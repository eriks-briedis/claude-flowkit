#!/usr/bin/env bash
# Exercises pr-worktree.sh against synthetic repositories. `gh` is stubbed —
# its only job in `add` is reporting the PR's base branch — but everything else
# is real git: a bare remote, commits published to refs/pull/<n>/head, worktree
# creation, merge-base, force-push handling, idempotency, teardown.
#
#   bash scripts/test-pr-worktree.sh
#
# Needs git, jq, and a writable TMPDIR. Nothing else, and it touches nothing
# outside its own scratch directory.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd -P)/pr-worktree.sh"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pr-worktree-test.XXXXXX")"
PASS=0
FAIL=0

trap 'chmod -R u+w "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

ok()  { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
section() { printf '\n=== %s ===\n' "$1"; }

# Every fixture assertion is fatal. A harness that reports passes against a
# fixture that never built is worse than one that reports failures.
fixture() {
  [ -e "$1" ] || { printf 'FIXTURE BROKEN: %s missing\n' "$1" >&2; exit 2; }
}

# --- gh stub -----------------------------------------------------------------
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
# pr-worktree.sh only ever calls `gh pr view <n> --repo <url> --json ...`.
if [ "${GH_STUB_FAIL:-0}" = "1" ]; then
  echo "could not resolve to a PullRequest with the number of 7" >&2
  exit 1
fi
[ "${GH_STUB_WARN:-0}" = "1" ] && echo "gh: a new release is available" >&2
printf '{"baseRefName":"%s","state":"%s","isCrossRepository":%s}\n' \
  "${GH_STUB_BASE:-main}" "${GH_STUB_STATE:-OPEN}" "${GH_STUB_XREPO:-false}"
STUB
chmod +x "$ROOT/bin/gh"
export PATH="$ROOT/bin:$PATH"

# --- fixture builder ---------------------------------------------------------
# Builds a bare remote plus a reviewer clone at <dir>/work and an author clone
# at <dir>/author. PR 7 is published to refs/pull/7/head only — no branch on the
# remote — which is exactly how a fork PR appears to a reviewer.
make_lab() {
  local dir="$1"
  mkdir -p "$dir"
  # -b main so the bare repo's HEAD matches the branch we push; otherwise the
  # author clone below has nothing to check out.
  git init --bare -q -b main "$dir/remote.git"
  git init -q -b main "$dir/work"
  git -C "$dir/work" config user.email t@t.t
  git -C "$dir/work" config user.name t
  git -C "$dir/work" remote add origin "$dir/remote.git"

  echo "base line 1" > "$dir/work/app.txt"
  git -C "$dir/work" add app.txt
  git -C "$dir/work" commit -qm "base commit"
  BASE_SHA=$(git -C "$dir/work" rev-parse HEAD)
  git -C "$dir/work" push -q origin main

  git -C "$dir/work" checkout -q -b feature
  echo "feature line" >> "$dir/work/app.txt"
  git -C "$dir/work" commit -qam "feature commit 1"
  echo "more" >> "$dir/work/app.txt"
  git -C "$dir/work" commit -qam "feature commit 2"
  PR_SHA=$(git -C "$dir/work" rev-parse HEAD)
  git -C "$dir/work" push -q origin "HEAD:refs/pull/7/head"

  # The base moves after the PR branched. A stale base ref gives a wrong
  # merge-base, which is what the forced refspec in `add` guards against.
  git -C "$dir/work" checkout -q main
  echo "base line 2" >> "$dir/work/app.txt"
  git -C "$dir/work" commit -qam "base moves on"
  git -C "$dir/work" push -q origin main
  NEW_BASE_SHA=$(git -C "$dir/work" rev-parse HEAD)
  git -C "$dir/work" branch -qD feature

  # Everything that publishes PR commits from here on runs in a separate clone.
  # The reviewer's repo gets deliberately dirtied and must stay that way — a
  # test-side commit in it would eat the state the assertions check.
  git clone -q "$dir/remote.git" "$dir/author"
  git -C "$dir/author" config user.email a@a.a
  git -C "$dir/author" config user.name a
}

LAB="$ROOT/main"
make_lab "$LAB"
fixture "$LAB/remote.git/HEAD"
fixture "$LAB/work/app.txt"
fixture "$LAB/author/app.txt"
[ -n "${PR_SHA:-}" ] && [ -n "${BASE_SHA:-}" ] && [ -n "${NEW_BASE_SHA:-}" ] ||
  { echo "FIXTURE BROKEN: shas unset" >&2; exit 2; }
cd "$LAB/work" || exit 2

section "add against a DIRTY working tree"

git add app.txt                       # a staged change ...
echo "unstaged on top" >> app.txt     # ... with an unstaged one on top
echo "scratch" > untracked.txt
DIRTY_STATUS=$(git status --porcelain)
DIRTY_INDEX=$(git diff --cached --stat)
DIRTY_HEAD=$(git rev-parse HEAD)

OUT=$("$SCRIPT" add 7 2>&1); RC=$?
check "add exits 0"                 "$RC" "0"
check "add reports ok"              "$(jq -r '.ok' <<<"$OUT")" "true"
check "add reports the PR number"   "$(jq -r '.pr' <<<"$OUT")" "7"
check "add reports base_ref"        "$(jq -r '.base_ref' <<<"$OUT")" "main"
check "add reports head_sha"        "$(jq -r '.head_sha' <<<"$OUT")" "$PR_SHA"
check "add reports base_sha"        "$(jq -r '.base_sha' <<<"$OUT")" "$NEW_BASE_SHA"
check "add reports merge_base"      "$(jq -r '.merge_base' <<<"$OUT")" "$BASE_SHA"
check "add reports PR state"        "$(jq -r '.state' <<<"$OUT")" "OPEN"
check "first add is not a reuse"    "$(jq -r '.reused' <<<"$OUT")" "false"

WT=$(jq -r '.path' <<<"$OUT")
fixture "$WT"
check "worktree lives in git dir"   "$(basename "$(dirname "$(dirname "$WT")")")" "flowkit"
check "worktree HEAD is PR head"    "$(git -C "$WT" rev-parse HEAD)" "$PR_SHA"
# rev-parse --symbolic-full-name distinguishes "detached" from "path is broken";
# a `symbolic-ref || echo detached` idiom reports detached for a missing dir too.
check "worktree is detached"        "$(git -C "$WT" rev-parse --symbolic-full-name HEAD 2>/dev/null || echo ERR)" "HEAD"
check "PR content is checked out"   "$(grep -c 'feature line' "$WT/app.txt")" "1"

# The point of the whole design.
check "main tree status untouched"  "$(git status --porcelain)" "$DIRTY_STATUS"
check "main tree index untouched"   "$(git diff --cached --stat)" "$DIRTY_INDEX"
check "main tree HEAD untouched"    "$(git rev-parse HEAD)" "$DIRTY_HEAD"
check "main tree still on main"     "$(git rev-parse --abbrev-ref HEAD)" "main"
check "worktree absent from status" "$(git status --porcelain | grep -c flowkit || true)" "0"

section "add writes only inside refs/flowkit"

check "head ref namespaced"         "$(jq -r '.ref' <<<"$OUT")" "refs/flowkit/head/pr-7"
check "base ref namespaced"         "$(jq -r '.base_local_ref' <<<"$OUT")" "refs/flowkit/base/pr-7"

# The fixture's own pushes created refs/remotes/origin/*; what matters is that
# `add` leaves that namespace exactly as it found it.
REMOTES_BEFORE=$(git for-each-ref --format='%(refname) %(objectname)' refs/remotes/)
"$SCRIPT" add 12 >/dev/null 2>&1 || true
check "add leaves refs/remotes be" "$(git for-each-ref --format='%(refname) %(objectname)' refs/remotes/)" "$REMOTES_BEFORE"
"$SCRIPT" remove 12 >/dev/null 2>&1

# A branch literally named HEAD is legal, and a forced fetch into
# refs/remotes/origin/HEAD writes through that symref onto origin/main.
git -C "$LAB/author" checkout -q -b poison "$BASE_SHA"
echo poison > "$LAB/author/poison.txt"
git -C "$LAB/author" add poison.txt
git -C "$LAB/author" commit -qm "poison"
git -C "$LAB/author" push -q origin "HEAD:refs/heads/HEAD"
git -C "$LAB/author" push -q origin "HEAD:refs/pull/31/head"
git update-ref refs/remotes/origin/main "$NEW_BASE_SHA"
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
OUT_P=$(GH_STUB_BASE=HEAD "$SCRIPT" add 31 2>&1)
check "base named HEAD still works" "$(jq -r '.ok' <<<"$OUT_P")" "true"
check "origin/main not clobbered"   "$(git rev-parse refs/remotes/origin/main)" "$NEW_BASE_SHA"
check "origin/HEAD symref intact"   "$(git symbolic-ref refs/remotes/origin/HEAD)" "refs/remotes/origin/main"
"$SCRIPT" remove 31 >/dev/null

section "diff against the base resolves inside the worktree"

MB=$(jq -r '.merge_base' <<<"$OUT")
check "diff sees the PR's file"     "$(git -C "$WT" diff --name-only "$MB"..HEAD)" "app.txt"
check "commit range is the PR's"    "$(git -C "$WT" log --oneline "$MB"..HEAD | wc -l | tr -d ' ')" "2"

section "idempotency and refresh"

OUT2=$("$SCRIPT" add 7)
check "second add reports reuse"    "$(jq -r '.reused' <<<"$OUT2")" "true"
check "second add still ok"         "$(jq -r '.ok' <<<"$OUT2")" "true"

git -C "$LAB/author" checkout -q -b feature2 "$PR_SHA"
echo "round two" >> "$LAB/author/app.txt"
git -C "$LAB/author" commit -qam "review round 2"
PR_SHA2=$(git -C "$LAB/author" rev-parse HEAD)
git -C "$LAB/author" push -q origin "HEAD:refs/pull/7/head" --force

OUT3=$("$SCRIPT" add 7)
check "add picks up new commits"    "$(jq -r '.head_sha' <<<"$OUT3")" "$PR_SHA2"
check "worktree moved to new head"  "$(git -C "$WT" rev-parse HEAD)" "$PR_SHA2"

# A force-push that rewrites history: non-fast-forward for the fetch and for
# the worktree checkout.
git -C "$LAB/author" checkout -q -b feature3 "$BASE_SHA"
echo "rewritten" >> "$LAB/author/app.txt"
git -C "$LAB/author" commit -qam "force-pushed rewrite"
PR_SHA3=$(git -C "$LAB/author" rev-parse HEAD)
git -C "$LAB/author" push -q origin "HEAD:refs/pull/7/head" --force

OUT4=$("$SCRIPT" add 7)
check "force-push still resolves"   "$(jq -r '.ok' <<<"$OUT4")" "true"
check "head follows force-push"     "$(jq -r '.head_sha' <<<"$OUT4")" "$PR_SHA3"
check "worktree follows too"        "$(git -C "$WT" rev-parse HEAD)" "$PR_SHA3"
check "no leftover PR-2 content"    "$(grep -c 'round two' "$WT/app.txt" || true)" "0"

section "list"

LIST=$("$SCRIPT" list)
check "list reports ok"             "$(jq -r '.ok' <<<"$LIST")" "true"
check "list returns one entry"      "$(jq '.worktrees | length' <<<"$LIST")" "1"
check "list reports the PR"         "$(jq -r '.worktrees[0].pr' <<<"$LIST")" "7"
check "list reports head_sha"       "$(jq -r '.worktrees[0].head_sha' <<<"$LIST")" "$PR_SHA3"

section "a second PR in parallel"

git -C "$LAB/author" checkout -q -b other "$BASE_SHA"
echo "other work" > "$LAB/author/other.txt"
git -C "$LAB/author" add other.txt
git -C "$LAB/author" commit -qm "other PR"
git -C "$LAB/author" push -q origin "HEAD:refs/pull/12/head"

OUT5=$("$SCRIPT" add 12)
WT12=$(jq -r '.path' <<<"$OUT5")
check "second PR adds cleanly"      "$(jq -r '.ok' <<<"$OUT5")" "true"
fixture "$WT12"
check "two worktrees coexist"       "$(jq '.worktrees | length' <<<"$("$SCRIPT" list)")" "2"
check "PR 7 unaffected by PR 12"    "$(git -C "$WT" rev-parse HEAD)" "$PR_SHA3"
check "each PR has its own tree"    "$([ -f "$WT12/other.txt" ] && echo yes || echo no)" "yes"
check "PR 12 tree lacks PR 7 file"  "$([ -f "$WT/other.txt" ] && echo yes || echo no)" "no"
check "main tree still dirty-same"  "$(git status --porcelain)" "$DIRTY_STATUS"

section "concurrent add — what /pr-review-parallel actually does"

"$SCRIPT" remove --all >/dev/null
for n in 7 12; do
  ( "$SCRIPT" add "$n" > "$ROOT/c.$n" 2>&1; echo $? > "$ROOT/rc.$n" ) &
done
wait
for n in 7 12; do
  check "concurrent add $n: rc"     "$(cat "$ROOT/rc.$n")" "0"
  check "concurrent add $n: ok"     "$(jq -r '.ok' < "$ROOT/c.$n")" "true"
done
check "both worktrees present"      "$(jq '.worktrees | length' <<<"$("$SCRIPT" list)")" "2"

section "remove"

OUT6=$("$SCRIPT" remove 12); RC=$?
check "remove exits 0"              "$RC" "0"
check "remove reports ok"           "$(jq -r '.ok' <<<"$OUT6")" "true"
check "remove reports removed"      "$(jq -r '.removed' <<<"$OUT6")" "true"
check "worktree dir is gone"        "$([ -e "$WT12" ] && echo yes || echo no)" "no"
check "head ref is gone"            "$(git rev-parse --verify --quiet refs/flowkit/head/pr-12 >/dev/null 2>&1 && echo yes || echo no)" "no"
check "base ref is gone"            "$(git rev-parse --verify --quiet refs/flowkit/base/pr-12 >/dev/null 2>&1 && echo yes || echo no)" "no"

OUT7=$("$SCRIPT" remove 12); RC7=$?
check "remove is idempotent (rc)"   "$RC7" "0"
check "remove is idempotent (ok)"   "$(jq -r '.ok' <<<"$OUT7")" "true"
check "second remove: nothing"      "$(jq -r '.removed' <<<"$OUT7")" "false"

section "a worktree the user locked is never touched"

"$SCRIPT" add 12 >/dev/null
WT12=$(jq -r '.worktrees[] | select(.pr == 12) | .path' <<<"$("$SCRIPT" list)")
fixture "$WT12"
git worktree lock "$WT12"           # a lock with no flowkit reason: the user's
E=$("$SCRIPT" remove 12 2>/dev/null); RC=$?
check "user lock: rc != 0"          "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
check "user lock: ok false"         "$(jq -r '.ok' <<<"$E")" "false"
check "user lock: reason"           "$(jq -r '.reason' <<<"$E")" "held_by_another_run"
check "user lock: says why"         "$(jq -r '.message' <<<"$E" | grep -c 'locked outside flowkit')" "1"
check "user lock: no bool leak"     "$(jq -r 'has("removed")' <<<"$E")" "false"
check "user lock: still there"      "$([ -e "$WT12" ] && echo yes || echo no)" "yes"

E=$("$SCRIPT" remove --all 2>/dev/null); RC=$?
check "user lock: --all rc is 3"    "$RC" "3"
check "user lock: --all ok false"   "$(jq -r '.ok' <<<"$E")" "false"
check "user lock: --all skipped it" "$(jq -r '.skipped[0].pr' <<<"$E")" "12"
check "user lock: survives --all"   "$([ -e "$WT12" ] && echo yes || echo no)" "yes"

E=$("$SCRIPT" remove 12 --force 2>/dev/null); RC=$?
check "--force breaks a user lock"  "$(jq -r '.removed' <<<"$E")" "true"
check "--force: worktree gone"      "$([ -e "$WT12" ] && echo yes || echo no)" "no"
"$SCRIPT" remove --all >/dev/null

section "a removal that fails must not report success"

# A read-only parent makes the unlink fail. Root ignores the permission bit.
if [ "$(id -u)" != "0" ]; then
  "$SCRIPT" add 12 >/dev/null
  WTROOT="$LAB/work/.git/flowkit/worktrees"
  chmod a-w "$WTROOT"
  E=$("$SCRIPT" remove 12 2>/dev/null); RC=$?
  chmod u+w "$WTROOT"
  check "failed remove: rc != 0"    "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
  check "failed remove: ok false"   "$(jq -r '.ok' <<<"$E")" "false"
  check "failed remove: reason"     "$(jq -r '.reason' <<<"$E")" "worktree_remove_failed"
  check "failed remove: no leak"    "$(jq -r 'has("removed")' <<<"$E")" "false"
  "$SCRIPT" remove --all >/dev/null
else
  printf '  SKIP running as root\n'
fi

section "concurrent runs must not tear down each other's worktrees"

RUN_A=$(jq -r '.run' <<<"$("$SCRIPT" run-id)")
RUN_B=$(jq -r '.run' <<<"$("$SCRIPT" run-id)")
check "run-id mints distinct ids"   "$([ "$RUN_A" != "$RUN_B" ] && echo yes || echo no)" "yes"

A7=$("$SCRIPT" add 7 --run "$RUN_A")
check "A claims PR 7"               "$(jq -r '.run' <<<"$A7")" "$RUN_A"
A7_PATH=$(jq -r '.path' <<<"$A7")
check "A's worktree is locked"      "$(jq -r '.worktrees[] | select(.pr == 7) | .locked' <<<"$("$SCRIPT" list)")" "true"
check "list names the owning run"   "$(jq -r '.worktrees[] | select(.pr == 7) | .run' <<<"$("$SCRIPT" list)")" "$RUN_A"
check "list marks the run live"     "$(jq -r '.worktrees[] | select(.pr == 7) | .run_live' <<<"$("$SCRIPT" list)")" "true"

B12=$("$SCRIPT" add 12 --run "$RUN_B")
check "B claims a different PR"     "$(jq -r '.ok' <<<"$B12")" "true"

# B's step-0 prune must leave A alone.
P=$("$SCRIPT" prune --run "$RUN_B")
check "B's prune spares A"          "$([ -e "$A7_PATH" ] && echo yes || echo no)" "yes"
check "B's prune defers ref sweep"  "$(jq -r '.ref_sweep_deferred' <<<"$P")" "true"
check "A's head ref survives"       "$(git rev-parse --verify --quiet refs/flowkit/head/pr-7 >/dev/null 2>&1 && echo yes || echo no)" "yes"

# B tries to take a PR A is reviewing.
E=$("$SCRIPT" add 7 --run "$RUN_B" 2>/dev/null); RC=$?
check "B can't steal A's PR"        "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
check "B gets a clear reason"       "$(jq -r '.reason' <<<"$E")" "held_by_another_run"
check "the message names run A"     "$(jq -r '.message' <<<"$E" | grep -c "$RUN_A")" "1"

# B's teardown removes only B's.
T=$("$SCRIPT" remove --all --run "$RUN_B"); RC=$?
check "B's teardown rc is 3"        "$RC" "3"
check "B's teardown ok false"       "$(jq -r '.ok' <<<"$T")" "false"
check "B removed its own"           "$(jq -r '.removed_count' <<<"$T")" "1"
check "B reported the skip"         "$(jq -r '.skipped[0].pr' <<<"$T")" "7"
check "B's skip names run A"        "$(jq -r '.skipped[0].reason' <<<"$T")" "held by live run $RUN_A"
check "A's worktree intact"         "$([ -e "$A7_PATH" ] && echo yes || echo no)" "yes"
check "A's checkout still valid"    "$(git -C "$A7_PATH" rev-parse --symbolic-full-name HEAD 2>/dev/null || echo ERR)" "HEAD"
check "A is the only one left"      "$(jq '.worktrees | length' <<<"$("$SCRIPT" list)")" "1"

# A's own teardown works and clears its marker.
T=$("$SCRIPT" remove --all --run "$RUN_A"); RC=$?
check "A's teardown rc is 0"        "$RC" "0"
check "A's teardown ok"             "$(jq -r '.ok' <<<"$T")" "true"
check "A removed its own"           "$(jq -r '.removed_count' <<<"$T")" "1"
check "nothing left at all"         "$(jq '.worktrees | length' <<<"$("$SCRIPT" list)")" "0"

section "a dead run holds nothing"

RUN_C=$(jq -r '.run' <<<"$("$SCRIPT" run-id)")
"$SCRIPT" add 7 --run "$RUN_C" >/dev/null
check "C's worktree is locked"      "$(jq -r '.worktrees[0].locked' <<<"$("$SCRIPT" list)")" "true"
rm -f "$LAB/work/.git/flowkit/runs/$RUN_C"   # the run died without tearing down
check "dead run is not live"        "$(jq -r '.worktrees[0].run_live' <<<"$("$SCRIPT" list)")" "false"
RUN_D=$(jq -r '.run' <<<"$("$SCRIPT" run-id)")
check "D reclaims a dead claim"     "$(jq -r '.ok' <<<"$("$SCRIPT" add 7 --run "$RUN_D" 2>/dev/null)")" "true"
check "D now owns it"               "$(jq -r '.worktrees[0].run' <<<"$("$SCRIPT" list)")" "$RUN_D"
check "D can tear it down"          "$(jq -r '.removed_count' <<<"$("$SCRIPT" remove --all --run "$RUN_D")")" "1"

section "--run is optional and changes nothing without it"

OUT=$("$SCRIPT" add 7)
check "no --run: run is null"       "$(jq -r '.run' <<<"$OUT")" "null"
check "no --run: not locked"        "$(jq -r '.worktrees[0].locked' <<<"$("$SCRIPT" list)")" "false"
check "no --run: any run removes"   "$(jq -r '.removed_count' <<<"$("$SCRIPT" remove --all)")" "1"
check "bad run id rejected"         "$(jq -r '.reason' <<<"$("$SCRIPT" add 7 --run 'a b/../c' 2>/dev/null)")" "bad_run_id"

section "prune"

"$SCRIPT" add 7 >/dev/null
"$SCRIPT" add 12 >/dev/null
PR12_PATH="$LAB/work/.git/flowkit/worktrees/pr-12"
fixture "$PR12_PATH"
rm -rf "$PR12_PATH"                                    # killed run: dir gone, metadata + refs left
mkdir -p "$LAB/work/.git/flowkit/worktrees/pr-99"      # leftover dir git never knew about
git update-ref refs/flowkit/head/pr-42 "$BASE_SHA"     # orphaned ref, no worktree

OUT8=$("$SCRIPT" prune)
check "prune reports ok"            "$(jq -r '.ok' <<<"$OUT8")" "true"
check "prune removes leftover dir"  "$([ -e "$LAB/work/.git/flowkit/worktrees/pr-99" ] && echo yes || echo no)" "no"
check "prune drops orphaned ref"    "$(git rev-parse --verify --quiet refs/flowkit/head/pr-42 >/dev/null 2>&1 && echo yes || echo no)" "no"
check "prune drops dead pr-12 refs" "$(git rev-parse --verify --quiet refs/flowkit/head/pr-12 >/dev/null 2>&1 && echo yes || echo no)" "no"
check "prune keeps live worktree"   "$(jq '.worktrees | length' <<<"$("$SCRIPT" list)")" "1"
check "prune deregistered pr-12"    "$(git worktree list --porcelain | grep -c 'pr-12' || true)" "0"
check "one prune pass is enough"    "$(jq -r '.ok' <<<"$("$SCRIPT" add 12)")" "true"

section "prune must not touch the user's own worktrees"

# Bare `git worktree prune` is repo-global and deregisters any worktree whose
# directory is missing — an unmounted drive, a bind mount, a half-finished move.
git -C "$LAB/work" branch -q myfeature main
git -C "$LAB/work" worktree add -q "$ROOT/user-wt" myfeature
fixture "$ROOT/user-wt"
mv "$ROOT/user-wt" "$ROOT/user-wt-detached"            # simulate the volume going away
"$SCRIPT" prune >/dev/null
mv "$ROOT/user-wt-detached" "$ROOT/user-wt"
check "user worktree survives"      "$(git -C "$ROOT/user-wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo BROKEN)" "myfeature"
check "still registered with git"   "$(git worktree list --porcelain | grep -c "$ROOT/user-wt" || true)" "1"
check "user worktree not in list"   "$(jq '.worktrees | map(select(.path | test("user-wt"))) | length' <<<"$("$SCRIPT" list)")" "0"
git -C "$LAB/work" worktree remove --force "$ROOT/user-wt"

