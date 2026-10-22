# explain-pr

A Claude Code plugin. It walks you through an open pull request and flags what deserves a
closer look, so you understand what the agent actually changed rather than taking its word
for it.

It ships a skill you can call yourself, plus a hook that re-runs it for you after a push.
The output is a **review draft, visible only to you**. Nothing is ever published to the PR.

## Install

```bash
/plugin marketplace add leobrossault/explain-pr
/plugin install explain-pr@lbrossault-tools
```

The name after `@` is the marketplace name declared in `.claude-plugin/marketplace.json`,
not the repository name.

Requires `git`, [`gh`](https://cli.github.com/) (authenticated), `jq`, `python3` and
`shasum` on your `PATH`.

## Use

Run it at the end of a dev session, **in the conversation that wrote the code** — that
conversation is where the intent lives, and it is the one thing the diff cannot tell you.

```
/explain-pr:explain-pr            # preview: drop a review draft only you can see
/explain-pr:explain-pr publish    # carry on to publication, still asking first
/explain-pr:explain-pr auto       # refresh the draft without asking (what the hook sends)
/explain-pr:explain-pr preview main   # force the base branch
```

What lands in the draft: the intent in a few lines, a reading order as deep links into
Files changed, the risky areas versus the mechanical ones, a decision log that separates
what the requirement imposed from what the agent decided on its own, a Mermaid diagram
when a flow crosses several files, and 3 to 8 comments on the key lines explaining why
they are the way they are.

Every link and every cited line is checked against the diff before anything is dropped.

## Turning it on, per project

Nothing happens until you opt a repository in. The flags live in that clone's own
`.git/config`, so they are per project, never committed, and invisible to collaborators.

```bash
explain-pr-ctl on            # refresh the draft after a push Claude makes, and catch up
                             # at session start if the PR moved without Claude
explain-pr-ctl headless-on   # also refresh after a push you make yourself, with no
                             # Claude session open
explain-pr-ctl off
explain-pr-ctl headless-off
explain-pr-ctl status        # what is on here, and which heads have been narrated
```

Put it on your `PATH` once:

```bash
ln -s ~/.claude/plugins/cache/*/explain-pr/*/scripts/explain-pr-ctl ~/.local/bin/explain-pr-ctl
```

That symlink points at one installed version, so re-run it after an update. Or skip it and
set the flags by hand: `git config --bool explain-pr.enabled true`.

## The three ways it fires

| Hook | Fires when | Needs |
|---|---|---|
| `PostToolUse` | Claude ran `git push` or `gh pr create` and the branch has an open PR | `enabled` |
| `SessionStart` | you open a session and the PR's head is one no narrative covers | `enabled` |
| `pre-push` (git) | you push yourself, from any terminal | `enabled` + `headless` |

The first two cost nothing when there is nothing to do. The `SessionStart` one compares
state rather than listening for an event, so it catches a push you made by hand, a PR you
opened yourself, and even a push from another machine — and it fires once per new head, not
once per session.

The headless one is the only path that spends tokens with nobody watching: it runs
`claude -p` in the background. It waits until GitHub actually reports the pushed commit as
the PR head before starting, so a rejected push costs nothing, and gives up after 90
seconds. Its log is `~/.claude/explain-pr/<owner>-<repo>/headless.log`. Two knobs:

```bash
git config explain-pr.claudeArgs "--permission-mode acceptEdits"   # passed to claude -p
git config explain-pr.headlessTimeout 120                          # seconds to wait
```

A `claude -p` run needs whatever permissions your setup requires to use Bash; if the log
shows it exiting without doing anything, that is the first thing to look at.

### If your repo already has a pre-push hook

`explain-pr-ctl headless-on` renames it to `pre-push.explain-pr-previous` and calls it first,
with the same stdin, and returns its exit code — so husky or lefthook can still reject the
push. `headless-off` puts it back. If `core.hooksPath` is set, git may not run
`.git/hooks/pre-push` at all; the installer warns you, and the hook has to go in that
directory instead.

## What the hooks read

They read the command Claude ran, or the state of the PR. They never write to your
repository, never push, never comment. The review draft is a GitHub review in state
`PENDING`: visible only to you, notifying nobody, deleted without a trace. Publishing is a
separate step that always asks.

`hooks/hooks.json` in full, so you can read it before you install rather than after:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/hook.sh\"", "timeout": 20 }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/session-start.sh\"", "timeout": 20 }
        ]
      }
    ]
  }
}
```

Both exit immediately unless the repository is opted in. Read `scripts/` — the longest file
is under eighty lines.

## How the skill finds its scripts

`CLAUDE_PLUGIN_ROOT` is exported to hook processes but **not** to the Bash calls a skill
makes, so the skill cannot read it. Two paths, depending on how it was started:

- Started by the hook (`auto`): the hook resolves `CLAUDE_PLUGIN_ROOT` itself and passes the
  absolute `scripts/` directory in its message. Nothing to look up.
- Started by hand: the skill resolves it once, with
  `ls -d ~/.claude/plugins/cache/*/explain-pr/*/scripts | sort -V | tail -1`. The installed
  plugin lives under a versioned directory, so the path moves on every bump and `sort -V`
  picks the newest.

Note that `~/.claude/plugins/marketplaces/<marketplace>/` is a full clone of this repository
and holds a second copy of `scripts/`. It is not what the installed plugin runs, and the
resolution above ignores it on purpose.

## Development

```bash
claude plugin validate .
```

### Known uncertainty

The hook returns `hookSpecificOutput.additionalContext`, which is the documented way to put
text in front of Claude after a tool has run. `PostToolUse` cannot block anything — the tool
has already run — so the older top-level `{"decision": "block", "reason": ...}` form is not
the right shape here, even though the docs still list it for this event.

If `auto` never actually fires, run a push once with `claude --debug` and swap in the
commented-out `decision` form near the bottom of `scripts/hook.sh`. Use one form or the
other, never both.

## Layout

```
explain-pr/
├── .claude-plugin/
│   ├── plugin.json
│   └── marketplace.json      this repo is its own marketplace
├── hooks/hooks.json
├── scripts/
│   ├── common.sh             the two flags, state paths, "already narrated?"
│   ├── explain-pr-ctl        on / off / headless-on / headless-off / status
│   ├── hook.sh               PostToolUse: a push Claude made
│   ├── session-start.sh      SessionStart: the PR moved without Claude
│   ├── pre-push              git hook template for headless mode
│   ├── headless-refresh.sh   detached worker behind pre-push
│   ├── anchor.sh             deep-link builder
│   ├── check.py              map + verify links and comments against the diff
│   └── review.py             review draft: find / draft / submit / discard
└── skills/explain-pr/SKILL.md
```

Working files (`body.md`, `review.json`) are written to
`~/.claude/explain-pr/<owner>-<repo>/<branch>/`, outside your repository and outside the
plugin, so they survive a plugin update.

## License

MIT
