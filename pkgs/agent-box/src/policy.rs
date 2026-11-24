//! Which GitHub requests a session may make with the injected token.
//!
//! The installation token is already limited to one repository. This policy
//! narrows writes further, to one branch or one pull request, because GitHub
//! tokens cannot express that. Reads are always allowed: git objects are
//! shared across branches, so read access cannot be narrower than the repo.

use crate::receive_pack::RefUpdate;
use crate::target::RepoId;
use graphql_parser::query::{Definition, OperationDefinition, Selection, Value};
use hyper::Method;
use serde_json::Value as Json;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Host {
    /// github.com: git smart HTTP and LFS.
    Web,
    /// api.github.com: REST and GraphQL.
    Api,
}

#[derive(Clone, Debug)]
pub struct Grant {
    pub repo: RepoId,
    pub repo_node_id: String,
    pub access: Access,
}

#[derive(Clone, Debug)]
pub enum Access {
    Repo,
    Branch(String),
    Pr {
        number: u64,
        node_id: String,
        head: PrHead,
    },
}

#[derive(Clone, Debug)]
pub enum PrHead {
    /// The head branch lives in the granted repo, so the session may push it.
    SameRepo(String),
    /// The head branch lives in a fork the token cannot write.
    Fork,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Deny(String),
}

fn deny(reason: impl Into<String>) -> Decision {
    Decision::Deny(reason.into())
}

/// What the proxy must read before it can decide.
#[derive(Debug, PartialEq, Eq)]
pub enum Check {
    Done(Decision),
    /// The ref-update commands at the start of a receive-pack body.
    RefUpdates,
    /// The whole (JSON) request body.
    Body(BodyRule),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BodyRule {
    GraphQl,
    CreatePull,
    LfsBatch,
}

impl Grant {
    pub fn describe(&self) -> String {
        match &self.access {
            Access::Repo => format!("{}: read and write the whole repo", self.repo),
            Access::Branch(branch) => {
                format!("{}: read the repo; write branch {branch}", self.repo)
            }
            Access::Pr {
                number,
                head: PrHead::SameRepo(branch),
                ..
            } => format!(
                "{}: read the repo; write PR #{number} and its branch {branch}",
                self.repo
            ),
            Access::Pr {
                number,
                head: PrHead::Fork,
                ..
            } => format!(
                "{}: read the repo; comment on and review fork PR #{number}",
                self.repo
            ),
        }
    }

