#!/usr/bin/env bash
# Lien profond vers une ligne de l'onglet « Files changed » d'une PR GitHub.
#
#   anchor.sh <owner/repo> <pr> <chemin> <ligne> [R|L] [ligne_fin]
#   anchor.sh --hash <chemin>
#
# L'ancre GitHub est diff-<sha256 hex du chemin>, suivie de R<n> (côté nouveau
# fichier) ou L<n> (côté ancien). Pour un fichier renommé, c'est le nouveau
# chemin. <pr> peut valoir {{PR}} tant que la PR n'existe pas encore.
set -euo pipefail

hash_path() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }

if [[ "${1:-}" == "--hash" ]]; then
  hash_path "$2"
  exit 0
fi

if [[ $# -lt 4 ]]; then
  sed -n '2,9p' "$0" >&2
  exit 2
fi

repo=$1 pr=$2 path=$3 line=$4 side=${5:-R} end=${6:-}
anchor="diff-$(hash_path "$path")${side}${line}"
[[ -n "$end" && "$end" != "$line" ]] && anchor+="-${side}${end}"
printf 'https://github.com/%s/pull/%s/files#%s\n' "$repo" "$pr" "$anchor"
