#!/usr/bin/env bash
# PostToolUse (Bash) hook. After a successful `git push` or `gh pr create` on a
# branch that has an open PR, ask Claude to re-run the explain-pr skill in `auto`
# mode: the review draft is replaced, nothing is published. Silent otherwise.
#
# Wired up by hooks/hooks.json when this plugin is enabled. Do NOT also declare it
# in .claude/settings.json or .claude/settings.local.json, or it will fire twice.
set -uo pipefail

input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")
cwd=$(jq -r '.cwd // ""' <<<"$input")

# `git push` (including `git -C dir push`) or `gh pr create`, either at the start of
# the command or after a separator.
grep -Eq '(^|[;&|]|&&)[[:space:]]*(git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+create)([[:space:]]|$)' <<<"$cmd" || exit 0

# Skip deletes, tag pushes and dry runs. Only the push/create segment is inspected, so
# a `-n` or `-d` belonging to an earlier command on the same line does not silently
# skip the refresh (`git commit -m "add -n flag" && git push` used to be swallowed).
seg=$(grep -Eo '(git([[:space:]]+-C[[:space:]]+[^[:space:];&|]+)?[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+create)[^;&|]*' <<<"$cmd" | tail -1)
grep -Eq '[[:space:]](--delete|-d|--tags|--dry-run|-n)([[:space:]]|$)' <<<"$seg " && exit 0

# Which directory was pushed from: `git -C <dir>`, else the last `cd <dir>` in the
# command, else the session cwd. A relative path is resolved from the session cwd.
dir=$(grep -Eo 'git[[:space:]]+-C[[:space:]]+[^[:space:];&|]+' <<<"$cmd" | tail -1 | awk '{print $3}')
[[ -z "$dir" ]] && dir=$(grep -Eo '(^|[;&|])[[:space:]]*cd[[:space:]]+[^[:space:];&|]+' <<<"$cmd" | tail -1 | awk '{print $NF}')
dir=${dir//\"/}; dir=${dir//\'/}; dir=${dir/#\~/$HOME}
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null
[[ -n "$dir" ]] && { cd "$dir" 2>/dev/null || exit 0; }
[[ -z "$cwd" && -z "$dir" ]] && exit 0

# Per-repository opt-in. Nothing happens unless explain-pr.enabled is true in this clone.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SELF_DIR/common.sh"
epr_enabled || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0
pr=$(gh pr view --json number,state,url -q 'select(.state == "OPEN") | "\(.number) \(.url)"' 2>/dev/null) || exit 0
[[ -z "$pr" ]] && exit 0
number=${pr%% *}

# CLAUDE_PLUGIN_ROOT is exported to hook processes but NOT to a skill's own Bash calls,
# so hand the resolved scripts directory to the skill rather than making it look.
scripts_dir="${CLAUDE_PLUGIN_ROOT:-}"
[[ -n "$scripts_dir" ]] && scripts_dir="${scripts_dir%/}/scripts"
[[ -n "$scripts_dir" && -f "$scripts_dir/check.py" ]] \
  && where="Its scripts are in ${scripts_dir} (resolved from CLAUDE_PLUGIN_ROOT); use that path and do not look for them." \
  || where="CLAUDE_PLUGIN_ROOT was not set for this hook, so resolve the scripts directory as the skill describes."

context="explain-pr hook: branch ${branch} was pushed and PR #${number} is open. \
${where} \
Run the explain-pr:explain-pr skill now with the argument \"auto\" on that PR: recompute the \
walkthrough and the comments against the new head, replace the review draft (visible only to \
the current user) without asking again, publish nothing. If you are already running explain-pr \
and this push is part of it, ignore this message."

# `hookSpecificOutput.additionalContext` is the documented way to put text in front of
# Claude after a tool has run (PostToolUse cannot block: the tool already ran).
# `systemMessage` is what the user sees in the transcript.
#
# If `auto` never actually fires with this form, run once with `claude --debug` and try
# the older top-level decision form instead, which the docs still list for PostToolUse:
#   jq -n --arg reason "$context" --arg msg "..." \
#     '{decision: "block", reason: $reason, systemMessage: $msg}'
# Use one form or the other, not both.
jq -n \
  --arg ctx "$context" \
  --arg msg "explain-pr: review draft to refresh on #${number}" \
  '{
     systemMessage: $msg,
     hookSpecificOutput: {
       hookEventName: "PostToolUse",
       additionalContext: $ctx
     }
   }'