section "add recovers from a killed run's debris"

"$SCRIPT" remove 7 >/dev/null
mkdir -p "$LAB/work/.git/flowkit/worktrees/pr-7"
echo junk > "$LAB/work/.git/flowkit/worktrees/pr-7/junk.txt"
OUT=$("$SCRIPT" add 7 2>&1)
check "add over debris: ok"         "$(jq -r '.ok' <<<"$OUT")" "true"
check "add over debris: not reuse"  "$(jq -r '.reused' <<<"$OUT")" "false"
check "debris is gone"              "$([ -e "$LAB/work/.git/flowkit/worktrees/pr-7/junk.txt" ] && echo yes || echo no)" "no"
check "PR content checked out"      "$([ -f "$(jq -r '.path' <<<"$OUT")/app.txt" ] && echo yes || echo no)" "yes"

section "remove --all"

OUT9=$("$SCRIPT" remove --all)
check "remove --all reports ok"     "$(jq -r '.ok' <<<"$OUT9")" "true"
check "remove --all count"          "$(jq -r '.removed_count' <<<"$OUT9")" "2"
check "list is empty after"         "$(jq '.worktrees | length' <<<"$("$SCRIPT" list)")" "0"
check "no flowkit refs remain"      "$(git for-each-ref --format='%(refname)' refs/flowkit/ | wc -l | tr -d ' ')" "0"
check "main tree survived it all"   "$(git status --porcelain)" "$DIRTY_STATUS"
check "main tree index survived"    "$(git diff --cached --stat)" "$DIRTY_INDEX"