    /// The branch this grant may push, if any.
    fn push_branch(&self) -> Option<&str> {
        match &self.access {
            Access::Branch(branch)
            | Access::Pr {
                head: PrHead::SameRepo(branch),
                ..
            } => Some(branch),
            Access::Repo
            | Access::Pr {
                head: PrHead::Fork, ..
            } => None,
        }
    }
}

pub fn check_request(grant: &Grant, host: Host, method: &Method, path: &str) -> Check {
    let segments: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
    // GraphQL over GET would carry a mutation past the body check; only
    // POST bodies are inspected.
    let scoped = !matches!(grant.access, Access::Repo);
    if scoped && host == Host::Api && segments == ["graphql"] && method != Method::POST {
        return Check::Done(deny("GraphQL must be sent with POST"));
    }
    if method == Method::GET || method == Method::HEAD || method == Method::OPTIONS {
        return Check::Done(Decision::Allow);
    }
    match host {
        Host::Web => check_web(grant, method, &segments),
        Host::Api => check_api(grant, method, &segments),
    }
}

fn check_web(grant: &Grant, method: &Method, segments: &[&str]) -> Check {
    let [owner, name, rest @ ..] = segments else {
        return Check::Done(deny("github.com web writes are not proxied"));
    };
    let ours = grant.repo.is(owner, name);
    match (method, rest) {
        (&Method::POST, ["git-upload-pack"]) => Check::Done(Decision::Allow),
        (&Method::POST, ["git-receive-pack"]) if !ours => Check::Done(deny(format!(
            "push to {owner}/{name} is outside {}",
            grant.repo
        ))),
        (&Method::POST, ["git-receive-pack"]) => match &grant.access {
            Access::Repo => Check::Done(Decision::Allow),
            Access::Pr {
                head: PrHead::Fork, ..
            } => Check::Done(deny("the PR's branch is in a fork; pushing is not allowed")),
            Access::Branch(_) | Access::Pr { .. } => Check::RefUpdates,
        },
        (&Method::POST, ["info", "lfs", "objects", "batch"]) => match grant.access {
            Access::Repo if ours => Check::Done(Decision::Allow),
            _ => Check::Body(BodyRule::LfsBatch),
        },
        _ => Check::Done(deny("github.com web writes are not proxied")),
    }
}

fn check_api(grant: &Grant, method: &Method, segments: &[&str]) -> Check {
    if matches!(grant.access, Access::Repo) {
        // The token cannot reach beyond the repo, so nothing narrower applies.
        return Check::Done(Decision::Allow);
    }
    if method == Method::POST && segments == ["graphql"] {
        return Check::Body(BodyRule::GraphQl);
    }
    let ["repos", owner, name, rest @ ..] = segments else {
        return Check::Done(deny("only repository API writes are allowed"));
    };
    if !grant.repo.is(owner, name) {
        return Check::Done(deny(format!("{owner}/{name} is outside {}", grant.repo)));
    }
    let allowed = match &grant.access {
        Access::Repo => unreachable!("repo grants return before path checks"),
        Access::Branch(_) => {
            if method == Method::POST && rest == ["pulls"] {
                return Check::Body(BodyRule::CreatePull);
            }
            false
        }
        Access::Pr { number, head, .. } => {
            let is_pr = |segment: &str| segment.parse::<u64>().ok() == Some(*number);
            let review = match (method, rest) {
                (&Method::POST, ["issues", n, "comments"])
                | (&Method::POST, ["pulls", n, "reviews"])
                | (&Method::POST, ["pulls", n, "reviews", _, "events"])
                | (&Method::POST, ["pulls", n, "comments"])
                | (&Method::POST, ["pulls", n, "comments", _, "replies"]) => is_pr(n),
                _ => false,
            };
            let manage = match (method, rest) {
                (&Method::PATCH, ["pulls", n])
                | (&Method::PATCH, ["issues", n])
                | (&Method::PUT, ["pulls", n, "update-branch"])
                | (&Method::POST | &Method::DELETE, ["pulls", n, "requested_reviewers"])
                | (&Method::POST | &Method::PUT, ["issues", n, "labels"])
                | (&Method::DELETE, ["issues", n, "labels", ..])
                | (&Method::POST | &Method::DELETE, ["issues", n, "assignees"]) => is_pr(n),
                _ => false,
            };
            review || (manage && matches!(head, PrHead::SameRepo(_)))
        }
    };
    Check::Done(if allowed {
        Decision::Allow
    } else {
        deny(format!(
            "{method} /{} is outside {}",
            segments.join("/"),
            grant.describe()
        ))
    })
}

pub fn check_ref_updates(grant: &Grant, updates: &[RefUpdate]) -> Decision {
    let Some(branch) = grant.push_branch() else {
        return deny("this session may not push");
    };
    let allowed = format!("refs/heads/{branch}");
    for update in updates {
        if update.name != allowed {
            return deny(format!("push to {} is outside {allowed}", update.name));
        }
        if update.is_delete() {
            return deny(format!("deleting {allowed} is not allowed"));
        }
    }
    Decision::Allow
}

pub fn check_body(grant: &Grant, rule: BodyRule, body: &[u8]) -> Decision {
    let Ok(json) = serde_json::from_slice::<Json>(body) else {
        return deny("request body is not JSON");
    };
    match rule {
        BodyRule::LfsBatch => match json.get("operation").and_then(Json::as_str) {
            Some("download") => Decision::Allow,
            _ => deny("LFS uploads are outside this session"),
        },
        BodyRule::CreatePull => {
            let Some(branch) = grant.push_branch() else {
                return deny("this session may not open pull requests");
            };
            let head = json.get("head").and_then(Json::as_str).unwrap_or_default();
            let head_ok = head == branch
                || head.split_once(':').is_some_and(|(owner, name)| {
                    owner.eq_ignore_ascii_case(&grant.repo.owner) && name == branch
                });
            let head_repo_ok = json
                .get("head_repo")
                .and_then(Json::as_str)
                .is_none_or(|full| {
                    full.split_once('/')
                        .is_some_and(|(o, n)| grant.repo.is(o, n))
                });
            if head_ok && head_repo_ok {
                Decision::Allow
            } else {
                deny(format!("pull requests must come from {branch}"))
            }
        }
        BodyRule::GraphQl => check_graphql(grant, &json),
    }
}

/// Mutations a PR-scoped session may run, and the input field that must name
/// the PR. Merging is absent on purpose: it writes the base branch.
const PR_REVIEW_MUTATIONS: &[(&str, &str)] = &[
    ("addComment", "subjectId"),
    ("addPullRequestReview", "pullRequestId"),
    ("addPullRequestReviewThread", "pullRequestId"),
    ("submitPullRequestReview", "pullRequestId"),
];
const PR_MANAGE_MUTATIONS: &[(&str, &str)] = &[
    ("updatePullRequest", "pullRequestId"),
    ("updatePullRequestBranch", "pullRequestId"),
    ("markPullRequestReadyForReview", "pullRequestId"),
    ("convertPullRequestToDraft", "pullRequestId"),
    ("closePullRequest", "pullRequestId"),
    ("reopenPullRequest", "pullRequestId"),
    ("requestReviews", "pullRequestId"),
    ("addLabelsToLabelable", "labelableId"),
    ("removeLabelsFromLabelable", "labelableId"),
    ("addAssigneesToAssignable", "assignableId"),
    ("removeAssigneesFromAssignable", "assignableId"),
];

fn check_graphql(grant: &Grant, json: &Json) -> Decision {
    let Some(query) = json.get("query").and_then(Json::as_str) else {
        return deny("GraphQL request has no query");
    };
    let variables = json.get("variables").cloned().unwrap_or(Json::Null);
    let document = match graphql_parser::parse_query::<String>(query) {
        Ok(document) => document,
        Err(error) => return deny(format!("unparseable GraphQL: {error}")),
    };
    for definition in &document.definitions {
        let mutation = match definition {
            Definition::Fragment(_)
            | Definition::Operation(
                OperationDefinition::Query(_) | OperationDefinition::SelectionSet(_),
            ) => {
                continue;
            }
            Definition::Operation(OperationDefinition::Subscription(_)) => {
                return deny("GraphQL subscriptions are not proxied");
            }
            Definition::Operation(OperationDefinition::Mutation(mutation)) => mutation,
        };
        for selection in &mutation.selection_set.items {
            let Selection::Field(field) = selection else {
                return deny("fragments at the top of a mutation are not allowed");
            };
            let input = field
                .arguments
                .iter()
                .find(|(name, _)| name == "input")
                .and_then(|(_, value)| to_json(value, &variables))
                .unwrap_or(Json::Null);
            if let Decision::Deny(reason) = check_mutation(grant, &field.name, &input) {
                return deny(reason);
            }
        }
    }
    Decision::Allow
}

fn check_mutation(grant: &Grant, name: &str, input: &Json) -> Decision {
    let field = |key: &str| input.get(key).and_then(Json::as_str);
    let outside = || {
        deny(format!(
            "GraphQL mutation {name} is outside {}",
            grant.describe()
        ))
    };
    match &grant.access {
        Access::Repo => Decision::Allow,
        Access::Branch(branch) => {
            let ok = name == "createPullRequest"
                && field("repositoryId") == Some(&grant.repo_node_id)
                && field("headRefName") == Some(branch)
                && field("headRepositoryId").is_none_or(|id| id == grant.repo_node_id);
            if ok { Decision::Allow } else { outside() }
        }
        Access::Pr { node_id, head, .. } => {
            let manage: &[(&str, &str)] = match head {
                PrHead::SameRepo(_) => PR_MANAGE_MUTATIONS,
                PrHead::Fork => &[],
            };
            let id_field = PR_REVIEW_MUTATIONS
                .iter()
                .chain(manage)
                .find(|(mutation, _)| *mutation == name)
                .map(|(_, id_field)| *id_field);
            match id_field {
                Some(id_field) if field(id_field) == Some(node_id) => Decision::Allow,
                _ => outside(),
            }
        }
    }
}

/// A GraphQL argument as JSON, with variables substituted. Unknown variables
/// become null, which no policy check accepts.
fn to_json(value: &Value<'_, String>, variables: &Json) -> Option<Json> {
    Some(match value {
        Value::Variable(name) => variables.get(name).cloned().unwrap_or(Json::Null),
        Value::Int(number) => Json::from(number.as_i64()?),
        Value::Float(number) => {
            serde_json::Number::from_f64(*number).map_or(Json::Null, Json::Number)
        }
        Value::String(text) | Value::Enum(text) => Json::String(text.clone()),
        Value::Boolean(flag) => Json::Bool(*flag),
        Value::Null => Json::Null,
        Value::List(items) => Json::Array(
            items
                .iter()
                .map(|item| to_json(item, variables))
                .collect::<Option<_>>()?,
        ),
        Value::Object(fields) => Json::Object(
            fields
                .iter()
                .map(|(key, item)| Some((key.clone(), to_json(item, variables)?)))
                .collect::<Option<_>>()?,
        ),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const A: &str = "1111111111111111111111111111111111111111";
    const ZERO: &str = "0000000000000000000000000000000000000000";

    fn grant(access: Access) -> Grant {
        Grant {
            repo: RepoId {
                owner: "jmqd".into(),
                name: "dotfiles".into(),
            },
            repo_node_id: "R_repo".into(),
            access,
        }
    }

    fn branch() -> Grant {
        grant(Access::Branch("feature".into()))
    }

    fn pr(head: PrHead) -> Grant {
        grant(Access::Pr {
            number: 7,
            node_id: "PR_seven".into(),
            head,
        })
    }

    fn same_repo_pr() -> Grant {
        pr(PrHead::SameRepo("feature".into()))
    }

    fn update(name: &str, new: &str) -> RefUpdate {
        RefUpdate {
            old: A.into(),
            new: new.into(),
            name: name.into(),
        }
    }

    fn graphql(grant: &Grant, query: &str, variables: Json) -> Decision {
        let body = json!({ "query": query, "variables": variables }).to_string();
        check_body(grant, BodyRule::GraphQl, body.as_bytes())
    }

    #[test]
    fn reads_are_allowed_for_every_grant_and_host() {
        for grant in [
            branch(),
            same_repo_pr(),
            pr(PrHead::Fork),
            grant(Access::Repo),
        ] {
            for host in [Host::Web, Host::Api] {
                assert_eq!(
                    check_request(&grant, host, &Method::GET, "/repos/other/repo/contents"),
                    Check::Done(Decision::Allow)
                );
            }
            assert_eq!(
                check_request(
                    &grant,
                    Host::Web,
                    &Method::POST,
                    "/other/repo.git/git-upload-pack"
                ),
                Check::Done(Decision::Allow)
            );
        }
    }

    #[test]
    fn a_repo_grant_pushes_anywhere_in_its_repo_but_never_elsewhere() {
        let grant = grant(Access::Repo);
        assert_eq!(
            check_request(
                &grant,
                Host::Web,
                &Method::POST,
                "/JMQD/Dotfiles.git/git-receive-pack"
            ),
            Check::Done(Decision::Allow)
        );
        assert!(matches!(
            check_request(
                &grant,
                Host::Web,
                &Method::POST,
                "/jmqd/other/git-receive-pack"
            ),
            Check::Done(Decision::Deny(_))
        ));
    }

    #[test]
    fn branch_and_same_repo_pr_grants_push_only_their_branch_and_never_delete_it() {
        for grant in [branch(), same_repo_pr()] {
            assert_eq!(
                check_request(
                    &grant,
                    Host::Web,
                    &Method::POST,
                    "/jmqd/dotfiles.git/git-receive-pack"
                ),
                Check::RefUpdates
            );
            assert_eq!(
                check_ref_updates(&grant, &[update("refs/heads/feature", A)]),
                Decision::Allow
            );
            for updates in [
                vec![update("refs/heads/main", A)],
                vec![update("refs/heads/feature", A), update("refs/tags/v1", A)],
                vec![update("refs/heads/feature", ZERO)],
                vec![update("refs/heads/feature/x", A)],
            ] {
                assert!(
                    matches!(check_ref_updates(&grant, &updates), Decision::Deny(_)),
                    "{updates:?}"
                );
            }
        }
    }

    #[test]
    fn fork_pr_grants_never_push() {
        assert!(matches!(
            check_request(
                &pr(PrHead::Fork),
                Host::Web,
                &Method::POST,
                "/jmqd/dotfiles/git-receive-pack"
            ),
            Check::Done(Decision::Deny(_))
        ));
        assert!(matches!(
            check_ref_updates(&pr(PrHead::Fork), &[update("refs/heads/feature", A)]),
            Decision::Deny(_)
        ));
    }

    #[test]
    fn pr_grants_comment_and_review_only_on_their_pr() {
        for grant in [same_repo_pr(), pr(PrHead::Fork)] {
            for path in [
                "/repos/jmqd/dotfiles/issues/7/comments",
                "/repos/jmqd/dotfiles/pulls/7/reviews",
                "/repos/jmqd/dotfiles/pulls/7/reviews/99/events",
                "/repos/jmqd/dotfiles/pulls/7/comments/5/replies",
            ] {
                assert_eq!(
                    check_request(&grant, Host::Api, &Method::POST, path),
                    Check::Done(Decision::Allow),
                    "{path}"
                );
            }
            for (method, path) in [
                (Method::POST, "/repos/jmqd/dotfiles/issues/8/comments"),
                (Method::PUT, "/repos/jmqd/dotfiles/pulls/7/merge"),
                (Method::POST, "/repos/jmqd/other/issues/7/comments"),
                (Method::DELETE, "/repos/jmqd/dotfiles/git/refs/heads/main"),
                (Method::POST, "/user/repos"),
            ] {
                assert!(
                    matches!(
                        check_request(&grant, Host::Api, &method, path),
                        Check::Done(Decision::Deny(_))
                    ),
                    "{method} {path}"
                );
            }
        }
    }

    #[test]
    fn only_same_repo_pr_grants_edit_the_pr() {
        let path = "/repos/jmqd/dotfiles/pulls/7";
        assert_eq!(
            check_request(&same_repo_pr(), Host::Api, &Method::PATCH, path),
            Check::Done(Decision::Allow)
        );
        assert!(matches!(
            check_request(&pr(PrHead::Fork), Host::Api, &Method::PATCH, path),
            Check::Done(Decision::Deny(_))
        ));
    }

    #[test]
    fn branch_grants_open_pull_requests_only_from_their_branch() {
        let grant = branch();
        assert_eq!(
            check_request(
                &grant,
                Host::Api,
                &Method::POST,
                "/repos/jmqd/dotfiles/pulls"
            ),
            Check::Body(BodyRule::CreatePull)
        );
        for head in ["feature", "jmqd:feature", "JMQD:feature"] {
            let body = json!({ "head": head, "base": "main" }).to_string();
            assert_eq!(
                check_body(&grant, BodyRule::CreatePull, body.as_bytes()),
                Decision::Allow,
                "{head}"
            );
        }
        for body in [
            json!({ "head": "main", "base": "feature" }),
            json!({ "head": "other:feature", "base": "main" }),
            json!({ "head": "feature", "head_repo": "other/dotfiles", "base": "main" }),
        ] {
            let body = body.to_string();
            assert!(
                matches!(
                    check_body(&grant, BodyRule::CreatePull, body.as_bytes()),
                    Decision::Deny(_)
                ),
                "{body}"
            );
        }
    }

    #[test]
    fn scoped_grants_refuse_graphql_that_skips_the_body_check() {
        for grant in [branch(), same_repo_pr(), pr(PrHead::Fork)] {
            assert!(matches!(
                check_request(&grant, Host::Api, &Method::GET, "/graphql"),
                Check::Done(Decision::Deny(_))
            ));
        }
    }

    #[test]
    fn graphql_queries_pass_and_mutations_must_target_the_granted_pr() {
        let grant = same_repo_pr();
        assert_eq!(
            graphql(
                &grant,
                "query { repository(owner:\"a\", name:\"b\") { id } }",
                Json::Null
            ),
            Decision::Allow
        );
        assert_eq!(
            graphql(
                &grant,
                "mutation C($input: AddCommentInput!) { addComment(input: $input) { clientMutationId } }",
                json!({ "input": { "subjectId": "PR_seven", "body": "hi" } })
            ),
            Decision::Allow
        );
        assert_eq!(
            graphql(
                &grant,
                "mutation($id: ID!) { updatePullRequest(input: { pullRequestId: $id, title: \"t\" }) { clientMutationId } }",
                json!({ "id": "PR_seven" })
            ),
            Decision::Allow
        );
        for (query, variables) in [
            (
                "mutation { addComment(input: { subjectId: \"PR_other\", body: \"x\" }) { clientMutationId } }",
                Json::Null,
            ),
            (
                "mutation { mergePullRequest(input: { pullRequestId: \"PR_seven\" }) { clientMutationId } }",
                Json::Null,
            ),
            (
                // One allowed field must not carry a second, disallowed one.
                "mutation { a: addComment(input: { subjectId: \"PR_seven\", body: \"x\" }) { clientMutationId } b: addComment(input: { subjectId: \"I_other\", body: \"x\" }) { clientMutationId } }",
                Json::Null,
            ),
            (
                "mutation($i: AddCommentInput!) { addComment(input: $i) { clientMutationId } }",
                Json::Null,
            ),
            (
                "mutation { ...F } fragment F on Mutation { deleteRef(input: {}) { clientMutationId } }",
                Json::Null,
            ),
            ("subscription { x }", Json::Null),
            ("not graphql", Json::Null),
        ] {
            assert!(
                matches!(graphql(&grant, query, variables), Decision::Deny(_)),
                "{query}"
            );
        }
    }

    #[test]
    fn fork_pr_grants_may_review_but_not_edit_through_graphql() {
        let grant = pr(PrHead::Fork);
        let review = "mutation { addPullRequestReview(input: { pullRequestId: \"PR_seven\", body: \"x\", event: COMMENT }) { clientMutationId } }";
        let edit = "mutation { updatePullRequest(input: { pullRequestId: \"PR_seven\", title: \"x\" }) { clientMutationId } }";
        assert_eq!(graphql(&grant, review, Json::Null), Decision::Allow);
        assert!(matches!(
            graphql(&grant, edit, Json::Null),
            Decision::Deny(_)
        ));
    }

    #[test]
    fn branch_grants_create_pull_requests_through_graphql_only_from_their_branch() {
        let grant = branch();
        let query = "mutation($input: CreatePullRequestInput!) { createPullRequest(input: $input) { pullRequest { url } } }";
        assert_eq!(
            graphql(
                &grant,
                query,
                json!({ "input": { "repositoryId": "R_repo", "headRefName": "feature", "baseRefName": "main", "title": "t" } })
            ),
            Decision::Allow
        );
        for input in [
            json!({ "repositoryId": "R_repo", "headRefName": "main", "baseRefName": "feature" }),
            json!({ "repositoryId": "R_other", "headRefName": "feature", "baseRefName": "main" }),
            json!({ "repositoryId": "R_repo", "headRefName": "feature", "headRepositoryId": "R_fork" }),
        ] {
            assert!(
                matches!(
                    graphql(&grant, query, json!({ "input": input })),
                    Decision::Deny(_)
                ),
                "{input}"
            );
        }
    }

    #[test]
    fn lfs_downloads_pass_and_uploads_need_a_repo_grant() {
        let grant = branch();
        let path = "/jmqd/dotfiles.git/info/lfs/objects/batch";
        assert_eq!(
            check_request(&grant, Host::Web, &Method::POST, path),
            Check::Body(BodyRule::LfsBatch)
        );
        assert_eq!(
            check_body(
                &grant,
                BodyRule::LfsBatch,
                br#"{"operation":"download","objects":[]}"#
            ),
            Decision::Allow
        );
        assert!(matches!(
            check_body(
                &grant,
                BodyRule::LfsBatch,
                br#"{"operation":"upload","objects":[]}"#
            ),
            Decision::Deny(_)
        ));
    }
}
