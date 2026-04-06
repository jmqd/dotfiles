pub mod config;
pub mod dirty;
pub mod lock;
pub mod metadata;
pub mod repo;
pub mod zoekt;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SearchTools {
    git_bin: String,
    zoekt_bin: String,
    zoekt_git_index_bin: String,
}

impl SearchTools {
    pub fn load() -> Self {
        Self {
            git_bin: std::env::var("FLOW_SEARCH_GIT_BIN").unwrap_or_else(|_| "git".to_owned()),
            zoekt_bin: std::env::var("FLOW_SEARCH_ZOEKT_BIN")
                .unwrap_or_else(|_| "zoekt".to_owned()),
            zoekt_git_index_bin: std::env::var("FLOW_SEARCH_ZOEKT_GIT_INDEX_BIN")
                .unwrap_or_else(|_| "zoekt-git-index".to_owned()),
        }
    }

    pub fn git_bin(&self) -> &str {
        &self.git_bin
    }

    pub fn zoekt_bin(&self) -> &str {
        &self.zoekt_bin
    }

    pub fn zoekt_git_index_bin(&self) -> &str {
        &self.zoekt_git_index_bin
    }
}

pub fn normalize_query_terms(terms: &[String]) -> Vec<String> {
    terms
        .iter()
        .flat_map(|value| value.split_whitespace())
        .map(|value| value.trim().to_lowercase())
        .filter(|value| !value.is_empty())
        .collect()
}

pub fn join_query_terms(terms: &[String]) -> String {
    terms.join(" ").trim().to_owned()
}

#[cfg(test)]
mod tests {
    use super::{join_query_terms, normalize_query_terms};

    #[test]
    fn normalizes_terms_to_lowercase_words() {
        assert_eq!(
            normalize_query_terms(&["Review Scope".to_owned(), "Parser".to_owned()]),
            vec!["review", "scope", "parser"]
        );
    }

    #[test]
    fn joins_terms_with_spaces() {
        assert_eq!(
            join_query_terms(&["review".to_owned(), "scope".to_owned()]),
            "review scope"
        );
    }
}