section "remote resolution"

check "--remote name works"         "$(jq -r '.remote' <<<"$("$SCRIPT" add 7 --remote origin)")" "origin"
check "--remote=value works"        "$(jq -r '.remote' <<<"$("$SCRIPT" add 7 --remote=origin)")" "origin"
check "--remote needs a value"      "$(jq -r '.reason' <<<"$("$SCRIPT" add 7 --remote 2>/dev/null)")" "bad_args"
check "two PR numbers rejected"     "$(jq -r '.reason' <<<"$("$SCRIPT" add 7 9 2>/dev/null)")" "bad_args"
"$SCRIPT" remove --all >/dev/null

git remote rename origin upstream
check "sole remote, no origin"      "$(jq -r '.remote' <<<"$("$SCRIPT" add 7)")" "upstream"
"$SCRIPT" remove --all >/dev/null
git remote add extra "$LAB/remote.git"
check "two remotes, no origin"      "$(jq -r '.reason' <<<"$("$SCRIPT" add 7 2>/dev/null)")" "no_remote"
git remote remove extra
git remote rename upstream origin

section "symlinked repo path"

# `pwd` is logical and preserves symlinks; `git worktree list` reports physical
# paths. A logical root would make every flowkit worktree invisible to list,
# remove and prune, so teardown would silently no-op and leak.
mkdir -p "$ROOT/real"
ln -s "$ROOT/real" "$ROOT/link"
make_lab "$ROOT/real/lab"
fixture "$ROOT/link/lab/work/app.txt"
(
  cd "$ROOT/link/lab/work" || exit 2
  "$SCRIPT" add 7 >/dev/null
  L=$("$SCRIPT" list)
  check "symlinked: list sees it"   "$(jq '.worktrees | length' <<<"$L")" "1"
  R=$("$SCRIPT" remove --all)
  check "symlinked: removes it"     "$(jq -r '.removed_count' <<<"$R")" "1"
  check "symlinked: nothing leaks"  "$(find "$ROOT/real/lab/work/.git/flowkit/worktrees" -maxdepth 1 -name 'pr-*' 2>/dev/null | wc -l | tr -d ' ')" "0"
)

