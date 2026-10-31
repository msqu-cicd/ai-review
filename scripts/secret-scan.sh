#!/usr/bin/env bash
# Secret gate: nothing reaches the model while it may contain a secret.
#
# Usage: secret-scan.sh MODE TARGET EXCLUDE_GLOBS_CSV OUT_DIR
#   MODE    diff  -> TARGET is a unified diff file, scanned via `gitleaks stdin`
#           tree  -> TARGET is a checkout directory; excluded globs are deleted from it,
#                    then the tree is scanned via `gitleaks dir`
#   OUT_DIR holds bin/gitleaks, gitleaks.json and, on findings, skip-reason.txt
#
# Exit codes: 0 clean, 1 findings (skip-reason.txt written), 2 bad arguments or an exclude
# glob that is absolute or contains "..", 3 install or scanner failure.
# Env: GITLEAKS_BIN overrides the binary (skips the download), GITLEAKS_VERSION the pin.
set -euo pipefail

GITLEAKS_VERSION=${GITLEAKS_VERSION:-8.30.1} # renovate: datasource=github-releases depName=gitleaks/gitleaks
GITLEAKS_BASE_URL="https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}"

usage() { echo "usage: secret-scan.sh diff|tree TARGET EXCLUDE_GLOBS_CSV OUT_DIR" >&2; exit 2; }

[[ $# -eq 4 ]] || usage
mode=$1 target=$2 globs=$3 out=$4
[[ $mode == diff || $mode == tree ]] || usage
mkdir -p "$out"

# validate_globs CSV: refuse anything that could reach outside the checkout.
validate_globs() {
  local IFS=, glob
  for glob in $1; do
    [[ -z $glob ]] && continue
    if [[ $glob == /* || $glob == *..* ]]; then
      echo "secret-scan.sh: refusing exclude path '$glob' (absolute or contains ..)" >&2
      exit 2
    fi
  done
}

# remove_excluded DIR CSV: delete matching paths inside DIR, then prune directories left
# empty by that (never inside .git).
remove_excluded() {
  local dir=$1 csv=$2
  (
    cd "$dir"
    shopt -s nullglob globstar dotglob
    local IFS=, glob
    for glob in $csv; do
      [[ -z $glob ]] && continue
      IFS=' '
      # shellcheck disable=SC2086
      for path in $glob; do
        [[ $path == .git || $path == .git/* ]] && continue
        rm -rf -- "$path"
        echo "secret-scan.sh: removed excluded path $path"
      done
      IFS=,
    done
  )
  find "$dir" -mindepth 1 -type d -empty -not -path "$dir/.git" -not -path "$dir/.git/*" -delete
}

# install_gitleaks OUT_DIR: pinned release, verified against the published checksums.
install_gitleaks() {
  local bin="$1/bin/gitleaks" tmp tarball="gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz"
  if [[ -x $bin ]]; then
    printf '%s\n' "$bin"
    return 0
  fi
  tmp=$(mktemp -d)
  if ! curl -fsSL --retry 2 -o "$tmp/$tarball" "$GITLEAKS_BASE_URL/$tarball" \
     || ! curl -fsSL --retry 2 -o "$tmp/checksums.txt" "$GITLEAKS_BASE_URL/gitleaks_${GITLEAKS_VERSION}_checksums.txt"; then
    echo "secret-scan.sh: gitleaks download failed" >&2
    rm -rf "$tmp"
    exit 3
  fi
  if ! (cd "$tmp" && sha256sum -c --ignore-missing --quiet checksums.txt); then
    echo "secret-scan.sh: gitleaks checksum mismatch for $tarball" >&2
    rm -rf "$tmp"
    exit 3
  fi
  mkdir -p "$1/bin"
  tar -xzf "$tmp/$tarball" -C "$1/bin" gitleaks
  rm -rf "$tmp"
  printf '%s\n' "$bin"
}

validate_globs "$globs"

if [[ $mode == tree ]]; then
  [[ -d $target ]] || { echo "secret-scan.sh: $target is not a directory" >&2; exit 2; }
  remove_excluded "$target" "$globs"
else
  [[ -f $target ]] || { echo "secret-scan.sh: $target is not a file" >&2; exit 2; }
fi

gitleaks=${GITLEAKS_BIN:-$(install_gitleaks "$out")}
report="$out/gitleaks.json"
rm -f "$report"

rc=0
if [[ $mode == diff ]]; then
  "$gitleaks" stdin --no-banner --redact --exit-code 1 --report-format json --report-path "$report" < "$target" || rc=$?
else
  "$gitleaks" dir "$target" --no-banner --redact --exit-code 1 --report-format json --report-path "$report" || rc=$?
fi

case $rc in
  0)
    echo "secret-scan.sh: clean ($mode)"
    exit 0
    ;;
  1)
    where="the diff"
    if [[ -s $report ]]; then
      files=$(jq -r '[.[] | .File // empty] | unique | map(select(length > 0)) | join(", ")' "$report")
      [[ -n $files ]] && where=$files
    fi
    printf 'AI review skipped: secret-like content in %s\n' "$where" > "$out/skip-reason.txt"
    echo "secret-scan.sh: findings in $where" >&2
    exit 1
    ;;
  *)
    echo "secret-scan.sh: gitleaks exited $rc" >&2
    exit 3
    ;;
esac
