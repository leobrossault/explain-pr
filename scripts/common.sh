#!/usr/bin/env bash
# Shared helpers. Source this with an absolute path; it reads nothing from stdin.
#
# Two per-repository flags, both stored in the clone's own .git/config, so they are
# per project, never committed, and invisible to collaborators:
#
#   explain-pr.enabled    nothing happens at all unless this is true
#   explain-pr.headless   also refresh on a manual push, without a Claude session
#
# Toggle them with scripts/explain-pr-ctl, or by hand:
#   git config --bool explain-pr.enabled true

epr_enabled() {
  [[ "$(git config --bool --get explain-pr.enabled 2>/dev/null)" == "true" ]]
}

epr_headless() {
  [[ "$(git config --bool --get explain-pr.headless 2>/dev/null)" == "true" ]]
}

# Where the skill keeps body.md, review.json and last-head, outside the repository and
# outside the plugin so a version bump does not lose it.
epr_state_root() {
  printf '%s\n' "${EXPLAIN_PR_HOME:-$HOME/.claude/explain-pr}"
}

# "owner/repo" -> "owner-repo". Read from the remote URL, with no network call: this runs
# on every session start, and `gh repo view` can block on a keychain prompt or a slow link.
# Falls back to gh only when the URL cannot be parsed.
epr_repo_slug() {
  local url s repo rest owner
  url=$(git config --get remote.origin.url 2>/dev/null)
  if [[ -n "$url" ]]; then
    s=${url%.git}; s=${s%/}
    s=${s#*://}        # strip any scheme
    s=${s#*@}          # strip user@
    s=${s/:/\/}        # scp form host:owner/repo -> host/owner/repo (first colon only)
    if [[ "$s" == */*/* || "$s" == */* ]]; then
      repo=${s##*/}
      rest=${s%/*}
      owner=${rest##*/}
      if [[ -n "$owner" && -n "$repo" && "$owner" != "$repo" ]]; then
        printf '%s\n' "$owner-$repo"
        return 0
      fi
    fi
  fi
  gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null | tr '/' '-'
}

# Has this exact head already been narrated? Looks across every branch directory of the
# repo rather than recomputing the branch slug, so it does not depend on how the slug was
# spelled when the narrative was written.
# Usage: epr_head_done <repo-slug> <sha>
epr_head_done() {
  local slug="$1" sha="$2" f
  [[ -n "$slug" && -n "$sha" ]] || return 1
  shopt -s nullglob
  for f in "$(epr_state_root)/$slug"/*/last-head; do
    [[ "$(tr -d '[:space:]' <"$f" 2>/dev/null)" == "$sha" ]] && return 0
  done
  return 1
}