section "repo path containing a backslash"

# `awk -v` escape-processes its value, so a backslash in the path would arrive
# mangled and the prefix test would never match.
make_lab "$ROOT/back\\tslash"
(
  cd "$ROOT/back\\tslash/work" || exit 2
  "$SCRIPT" add 7 >/dev/null
  L=$("$SCRIPT" list)
  check "backslash: list sees it"   "$(jq '.worktrees | length' <<<"$L")" "1"
  P=$(jq -r '.worktrees[0].path' <<<"$L")
  "$SCRIPT" prune >/dev/null
  check "backslash: prune spares it" "$([ -e "$P" ] && echo yes || echo no)" "yes"
  check "backslash: removes it"     "$(jq -r '.removed_count' <<<"$("$SCRIPT" remove --all)")" "1"
)

section "repo path containing spaces"

make_lab "$ROOT/with spaces"
(
  cd "$ROOT/with spaces/work" || exit 2
  check "spaces: add ok"            "$(jq -r '.ok' <<<"$("$SCRIPT" add 7)")" "true"
  check "spaces: list sees it"      "$(jq '.worktrees | length' <<<"$("$SCRIPT" list)")" "1"
  check "spaces: removes it"        "$(jq -r '.removed_count' <<<"$("$SCRIPT" remove --all)")" "1"
)

