# explain-pr

A Claude Code plugin. It walks you through an open pull request and flags what deserves a
closer look, so you understand what the agent actually changed rather than taking its word
for it.

It ships a skill you can call yourself, plus a hook that re-runs it for you after a push.
The output is a **review draft, visible only to you**. Nothing is ever published to the PR.

> **Status: not installable yet.** `skills/explain-pr/SKILL.md` is still missing, so the hook
> would ask Claude to run a skill that does not exist. Don't install this until that file
> lands.

## Install

```bash
/plugin marketplace add leobrossault/explain-pr
/plugin install explain-pr@lbrossault-tools
```

The name after `@` is the marketplace name declared in `.claude-plugin/marketplace.json`,
not the repository name.

Requires `git`, [`gh`](https://cli.github.com/) (authenticated) and `jq` on your `PATH`.

## Use

```
/explain-pr:explain-pr          # walk me through the current PR
/explain-pr:explain-pr auto     # recompute and replace the review draft, no questions
```

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
├── scripts/hook.sh
└── skills/explain-pr/SKILL.md
```

## License

MIT
