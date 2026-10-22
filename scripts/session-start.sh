#!/usr/bin/env bash
# SessionStart hook. Catch-up path: in a repository where explain-pr is enabled, compare
# the open PR's head against the heads already narrated. If the PR moved since the last
# run — a push you made by hand, a PR you opened yourself, a push from another machine —
# ask Claude to refresh the draft. Silent otherwise.
#
# This compares state rather than listening for an event, so it does not care who pushed
# or how. A PostToolUse hook can only see commands Claude itself ran.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"

input=$(cat 2>/dev/null || true)
cwd=$(jq -r '.cwd // ""' <<<"${input:-{\}}" 2>/dev/null)
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

epr_enabled || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
pr=$(gh pr view --json number,state,headRefOid \
       -q 'select(.state == "OPEN") | "\(.number) \(.headRefOid)"' 2>/dev/null) || exit 0
[[ -z "$pr" ]] && exit 0
number=${pr%% *}
head=${pr##* }

slug=$(epr_repo_slug)
epr_head_done "$slug" "$head" && exit 0

short=${head:0:7}
shopt -s nullglob
narrated=("$(epr_state_root)/$slug"/*/last-head)
if (( ${#narrated[@]} )); then
  why="The PR has moved since the last explain-pr run (head is now ${short})."
  msg="explain-pr: #${number} moved to ${short}, draft is stale"
else
  why="PR #${number} has no explain-pr narrative yet (head ${short})."
  msg="explain-pr: #${number} has no walkthrough yet"
fi

context="explain-pr catch-up: branch ${branch} is on open PR #${number} and ${why} \
Its scripts are in ${SELF_DIR}; use that path and do not look for them. \
Run the explain-pr:explain-pr skill now with the argument \"auto\" on that PR: recompute the \
walkthrough and the comments against the new head, replace the review draft (visible only to \
the current user) without asking again, publish nothing. Say in one line that you are doing it \
because the PR moved outside Claude, then go back to whatever the user asks next. This fires \
once per new head, so it will not repeat until the PR moves again."

jq -n \
  --arg ctx "$context" \
  --arg msg "$msg" \
  '{
     systemMessage: $msg,
     hookSpecificOutput: {
       hookEventName: "SessionStart",
       additionalContext: $ctx
     }
   }'
