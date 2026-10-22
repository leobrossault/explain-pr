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

## What the hook does

`hooks/hooks.json` registers a `PostToolUse` hook on `Bash`. The full contents, so you can
read it before you install rather than after:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"${CLAUDE_PLUGIN_ROOT}/scripts/hook.sh\"",
            "timeout": 20
          }
        ]
      }
    ]
  }
}
```

`scripts/hook.sh` reads the Bash command Claude just ran and **exits immediately unless** the
command contains a `git push` or a `gh pr create`. Only then does it touch your repository, and
only to read: `git rev-parse` for the branch name and `gh pr view` for the PR state. If the
branch has an open PR, it asks Claude to re-run the skill in `auto` mode.

It deliberately does nothing on `--delete` / `-d`, `--tags`, `--dry-run` / `-n`, or when the
branch has no open PR.

It writes nothing, pushes nothing and comments nothing. Read `scripts/hook.sh` — it is about
forty lines.

## Scope, and why it matters

Hooks installed by a plugin are **active in every session, in every project**, not just the
repository you set them up in. That is wider than wiring the hook into a single project's
`.claude/settings.local.json`, which is what it replaces.

If you previously declared this hook by hand in `.claude/settings.json` or
`.claude/settings.local.json`, **remove that entry**. Plugin hooks merge with project and user
hooks, so leaving both in place runs the hook twice on every push.

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
│   ├── hook.sh               PostToolUse hook
│   ├── anchor.sh             deep-link builder
│   ├── check.py              map + verify links and comments against the diff
│   └── review.py             GitHub review draft: find / draft / submit / discard
└── skills/explain-pr/SKILL.md
```

Working files (`body.md`, `review.json`) are written to
`~/.claude/explain-pr/<owner>-<repo>/<branch>/`, outside your repository and outside the
plugin, so they survive a plugin update.

## License

MIT