section "error paths"

cd "$LAB/work" || exit 2
E=$("$SCRIPT" add abc 2>/dev/null); RC=$?
check "bad PR number: exit != 0"    "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
check "bad PR number: reason"       "$(jq -r '.reason' <<<"$E")" "bad_pr_number"
check "bad PR number: ok false"     "$(jq -r '.ok' <<<"$E")" "false"
check "zero rejected"               "$(jq -r '.reason' <<<"$("$SCRIPT" add 0 2>/dev/null)")" "bad_pr_number"
check "leading zeros rejected"      "$(jq -r '.reason' <<<"$("$SCRIPT" add 007 2>/dev/null)")" "bad_pr_number"
check "missing PR number: reason"   "$(jq -r '.reason' <<<"$("$SCRIPT" add 2>/dev/null)")" "bad_pr_number"

E=$("$SCRIPT" frobnicate 2>/dev/null); RC=$?
check "unknown subcommand: rc"      "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
check "unknown subcommand: reason"  "$(jq -r '.reason' <<<"$E")" "bad_args"
check "usage goes to stderr"        "$(jq -e . >/dev/null 2>&1 <<<"$E" && echo clean || echo mixed)" "clean"
check "list rejects extra args"     "$(jq -r '.reason' <<<"$("$SCRIPT" list 9 2>/dev/null)")" "bad_args"
check "prune rejects extra args"    "$(jq -r '.reason' <<<"$("$SCRIPT" prune --all 2>/dev/null)")" "bad_args"
check "remove rejects extra args"   "$(jq -r '.reason' <<<"$("$SCRIPT" remove 7 9 2>/dev/null)")" "bad_args"

