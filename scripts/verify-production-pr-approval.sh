#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"

GH_BIN="${GH_BIN:-gh}"
JQ_BIN="${JQ_BIN:-jq}"
AF_VERIFY_PRODUCTION_ENVIRONMENT="${AF_VERIFY_PRODUCTION_ENVIRONMENT:-false}"

if [[ "${GITHUB_REPOSITORY}" != "alternatefutures/service-builder" ]]; then
  echo "publisher approval verifier is bound to the exact repository" >&2
  exit 2
fi
if [[ ! "${GITHUB_SHA}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "GITHUB_SHA must be a full lowercase commit SHA" >&2
  exit 2
fi
if [[ "${AF_VERIFY_PRODUCTION_ENVIRONMENT}" != true \
  && "${AF_VERIFY_PRODUCTION_ENVIRONMENT}" != false ]]; then
  echo "AF_VERIFY_PRODUCTION_ENVIRONMENT must be true or false" >&2
  exit 2
fi

# The private repository is on GitHub Free, where required environment
# reviewers are unavailable. Keep the environment's protected-branch policy as
# an additive check, then independently prove this exact main commit came from
# one unambiguous merged PR with a current exact-head approval from a known
# human who is not the PR author.
if [[ "${AF_VERIFY_PRODUCTION_ENVIRONMENT}" == true ]]; then
  environment_json="$("${GH_BIN}" api \
    "repos/${GITHUB_REPOSITORY}/environments/Production")"
  "${JQ_BIN}" -e '
    (.deployment_branch_policy.protected_branches == true) and
    (.deployment_branch_policy.custom_branch_policies == false)
  ' <<<"${environment_json}" >/dev/null || {
    echo "publisher environment must remain restricted to protected branches" >&2
    exit 1
  }
fi

pulls_json="$("${GH_BIN}" api --paginate --slurp \
  -H "Accept: application/vnd.github+json" \
  "repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls?per_page=100")"
pull_json="$("${JQ_BIN}" -ce --arg sha "${GITHUB_SHA}" '
  add
  | [
      .[]
      | select(
          .merged_at != null
          and .base.ref == "main"
          and (.merge_commit_sha == $sha or .head.sha == $sha)
        )
    ]
  | if length == 1 then .[0] else error("exact_merged_pr_not_unique") end
' <<<"${pulls_json}")" || {
  echo "exact publisher commit must be associated with one merged PR into main" >&2
  exit 1
}

pull_number="$("${JQ_BIN}" -er '.number | select(type == "number" and . > 0)' \
  <<<"${pull_json}")"
pull_head_sha="$("${JQ_BIN}" -er '.head.sha | select(test("^[0-9a-f]{40}$"))' \
  <<<"${pull_json}")"
pull_author="$("${JQ_BIN}" -er '.user.login | select(type == "string" and length > 0)' \
  <<<"${pull_json}")"

reviews_json="$("${GH_BIN}" api --paginate --slurp \
  -H "Accept: application/vnd.github+json" \
  "repos/${GITHUB_REPOSITORY}/pulls/${pull_number}/reviews?per_page=100")"
"${JQ_BIN}" -e \
  --arg head "${pull_head_sha}" \
  --arg author "${pull_author}" '
    add
    | [
        .[]
        | select(
            (.user.login == "mavisakalyan" or .user.login == "CaptainSouthpaw")
            and .user.login != $author
            and .commit_id == $head
            and (.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")
          )
      ]
    | sort_by(.user.login, .submitted_at, .id)
    | group_by(.user.login)
    | map(last)
    | any(.state == "APPROVED")
  ' <<<"${reviews_json}" >/dev/null || {
  echo "exact PR head requires a current approval from an allowlisted independent human" >&2
  exit 1
}

printf 'Verified independent exact-head approval for PR #%s\n' "${pull_number}"

