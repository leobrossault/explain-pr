#!/usr/bin/env bash
# Detached worker for the headless path. Launched by the pre-push git hook, never by hand.
#
#   headless-refresh.sh <repo-root> <pushed-sha> <log-file>
#
# pre-push runs BEFORE the push, and a push can still be rejected, so this waits until the
# remote actually reports the pushed sha as the PR head before spending anything. If it
# never does, it gives up and says so in the log.
set -uo pipefail

repo_root=${1:?repo root required}
pushed_sha=${2:?pushed sha required}
log=${3:?log file required}

mkdir -p "$(dirname "$log")" 2>/dev/null || true
stamp() { date -u +%FT%TZ; }

cd "$repo_root" 2>/dev/null || { printf '%s  cannot cd into %s\n' "$(stamp)" "$repo_root" >>"$log"; exit 0; }

extra_args=$(git config --get explain-pr.claudeArgs 2>/dev/null || true)
timeout_s=$(git config --get explain-pr.headlessTimeout 2>/dev/null || true)
[[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=90

waited=0
while (( waited < timeout_s )); do
  pr=$(gh pr view --json number,state,headRefOid \
         -q 'select(.state == "OPEN") | "\(.number) \(.headRefOid)"' 2>/dev/null) || pr=""
  if [[ -n "$pr" && "${pr##* }" == "$pushed_sha" ]]; then
    printf '%s  #%s head %s: starting claude -p\n' "$(stamp)" "${pr%% *}" "${pushed_sha:0:7}" >>"$log"
    # shellcheck disable=SC2086
    if claude -p "/explain-pr:explain-pr auto" $extra_args >>"$log" 2>&1; then
      printf '%s  done\n' "$(stamp)" >>"$log"
    else
      printf '%s  claude -p exited non-zero, output above\n' "$(stamp)" >>"$log"
    fi
    exit 0
  fi
  sleep 3
  (( waited += 3 ))
done

printf '%s  gave up after %ss: the remote never reported head %s (push rejected, or no open PR)\n' \
  "$(stamp)" "$waited" "${pushed_sha:0:7}" >>"$log"
