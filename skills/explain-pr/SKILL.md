---
name: explain-pr
description: Writes the story of a pull request for its reviewer (intent, a reading order as deep links into Files changed, risky areas and mechanical changes, a decision log, a Mermaid diagram when it earns its place) plus an author's review of 3 to 8 comments on the key lines. Every link and every line is checked against the diff. Previewed inside GitHub as a review draft only the author can see; published only after explicit agreement. Run it at the end of a dev session, in the conversation that wrote the code.
argument-hint: "[preview|publish|auto] [base-branch]"
---

# explain-pr — explain a pull request to its reviewer

Goal: a human reviewer should understand in a few minutes **why** the code looks the
way it does, **in what order** to read it, and **where** to concentrate. The code was
often written by an agent, so the story has to make the choices the agent made on its
own visible, so they get reviewed as such.

Two rules override everything else:

1. **Everything is checkable.** Every claim about the code points at precise lines of
   the diff. A claim that cannot be tied to a line visible in the diff is either
   rephrased (as a claim about intent, without pretending to describe the code) or
   dropped.
2. **Nothing ships without agreement.** The default mode is preview, dropped into the
   PR as a review draft only the user can see. Dropping that draft, creating or
   editing a PR, submitting a review: each one waits for an explicit "yes" from the
   user in the chat, for that action.

Arguments: `preview` (default) stops at the review draft. `publish` carries on to
publication, still asking for confirmation before anything goes out. `auto` is passed
by `scripts/hook.sh` after a push on a branch with an open PR: see "Auto mode" in § 6.
A second argument forces the base branch.

## Scripts

They live in this plugin's `scripts/` directory. Resolve it **once**, at the start, and
then use the absolute path literally in every later command:

```bash
echo "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/skills/explain-pr}"
```

(The fallback covers an older install as a personal skill rather than a plugin.)

- `anchor.sh <owner/repo> <pr> <path> <line> [R|L] [end_line]` → deep link URL. The
  anchor is `diff-<sha256 hex of the path>` (`shasum -a 256`), then `R<n>` (new file)
  or `L<n>` (old one). `anchor.sh --hash <path>` gives the hash alone.
- `check.py map --base B --head H [--files globs…]` → per file: hash, added lines,
  lines visible on the R side.
- `check.py check --base B --head H --repo o/r [--pr N] --body f.md --review f.json`
  → checks every link and every comment, and prints the line of code being targeted.
- `review.py find|draft|submit|discard --repo o/r --pr N …` → the GitHub review draft
  (PENDING): drop it, submit it as COMMENT, or delete it.
- `hook.sh` → the PostToolUse (Bash) hook, registered by this plugin's
  `hooks/hooks.json`. After `git push` / `gh pr create` on a branch with an open PR, it
  asks Claude to run this skill in `auto` mode. Nothing to wire up by hand.

## 1. Place the branch

In the current repository:

```bash
git branch --show-current
gh repo view --json nameWithOwner,defaultBranchRef -q '.nameWithOwner + " " + .defaultBranchRef.name'
gh pr view --json number,url,state,baseRefName,headRefOid,body,title 2>/dev/null
git status --short
```

- **Base**: the PR's `baseRefName` if it exists, else the argument, else the
  repository's default branch. Work against `origin/<base>` after
  `git fetch origin <base>` (that is the merge base GitHub displays).
- **Head**: `HEAD`. If a PR exists and `headRefOid` ≠ `git rev-parse HEAD`, GitHub's
  line numbers will not be the local ones: say so, and offer either to push first
  (with agreement) or to work on `headRefOid` (`--head <sha>` for the scripts,
  `git fetch` if needed).
- Uncommitted changes: they are neither in the diff nor on the PR. Mention them in one
  line, do not describe them.
- PR number: the existing PR's, else the literal marker `{{PR}}` in links until it is
  created.
- Never create a branch, commit, push or modify the repository in this skill without
  explicit agreement.

## 2. Gather the material

```bash
git log --reverse --format='%h %s%n%b' origin/<base>..HEAD
git diff --stat -M origin/<base>...HEAD
python3 <plugin-dir>/scripts/check.py map --base origin/<base> --head HEAD
```