E=$(GH_STUB_FAIL=1 "$SCRIPT" add 7 2>/dev/null); RC=$?
check "gh failure: exit != 0"       "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
check "gh failure: reason"          "$(jq -r '.reason' <<<"$E")" "gh_failed"
check "gh failure: keeps message"   "$(jq -r '.message' <<<"$E" | grep -c PullRequest)" "1"

# gh writes warnings to stderr on success; folding them into stdout would
# corrupt the JSON being parsed.
check "gh stderr noise tolerated"   "$(jq -r '.ok' <<<"$(GH_STUB_WARN=1 "$SCRIPT" add 7 2>/dev/null)")" "true"
"$SCRIPT" remove --all >/dev/null

check "bad remote: reason"          "$(jq -r '.reason' <<<"$("$SCRIPT" add 7 --remote nope 2>/dev/null)")" "no_remote"
check "no such PR ref: reason"      "$(jq -r '.reason' <<<"$("$SCRIPT" add 999 2>/dev/null)")" "fetch_failed"
check "missing base branch: reason" "$(jq -r '.reason' <<<"$(GH_STUB_BASE=gone "$SCRIPT" add 7 2>/dev/null)")" "fetch_failed"

mkdir -p "$ROOT/notarepo"
E=$(cd "$ROOT/notarepo" && "$SCRIPT" list 2>/dev/null); RC=$?
check "outside a repo: exit != 0"   "$([ "$RC" -ne 0 ] && echo yes || echo no)" "yes"
check "outside a repo: reason"      "$(jq -r '.reason' <<<"$E")" "not_a_repo"

"$SCRIPT" --help >/dev/null 2>&1
check "--help exits 0"              "$?" "0"

section "every subcommand emits one JSON object with .ok"

for c in "list" "prune" "remove 5" "remove --all"; do
  O=$($SCRIPT $c 2>/dev/null)
  if [ "$(jq -r '.ok' <<<"$O" 2>/dev/null)" = "true" ]; then ok "JSON .ok: $c"; else bad "JSON .ok: $c" "$O"; fi
done

section "repo-level invariants"

check "no GitHub writes anywhere" \
  "$(grep -rlE '^[[:space:]]*[^#|>*-][^|]*\b(gh pr (review|comment|create)|git (commit|push))\b' \
     "$REPO_ROOT/scripts" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "README documents the script" \
  "$([ "$(grep -c 'pr-worktree.sh' "$REPO_ROOT/README.md")" -ge 1 ] && echo yes || echo no)" "yes"

printf '\npassed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
