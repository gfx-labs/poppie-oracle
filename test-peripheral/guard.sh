#!/usr/bin/env bash
# Guard: audited code and the default build are unchanged vs tag v1-bsc.
# Usage: bash test-peripheral/guard.sh   (from the repo root)
set -euo pipefail
export PATH="$HOME/.foundry/bin:$PATH" FOUNDRY_DISABLE_NIGHTLY_WARNING=1
TAG=v1-bsc
cd "$(git rev-parse --show-toplevel)"

echo "[1/3] git diff of audited files vs $TAG"
git diff --exit-code "$TAG" -- src/PoppieEulerOracle.sol src/PoppieEulerAdapter.sol src/interfaces src/vendor

echo "[2/3] [profile.default] block vs $TAG"
# trailing blank lines are dropped (the tag file ends right after the block)
block() { awk '/^\[profile\.default\]/{p=1} /^# ──|^\[profile\.eval/{p=0} p' | awk 'NF{for(;n>0;n--)print "";print;next}{n++}'; }
diff <(git show "$TAG:foundry.toml" | block) <(block < foundry.toml)

echo "[3/3] oracle + adapter bytecode vs $TAG build"
WT=cache/guard-$TAG
if [ ! -d "$WT/src" ]; then
  rm -rf "$WT" && mkdir -p "$WT"
  git archive "$TAG" | tar -x -C "$WT"
  rm -rf "$WT/lib" && cp -al lib "$WT/lib"  # hardlinks: keeps remapping paths relative
fi
# force-rebuild src/ in both trees: a stale cache can carry old metadata
forge build --force src >/dev/null
(cd "$WT" && forge build --force src >/dev/null)
for c in PoppieEulerOracle PoppieEulerAdapter; do
  a=$(forge inspect "$c" bytecode)
  b=$(cd "$WT" && forge inspect "$c" bytecode)
  [ "$a" = "$b" ] || { echo "bytecode mismatch: $c"; exit 1; }
  echo "  $c bytecode identical (${#a} hex chars)"
done
echo "GUARD OK"