Then read the diff file by file (`git diff -M origin/<base>...HEAD -- <path>`),
starting with application code, skimming lockfiles, stories, snapshots and generated
files. On a large diff, read the files carrying the logic in full and settle for the
hunk list on the rest.

**Where the intent comes from:**

- **The present conversation** (the normal case): re-read what was asked, the options
  considered and then dropped, the constraints the user set, the bugs hit along the
  way, what the agent decided without being told. This is the most valuable material:
  it exists nowhere in the code.
- **No conversation** (skill run cold, a test, another session): fall back on the diff,
  the commit messages and any existing PR description. Say so at the top of the preview
  ("Context reconstructed from the diff and the commits, without the dev conversation")
  and, in the decision log, file everything not attested by a commit, the PR or a code
  comment under "inferred from the code". Never invent a dropped option.

## 3. Write the description

In English, direct tone, short sentences, no superlatives. Template:

````markdown
<!-- explain-pr:start -->
## Intent

3-4 lines: the need, what the PR changes for the end user or the developer, and the
limit of what it covers.

## Reading order

1. [`path/short.tsx` — what you find there](https://github.com/o/r/pull/N/files#diff-<hash>R42): why start here.
2. …

## Where to look

**Risky areas** — read these line by line:
- [Label](link): the concrete risk (edge case, side effect, performance, security, concurrency).

**Mechanical changes** — skim these:
- `glob/or/files`: the nature of the change (rename, move, stories, lockfile, docs).

## Decision log

| Decision | Origin | Where |
|---|---|---|
| … | came from the requirement | [link](…) |
| … | the agent's call | [link](…) |

## Diagram

```mermaid
sequenceDiagram
  …
```
<!-- explain-pr:end -->
````

Content rules:

- **Reading order**: 4 to 8 steps, from the core outwards (types and contracts → logic
  → wiring → UI → tests). Each step is a deep link, preferably to an **added** line
  (`+` in `check.py map`), on the line that gives the file its meaning (signature,
  entry point, key condition), not on the first line of the hunk.
- **Risky areas**: only what genuinely deserves attention; 2 to 5 entries. Each one
  names the concrete risk, not "worth checking".
- **Mechanical changes**: globs or paths with no link. This is the only place a bullet
  may not point at a line.
- **Decision log**: 4 to 8 rows. Origin ∈ "came from the requirement" (asked for or
  imposed by the user, the ticket, the mockup, a stated technical constraint) / "the
  agent's call" (a trade-off taken unprompted; this is what the reviewer must
  challenge) / "inferred from the code" (no-conversation mode only). Name the dropped
  option when it is known.
- **Mermaid diagram**: only if a flow crosses several files, or if the order of events
  matters (loading, navigation, state). Otherwise, no such section. No diagram that
  restates the file list.
- Build every link with `anchor.sh`, never by hand.
- Do not restate the exhaustive list of changes: the PR already shows it.

If the PR already has a description written by someone: do not overwrite it. The
`<!-- explain-pr:start -->…<!-- explain-pr:end -->` block is **prepended** to the
existing description, or **replaced** if it is already there (skill re-run).

## 4. Write the author's review

3 to 8 comments on the key lines, each explaining the **why** (a constraint, a bug
avoided, an alternative dropped, an invariant to preserve), never the what that the
code already states. One or two sentences, in English. `review.json` format:

```json
{
  "commit_id": "<sha of the PR head>",
  "event": "COMMENT",
  "body": "Author's notes: why the key lines are the way they are. <!-- explain-pr -->",
  "comments": [
    { "path": "packages/x/src/a.ts", "line": 42, "side": "RIGHT", "body": "…" },
    { "path": "packages/x/src/b.ts", "start_line": 10, "line": 18, "side": "RIGHT", "start_side": "RIGHT", "body": "…" }
  ]
}
```

A comment does not repeat an entry from the description: it extends it onto the exact
line.

## 5. Check

```bash
python3 <plugin-dir>/scripts/check.py check \
  --base origin/<base> --head HEAD --repo <owner/repo> [--pr N] \
  --body <dir>/body.md --review <dir>/review.json
```

