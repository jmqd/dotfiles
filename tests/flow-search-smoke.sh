#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
search_root="$tmp_dir/src"
state_dir="$tmp_dir/state"
repo_dir="$search_root/demo"
home_dir="$tmp_dir/home"
mkdir -p "$repo_dir/src" "$repo_dir/docs" "$home_dir"

export HOME="$home_dir"
export FLOW_SEARCH_ROOTS="$search_root"
export FLOW_SEARCH_STATE_DIR="$state_dir"

cd "$repo_dir"
git init -q
git config user.name 'Flow Smoke'
git config user.email 'flow-smoke@example.com'

printf 'fn hello_world() {}\n' >"$repo_dir/src/main.rs"
printf 'overview\n' >"$repo_dir/docs/search_plan.md"

git add src/main.rs docs/search_plan.md
git commit -q -m 'initial commit' -m 'adds hello world function'

printf 'dirty needle\n' >>"$repo_dir/src/main.rs"

cd "$repo_root"
flow search reindex >"$tmp_dir/reindex.txt"

[ -s "$state_dir/metadata/commits.sqlite" ]
[ -s "$state_dir/metadata/repos.json" ]
find "$state_dir/zoekt/index" -name '*.zoekt' -print -quit | grep -q .

flow --output json search status >"$tmp_dir/status.json"
jq -e --arg root "$search_root" '
  .command == "status"
  and .data.roots == [$root]
  and .data.index_ready == true
  and .data.metadata_ready == true
  and .data.indexed_repo_count == 1
  and .data.commit_count == 1
' "$tmp_dir/status.json" >/dev/null

flow --output json search code hello_world --repo demo >"$tmp_dir/code.json"
jq -e '
  .command == "code"
  and .data.repo == "demo"
  and (.data.results | length) == 1
  and .data.results[0].kind == "code"
  and .data.results[0].path == "src/main.rs"
  and .data.results[0].line == 1
  and (.data.results[0].snippet | contains("hello_world"))
' "$tmp_dir/code.json" >/dev/null

flow --output json search code search_plan --repo demo >"$tmp_dir/path.json"
jq -e '
  .command == "code"
  and .data.repo == "demo"
  and (.data.results | length) == 1
  and .data.results[0].kind == "path"
  and .data.results[0].path == "docs/search_plan.md"
' "$tmp_dir/path.json" >/dev/null

flow --output json search query hello --repo demo >"$tmp_dir/query.json"
jq -e '
  .command == "query"
  and .data.repo == "demo"
  and ([.data.results[].kind] | index("code")) != null
  and ([.data.results[].kind] | index("commit")) != null
' "$tmp_dir/query.json" >/dev/null

flow --output json search commits initial --repo demo >"$tmp_dir/commits.json"
jq -e '
  .command == "commits"
  and .data.repo == "demo"
  and (.data.results | length) == 1
  and .data.results[0].kind == "commit"
  and .data.results[0].subject == "initial commit"
' "$tmp_dir/commits.json" >/dev/null

flow --output json search query needle --repo demo --include-dirty >"$tmp_dir/dirty.json"
jq -e '
  .command == "query"
  and .data.repo == "demo"
  and ([.data.results[].kind] | index("dirty")) != null
  and ([.data.results[] | select(.kind == "dirty")][0].path) == "src/main.rs"
  and ([.data.results[] | select(.kind == "dirty")][0].snippet | contains("dirty needle"))
' "$tmp_dir/dirty.json" >/dev/null
