#!/usr/bin/env python3
"""Vérifie qu'une description de PR et une review d'auteur ne citent que des
lignes réellement présentes dans le diff affiché par GitHub.

  check.py map   --base B --head H [--files motif]
      Pour chaque fichier du diff : hash d'ancre, chemin, lignes ajoutées (+)
      et lignes visibles côté R. Sert à choisir les lignes à citer.

  check.py check --base B --head H --repo owner/repo [--pr N]
                 [--body body.md] [--review review.json]
      Contrôle chaque lien #diff-…R<n>/L<n> du corps et chaque commentaire de
      la review. Affiche, pour chaque référence, la ligne de code ciblée afin
      qu'on puisse relire l'affirmation contre le code. Code de sortie 1 s'il
      reste une erreur.

Le diff est calculé comme sur GitHub : `git diff -M base...head`, 3 lignes de
contexte. Seules les lignes visibles dans un hunk peuvent porter une ancre ou
un commentaire de review. Les hash sont recalculés avec hashlib, indépendamment
d'anchor.sh (shasum), ce qui recoupe les deux calculs.
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
from fnmatch import fnmatch

LINK_RE = re.compile(
    r"https://github\.com/(?P<repo>[^/\s]+/[^/\s]+)/pull/(?P<pr>\d+|\{\{PR\}\})/files"
    r"#diff-(?P<hash>[0-9a-f]{64})(?P<side>[RL])(?P<line>\d+)"
    r"(?:-(?P<side2>[RL])(?P<end>\d+))?"
)
ANY_DIFF_LINK_RE = re.compile(r"/files#diff-[^\s)\]>\"']*")
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
# Sections (titres ou lignes en gras) où chaque puce doit pointer vers du code ; les
# zones mécaniques peuvent se contenter de globs.
CITED_SECTIONS = re.compile(r"risque|journal|décision|decision", re.I)


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def sha(path):
    return hashlib.sha256(path.encode()).hexdigest()


def parse_diff(base, head):
    """{chemin: {"R": {ligne: '+'|' '}, "L": {ligne: '-'|' '}, "old": ancien chemin}}"""
    files, cur = {}, None
    old_path = None
    r = l = 0
    for raw in git("diff", "--no-color", "-M", "--unified=3", f"{base}...{head}").splitlines():
        if raw.startswith("diff --git "):
            cur, old_path = None, None
            continue
        if raw.startswith("--- "):
            old_path = None if raw == "--- /dev/null" else raw[6:] if raw.startswith("--- a/") else raw[4:]
            continue
        if raw.startswith("+++ "):
            new_path = old_path if raw == "+++ /dev/null" else raw[6:] if raw.startswith("+++ b/") else raw[4:]
            cur = files.setdefault(new_path, {"R": {}, "L": {}, "old": old_path, "deleted": raw == "+++ /dev/null"})
            continue
        if cur is None:
            continue
        m = HUNK_RE.match(raw)
        if m:
            l, r = int(m.group(1)), int(m.group(3))
            continue
        if raw.startswith("\\"):
            continue
        tag = raw[:1]
        if tag == "+":
            cur["R"][r] = "+"; r += 1
        elif tag == "-":
            cur["L"][l] = "-"; l += 1
        elif tag == " ":
            cur["R"][r] = " "; cur["L"][l] = " "; r += 1; l += 1
    return files


def ranges(lines):
    out, start, prev = [], None, None
    for n in sorted(lines):
        if start is None:
            start = prev = n
        elif n == prev + 1:
            prev = n
        else:
            out.append((start, prev)); start = prev = n
    if start is not None:
        out.append((start, prev))
    return ", ".join(f"{a}" if a == b else f"{a}-{b}" for a, b in out)


def code_at(rev, path, line):
    try:
        text = git("show", f"{rev}:{path}").splitlines()
        return text[line - 1].strip()[:110] if 0 < line <= len(text) else "<hors fichier>"
    except subprocess.CalledProcessError:
        return "<illisible>"


def cmd_map(a):
    files = parse_diff(a.base, a.head)
    for path, f in sorted(files.items()):
        if a.files and not any(fnmatch(path, p) for p in a.files):
            continue
        added = [n for n, t in f["R"].items() if t == "+"]
        tag = " (supprimé)" if f["deleted"] else f" (renommé depuis {f['old']})" if f["old"] and f["old"] != path else ""
        print(f"{sha(path)}  {path}{tag}")
        print(f"    + : {ranges(added) or '-'}")
        print(f"    R : {ranges(f['R']) or '-'}")


def check_ref(files, path, side, start, end, head, base, errors, label):
    f = files.get(path)
    if f is None:
        errors.append(f"{label} : {path} n'est pas dans le diff")
        return
    missing = [n for n in range(start, end + 1) if n not in f[side]]
    if missing:
        errors.append(f"{label} : {path} {side}{ranges(missing)} hors des hunks visibles")
        return
    rev, p = (head, path) if side == "R" else (base, f["old"] or path)
    kind = f[side][start]
    print(f"  ok  {label} -> {path}:{side}{start}{'-' + str(end) if end != start else ''} [{kind}] {code_at(rev, p, start)}")


def cmd_check(a):
    files = parse_diff(a.base, a.head)
    base = git("merge-base", a.base, a.head).strip()
    by_hash = {sha(p): p for p in files}
    errors, warnings = [], []

    if a.body:
        body = open(a.body, encoding="utf-8").read()
        print(f"Description : {a.body}")
        good_spans = []
        for i, m in enumerate(LINK_RE.finditer(body), 1):
            good_spans.append(m.span())
            label = f"lien {i}"
            if m["repo"] != a.repo:
                errors.append(f"{label} : dépôt {m['repo']} au lieu de {a.repo}")
            if a.pr and m["pr"] != str(a.pr):
                errors.append(f"{label} : PR {m['pr']} au lieu de {a.pr}")
            path = by_hash.get(m["hash"])
            if path is None:
                errors.append(f"{label} : hash {m['hash'][:12]}… ne correspond à aucun fichier du diff")
                continue
            if m["side2"] and m["side2"] != m["side"]:
                errors.append(f"{label} : plage à cheval sur L et R")
                continue
            start = int(m["line"]); end = int(m["end"] or start)
            check_ref(files, path, m["side"], start, end, a.head, base, errors, label)
        for m in ANY_DIFF_LINK_RE.finditer(body):
            if not any(s <= m.start() < e for s, e in good_spans):
                errors.append(f"ancre mal formée : {m.group(0)[:90]}")

        section = ""
        in_mermaid = False
        for line in body.splitlines():
            if line.startswith("```"):
                in_mermaid = not in_mermaid
            if in_mermaid:
                continue
            if line.startswith("#") or line.startswith("**"):
                section = re.sub(r"[#*]", "", line).strip()
                continue
            item = re.match(r"\s*(?:[-*]|\d+\.)\s+(.*)", line)
            if item and CITED_SECTIONS.search(section) and "/files#diff-" not in line:
                warnings.append(f"puce sans lien dans « {section} » : {item.group(1)[:80]}")

    if a.review:
        review = json.load(open(a.review, encoding="utf-8"))
        comments = review.get("comments", [])
        print(f"Review : {a.review} ({len(comments)} commentaires)")
        if review.get("event") != "COMMENT":
            errors.append(f"review : event {review.get('event')!r}, attendu 'COMMENT'")
        head_sha = git("rev-parse", a.head).strip()
        if review.get("commit_id") not in (None, head_sha):
            errors.append(f"review : commit_id {review.get('commit_id')} différent de {head_sha}")
        if not 3 <= len(comments) <= 8:
            warnings.append(f"review : {len(comments)} commentaires (cible 3 à 8)")
        for i, c in enumerate(comments, 1):
            side = {"RIGHT": "R", "LEFT": "L"}.get(c.get("side", "RIGHT"))
            if side is None or "line" not in c or "path" not in c:
                errors.append(f"commentaire {i} : champs path/line/side manquants ou invalides")
                continue
            start = int(c.get("start_line", c["line"]))
            if c.get("start_side", c.get("side", "RIGHT")) != c.get("side", "RIGHT"):
                errors.append(f"commentaire {i} : start_side différent de side")
                continue
            check_ref(files, c["path"], side, start, int(c["line"]), a.head, base, errors, f"commentaire {i}")

    for w in warnings:
        print(f"  ATTENTION  {w}")
    for e in errors:
        print(f"  ERREUR  {e}")
    print(f"{len(errors)} erreur(s), {len(warnings)} avertissement(s)")
    return 1 if errors else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("map")
    c = sub.add_parser("check")
    for p in (m, c):
        p.add_argument("--base", required=True)
        p.add_argument("--head", default="HEAD")
    m.add_argument("--files", nargs="*")
    c.add_argument("--repo", required=True)
    c.add_argument("--pr")
    c.add_argument("--body")
    c.add_argument("--review")
    a = ap.parse_args()
    sys.exit(cmd_map(a) if a.cmd == "map" else cmd_check(a))


if __name__ == "__main__":
    main()