- Every **ERROR** gets fixed (line outside a hunk, wrong hash, wrong repository) before
  going any further.
- Re-read every `ok` line: the code shown on the right must match what the text claims.
  Otherwise move the link to the right line, or rephrase.
- A **WARNING** about a "bullet with no link" in the risky areas or the decision log:
  add the link, or rephrase it as intent, or drop it.
- Eyeball the Mermaid (simple syntax, short labels quoted when they contain
  punctuation).

## 6. Preview inside GitHub: a review draft

The preview is read **in the PR**, not in a file: a review draft (state `PENDING`) is
visible only to its author, notifies nobody, and can be deleted without a trace. The
story is its body, the comments sit on their lines in the Files changed tab, and the
Mermaid and the deep links render there exactly as the reviewer will see them.

The working files (`body.md`, `review.json`) go in
`~/.claude/explain-pr/<owner>-<repo>/<branch-slug>/`, outside the repository. They are
not deliverables: do not show them to the user as the preview.

1. Ask once: "Shall I drop a review draft on #N, visible only to you?" It is a write to
   the repository, even one invisible to others: it waits for a yes.
2. Then:
   ```bash
   python3 <plugin-dir>/scripts/review.py draft --repo <o/r> --pr N \
     --body <dir>/body.md --review <dir>/review.json
   ```
   GitHub allows only one draft per person per PR: if `draft` finds one, ask whether to
   delete it (`discard`) or to stop.
3. Give the user the link `https://github.com/<o/r>/pull/N/files`. The story shows up in
   the review-in-progress panel ("Finish your review" / "Review changes"), the comments
   on their lines marked *Pending*. Ask them to click one or two reading-order links to
   confirm the anchors actually scroll.
4. Corrections: edit `body.md` / `review.json`, `discard`, then `draft` again (simpler
   than editing comment by comment).

**Auto mode** (argument `auto`, sent by the hook this plugin installs): agreement for
the draft is given once and for all by that hook. So, without asking anything:

1. redo § 1 to 5 against the PR's new head (read the commits added since the last run,
   reuse the previous story from `~/.claude/explain-pr/…/body.md` as a starting point
   and correct it, rather than rewriting everything);
2. `review.py find`, `discard` the existing draft if there is one, then `draft`;
3. finish with one line: "explain-pr draft refreshed on #N (K comments, head
   <short sha>)" and what changed in the story.

If an explain-pr review has **already been published** on the PR, do not post comments
again: prepare the description-block update and offer it, because that is a publication
and it waits for a yes. Auto mode never publishes anything. If `check.py` leaves an
error, do not drop a draft: say so in one line.

**No PR** (branch never proposed): no draft is possible. Offer to create the PR as a
draft (`gh pr create --draft`, visible to the team, so explicit agreement), otherwise
fall back on a local preview summarised in the reply.

## 7. Publish (only after an explicit "yes")

Ask for a confirmation that states exactly what will go out: "Prepend the story to the
description of #N" and "Submit the review: K comments visible to everyone". Then:

1. **Description**: compose `<dir>/body-final.md` = explain-pr block + old description
   (previous block removed), then `gh pr edit N --body-file <dir>/body-final.md`.
2. **Review**: submit the draft with a short body, the story now living in the
   description:
   ```bash
   python3 <plugin-dir>/scripts/review.py submit --repo <o/r> --pr N --id <id> \
     --body "Author's notes: why the key lines are the way they are, see the description. <!-- explain-pr -->"
   ```

**No PR yet**: create the PR first (`gh pr create --base <base> --head <branch> --title
… --body-file …`, branch pushed with agreement), replace `{{PR}}` with its number in
`body.md`, re-check with `check.py --pr N`, then go through the draft (§ 6) before
publishing.

Finish by giving the PR URL and the number of visible comments.

## Known limits

- GitHub collapses large files ("Load diff"): a link into such a file opens the tab but
  does not scroll to the line. For the reading order, prefer lines in small or
  medium-sized files, or warn in the label.
- Anchors depend on the path: a later rename breaks the links. Re-run the skill after
  any push that moves files or shifts the cited lines.
