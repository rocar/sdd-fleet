#!/usr/bin/env bash
# plan-digest.sh <file>... — print a stable content digest of the concatenated files.
#
# THE single home of the ratification digest algorithm, shared by epic-ratify-record.sh
# (which records PLAN_DIGEST in RATIFICATION.md) and the epic-ratified-before-fanout hook
# (which re-validates it). Both MUST compute the digest identically, or an untampered plan
# would false-refuse — hence one helper, not two copies.
#
# Portable: shasum -a 256, else sha256sum, else cksum — the value need only be stable for a
# given content on a given machine, not cross-tool identical. The digest is over the bytes
# of the files concatenated IN ARGUMENT ORDER, so callers must pass them in the same order
# (plan.md then contracts.md).
#
# Any input that is missing/unreadable → exit 1 with no output, so a caller that does
# `d=$(plan-digest.sh ... || true)` sees an empty string and fails closed.
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: plan-digest.sh <file>..." >&2; exit 1; }
for f in "$@"; do
  [ -r "$f" ] || { echo "plan-digest: missing or unreadable: $f" >&2; exit 1; }
done

if command -v shasum >/dev/null 2>&1; then
  cat "$@" | shasum -a 256 | awk '{print $1}'
elif command -v sha256sum >/dev/null 2>&1; then
  cat "$@" | sha256sum | awk '{print $1}'
else
  cat "$@" | cksum | awk '{print $1"-"$2}'
fi
