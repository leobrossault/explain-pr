#!/usr/bin/env python3
"""Brouillon de review GitHub (state PENDING) : visible du seul auteur, sans
notification, tant qu'il n'est pas soumis.

  review.py find    --repo o/r --pr N
      Brouillon déjà ouvert par l'utilisateur courant (GitHub n'en permet qu'un).
  review.py draft   --repo o/r --pr N --body body.md --review review.json
      Crée le brouillon : le récit en corps, les commentaires sur les lignes.
  review.py submit  --repo o/r --pr N --id ID [--body texte]
      Soumet le brouillon en COMMENT (le corps peut être remplacé à la soumission).
  review.py discard --repo o/r --pr N --id ID
      Supprime le brouillon et ses commentaires.
"""
import argparse
import json
import os
import subprocess
import sys


def record_head(body_path, commit_id):
    """Write the narrated head next to body.md, as last-head.

    The SessionStart catch-up hook compares the PR's current head against these files to
    decide whether the draft is stale. Recording it here rather than asking the model to
    do it keeps the two in step. Best effort: never fail a successful draft over this.
    """
    if not body_path or not commit_id:
        return
    try:
        state_dir = os.path.dirname(os.path.abspath(body_path))
        os.makedirs(state_dir, exist_ok=True)
        with open(os.path.join(state_dir, "last-head"), "w", encoding="utf-8") as fh:
            fh.write(commit_id + "\n")
    except OSError as exc:
        print(f"note : head non enregistré ({exc})", file=sys.stderr)


def gh(method, path, payload=None):
    cmd = ["gh", "api", "--method", method, path]
    if payload is not None:
        cmd += ["--input", "-"]
    res = subprocess.run(cmd, input=json.dumps(payload) if payload is not None else None,
                         capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"gh api {method} {path} a échoué : {res.stderr.strip() or res.stdout.strip()}")
    return json.loads(res.stdout) if res.stdout.strip() else None


def pending(repo, pr):
    me = gh("GET", "user")["login"]
    reviews = gh("GET", f"repos/{repo}/pulls/{pr}/reviews?per_page=100")
    return [r for r in reviews if r["state"] == "PENDING" and r["user"]["login"] == me]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["find", "draft", "submit", "discard"])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--pr", required=True)
    ap.add_argument("--id")
    ap.add_argument("--body")
    ap.add_argument("--review")
    a = ap.parse_args()
    base = f"repos/{a.repo}/pulls/{a.pr}/reviews"

    if a.action == "find":
        for r in pending(a.repo, a.pr):
            print(r["id"], r["html_url"])
        return

    if a.action == "draft":
        existing = pending(a.repo, a.pr)
        if existing:
            sys.exit(f"Un brouillon existe déjà (id {existing[0]['id']}) : le supprimer ou le soumettre d'abord.")
        review = json.load(open(a.review, encoding="utf-8"))
        review.pop("event", None)  # sans event, la review reste PENDING
        review["body"] = open(a.body, encoding="utf-8").read()
        r = gh("POST", base, review)
        record_head(a.body, review.get("commit_id"))
        print(f"brouillon {r['id']} ({r['state']}) : https://github.com/{a.repo}/pull/{a.pr}/files")
        return

    if not a.id:
        sys.exit("--id requis")
    if a.action == "submit":
        payload = {"event": "COMMENT"}
        if a.body:
            payload["body"] = a.body
        r = gh("POST", f"{base}/{a.id}/events", payload)
        print(f"review {r['id']} soumise ({r['state']}) : {r['html_url']}")
    else:
        gh("DELETE", f"{base}/{a.id}")
        print(f"brouillon {a.id} supprimé")


if __name__ == "__main__":
    main()
