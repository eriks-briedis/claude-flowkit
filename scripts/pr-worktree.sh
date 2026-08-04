#!/usr/bin/env bash
# Owns the git worktree lifecycle for reviewing PRs without touching the user's
# working tree. Backs /pr-review-parallel; usable standalone.
#
#   pr-worktree.sh run-id
#   pr-worktree.sh add <number> [--remote <name>] [--run <id>]
#   pr-worktree.sh remove <number> | remove --all   [--run <id>]
#   pr-worktree.sh list
#   pr-worktree.sh prune [--run <id>]
#
# Concurrent runs in one repository don't collide. A run mints an id with
# `run-id` and passes it to every call; each worktree it creates is locked with
# that id, and removal and pruning skip anything a *live* run holds. Because the
# claim is git's own on-disk lock state, it works between two Claude Code
# sessions that share no memory — which is exactly the case a note in a markdown
# document cannot cover. `--force` overrides, and a run whose marker has gone
# stale holds nothing.
#
# Worktrees live under <git-common-dir>/flowkit/worktrees/pr-<n>, checked out
# detached from refs/flowkit/head/pr-<n>, which is fetched from
# refs/pull/<n>/head so PRs from forks resolve the same as PRs from branches on
# the origin. Living inside the git dir means they never appear in `git status`
# and never need a .gitignore entry; detached means they never collide with the
# local branches `gh pr checkout` leaves behind for /pr-review-loop.
#
# `add` writes only inside refs/flowkit/* and <git-common-dir>/flowkit/. That
# includes the PR's base branch, fetched to refs/flowkit/base/pr-<n> rather than
# refs/remotes/<remote>/<base>: the base branch name comes from whoever opened
# the PR, `HEAD` is a legal branch name, and a forced update to
# refs/remotes/origin/HEAD writes straight through that symref onto the user's
# origin/main. Keeping every write in one namespace also means `prune` and
# `remove` can clean up completely.
#
# `add` does not write to the working tree of the repo it runs from — it fetches
# refs and creates a worktree elsewhere, nothing more. Reviewing a PR through
# this script therefore does not require a clean tree, which is the whole reason
# it exists.
#
# Every subcommand prints one JSON object with an `ok` field. Success exits 0.
# Failure prints {"ok": false, "reason": ..., "message": ...} and exits
# non-zero — unlike ticket-lookup.sh, where a miss is ordinary, a worktree that
# didn't get created is a real error the caller must stop on.
#
# Only `add` needs `gh` (for the PR's base branch). list/remove/prune are pure
# git, so cleanup still works when gh is unauthenticated or offline.
#
# Nothing here ever runs bare `git worktree prune`. That command is repo-global
# and deregisters *any* worktree whose directory is currently missing — an
# unmounted external drive, a devcontainer bind mount, a path the user is part
# way through moving. Reviewing someone's PR must not cost the user a worktree
# they built for their own work, so metadata cleanup is scoped by hand to
# directories under our own root.

set -uo pipefail

REF_PREFIX="refs/flowkit"

usage() {
  cat >&2 <<'EOF'
Usage:
  pr-worktree.sh run-id                           Mint a run id and mark the run live
  pr-worktree.sh add <number> [--remote <name>] [--run <id>]
                                                  Fetch the PR and create/refresh its worktree
  pr-worktree.sh remove <number> [--run <id>]     Remove one PR's worktree and its refs
  pr-worktree.sh remove --all [--run <id>]        Remove this run's review worktrees
  pr-worktree.sh list                             List flowkit review worktrees
  pr-worktree.sh prune [--run <id>]               Drop stale metadata, leftover dirs, orphaned refs

  --remote <name>   Remote to fetch from, and the repository `gh` is asked about.
                    Defaults to origin, or the only remote if the repo has
                    exactly one and no origin.
  --run <id>        Claim worktrees for this run, from `run-id`. Without it, add
                    creates an unlocked worktree that any run may reclaim.
  --force           Break locks, including a live run's. Accepted by add, remove
                    and prune.

Exit codes: 0 success, 1 error, 3 (remove --all only) partial — some worktrees
were skipped because another live run holds them; see `skipped` in the output.
EOF
}

# jq builds every payload so paths and git's error text get escaped properly.
# Its absence has to be reported without it, hence the one hand-written object.
if ! command -v jq >/dev/null 2>&1; then
  printf '{"ok": false, "reason": "no_jq", "message": "jq is required but not installed"}\n'
  exit 1
fi

fail() {
  jq -n --arg reason "$1" --arg message "$2" \
    '{ok: false, reason: $reason, message: $message}'
  exit "${3:-1}"
}

require_repo() {
  local common_dir
  common_dir=$(git rev-parse --git-common-dir 2>/dev/null) ||
    fail not_a_repo "not inside a git repository"
  # --git-common-dir answers relatively (".git") from the repo root, and every
  # path handed to a caller or baked into worktree metadata has to be absolute.
  # -P resolves symlinks: `git worktree list` reports physical paths, so a
  # logical one here would fail every prefix test in flowkit_worktrees() and
  # make our own worktrees invisible to list, remove, and prune.
  common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) ||
    fail not_a_repo "cannot resolve git directory"
  FLOWKIT_COMMON_DIR="$common_dir"
  WT_ROOT="$common_dir/flowkit/worktrees"
}

resolve_remote() {
  local requested="${1:-}"
  if [ -n "$requested" ]; then
    git remote get-url "$requested" >/dev/null 2>&1 ||
      fail no_remote "no remote named '$requested'"
    REMOTE="$requested"
    return
  fi
  if git remote get-url origin >/dev/null 2>&1; then
    REMOTE="origin"
    return
  fi
  local remotes count
  remotes=$(git remote)
  count=$(printf '%s\n' "$remotes" | grep -c . || true)
  [ "$count" != "0" ] || fail no_remote "this repository has no remotes"
  [ "$count" = "1" ] ||
    fail no_remote "no 'origin' remote; pass --remote to pick one of: $(printf '%s' "$remotes" | tr '\n' ' ')"
  REMOTE="$remotes"
}

validate_pr() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] ||
    fail bad_pr_number "PR number must be a positive integer without leading zeros, got '${1:-}'"
}

reject_extra_args() {
  [ $# -eq 0 ] || fail bad_args "unexpected argument '$1'"
}

# Registered worktrees under our root, as "path<TAB>sha<TAB>locked<TAB>reason"
# lines, where locked is 0 or 1. Anything the user created elsewhere is none of
# this script's business.
#
# The root goes through the environment rather than `awk -v`, which runs escape
# processing on its value: a repo path containing a backslash would arrive at
# awk mangled, the prefix test would never match, and list/remove/prune would
# quietly act as though the repo had no worktrees at all.
flowkit_worktrees() {
  FLOWKIT_WT_ROOT="$WT_ROOT/" awk '
    function flush() {
      if (path != "" && index(path, root) == 1) print path "\t" sha "\t" locked "\t" reason
      path = ""; sha = ""; locked = 0; reason = ""
    }
    BEGIN         { root = ENVIRON["FLOWKIT_WT_ROOT"] }
    /^worktree /  { flush(); path = substr($0, 10); next }
    /^HEAD /      { sha = substr($0, 6); next }
    /^locked/     { locked = 1; if (length($0) > 7) reason = substr($0, 8); next }
    /^$/          { flush(); next }
    END           { flush() }
  ' < <(git worktree list --porcelain 2>/dev/null)
}

worktree_field() {
  # $1 = path, $2 = 1-based column in flowkit_worktrees output
  local path sha locked reason
  while IFS=$'\t' read -r path sha locked reason; do
    if [ "$path" = "$1" ]; then
      case "$2" in
        2) printf '%s' "$sha" ;;
        3) printf '%s' "$locked" ;;
        4) printf '%s' "$reason" ;;
      esac
      return 0
    fi
  done < <(flowkit_worktrees)
  return 1
}

is_registered() {
  worktree_field "$1" 2 >/dev/null
}

pr_from_path() {
  local base
  base=$(basename "$1")
  printf '%s' "${base#pr-}"
}

# --- run ownership -----------------------------------------------------------
#
# A worktree created with --run is locked with the reason
#   flowkit run=<id> started=<epoch>
# and the run keeps a marker at <git-common-dir>/flowkit/runs/<id> holding its
# start epoch. Two things follow, and both are the point of the mechanism:
#
#   * The ownership record lives in git's own on-disk state, so a second
#     Claude Code session — which shares no memory with the first — sees it.
#   * Liveness is decided by the marker, not by the age of the lock. A run
#     parked for hours waiting on the user is still live and must not have its
#     worktrees taken; a run that died is not, and its worktrees are free, since
#     a worktree is derived state that rebuilds from refs/pull/<n>/head in
#     seconds. Age alone would get one of those two cases wrong whichever
#     threshold you picked.
#
# Nothing here ever breaks a live run's lock, or a lock the user placed by hand,
# without an explicit --force.

RUN_TTL=43200 # 12h; a marker older than this belongs to a run that isn't coming back

run_marker() { printf '%s/flowkit/runs/%s' "$FLOWKIT_COMMON_DIR" "$1"; }

touch_run_marker() {
  local marker
  marker=$(run_marker "$1")
  mkdir -p "$(dirname "$marker")" || return 1
  date -u +%s > "$marker"
}

# Run ids land in file paths and in a lock reason parsed on whitespace, so keep
# them to characters that can't turn into a path traversal or a second field.
validate_run_id() {
  [ -n "${1:-}" ] || return 0
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] ||
    fail bad_run_id "run id must match [A-Za-z0-9._-]+, got '$1'"
}

lock_reason_for() {
  printf 'flowkit run=%s started=%s' "$1" "$(date -u +%s)"
}

# Empty when the lock isn't ours — a user-placed lock has no flowkit prefix, and
# must be treated as untouchable rather than as an unowned worktree.
run_from_reason() {
  local r="$1"
  case "$r" in
    "flowkit run="*)
      r="${r#flowkit run=}"
      printf '%s' "${r%% *}"
      ;;
  esac
}

run_is_live() {
  local id="$1" marker started now
  [ -n "$id" ] || return 1
  marker=$(run_marker "$id")
  [ -f "$marker" ] || return 1
  started=$(cat "$marker" 2>/dev/null)
  [[ "$started" =~ ^[0-9]+$ ]] || return 1
  now=$(date -u +%s)
  [ $((now - started)) -lt "$RUN_TTL" ]
}

# Echoes a one-line explanation and returns 1 when $1 may not be touched by the
# run named in $2. FORCE=1 clears everything.
may_touch() {
  local path="$1" own_run="${2:-}" locked reason owner
  [ "${FORCE:-0}" = "1" ] && return 0
  locked=$(worktree_field "$path" 3 2>/dev/null) || return 0
  [ "$locked" = "1" ] || return 0
  reason=$(worktree_field "$path" 4)
  owner=$(run_from_reason "$reason")
  if [ -z "$owner" ]; then
    printf 'locked outside flowkit (%s)' "${reason:-no reason given}"
    return 1
  fi
  [ -n "$own_run" ] && [ "$owner" = "$own_run" ] && return 0
  if run_is_live "$owner"; then
    printf 'held by live run %s' "$owner"
    return 1
  fi
  return 0
}

# The scoped stand-in for `git worktree prune`, per the header note. Removes the
# admin directory of any worktree whose recorded path is under our root and no
# longer exists, and nothing else. A lock held by a live run is left alone.
prune_flowkit_metadata() {
  local admin gitdir tree reason owner
  [ -d "$FLOWKIT_COMMON_DIR/worktrees" ] || return 0
  for admin in "$FLOWKIT_COMMON_DIR"/worktrees/*; do
    [ -f "$admin/gitdir" ] || continue
    if [ -e "$admin/locked" ] && [ "${FORCE:-0}" != "1" ]; then
      reason=$(cat "$admin/locked" 2>/dev/null)
      owner=$(run_from_reason "$reason")
      # A lock we don't recognise, or one a live run holds, stays put.
      { [ -z "$owner" ] || run_is_live "$owner"; } && continue
    fi
    gitdir=$(cat "$admin/gitdir" 2>/dev/null) || continue
    tree="${gitdir%/.git}"
    case "$tree" in
      "$WT_ROOT"/*) [ -e "$tree" ] || rm -rf "$admin" ;;
    esac
  done
}

drop_refs_for_pr() {
  local pr="$1" ref
  for ref in "$REF_PREFIX/head/pr-$pr" "$REF_PREFIX/base/pr-$pr"; do
    if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
      git update-ref -d "$ref" 2>/dev/null || return 1
    fi
  done
}

cmd_add() {
  local pr="" remote_arg="" run_id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --remote)
        [ $# -ge 2 ] || fail bad_args "--remote needs a value"
        remote_arg="$2"
        shift 2
        ;;
      --remote=*)
        remote_arg="${1#--remote=}"
        shift
        ;;
      --run)
        [ $# -ge 2 ] || fail bad_args "--run needs a value"
        run_id="$2"
        shift 2
        ;;
      --run=*)
        run_id="${1#--run=}"
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        [ -z "$pr" ] || fail bad_args "unexpected argument '$1'"
        pr="$1"
        shift
        ;;
    esac
  done

  validate_pr "$pr"
  validate_run_id "$run_id"
  require_repo
  resolve_remote "$remote_arg"

  # Ownership is checked before the fetch, so a PR another run is reviewing
  # costs nothing to discover.
  local path="$WT_ROOT/pr-$pr" why
  if ! why=$(may_touch "$path" "$run_id"); then
    fail held_by_another_run \
      "PR #$pr is $why — wait for it, or pass --force to take it over"
  fi
  # Refresh the marker before any slow work: a run is live from the moment it
  # starts claiming worktrees, not from the moment the first one appears.
  [ -n "$run_id" ] && touch_run_marker "$run_id"

  command -v gh >/dev/null 2>&1 ||
    fail no_gh "gh is required to resolve the PR's base branch"

  # --repo pins gh to the same remote git fetches from. Without it gh applies
  # its own preference order (upstream, then github, then origin) and, in the
  # ordinary fork setup where origin is your fork, would answer about a
  # different repository than the one the pull ref is fetched from — silently
  # reviewing a different PR that happens to share the number.
  local remote_url meta gh_err message
  remote_url=$(git remote get-url "$REMOTE")
  gh_err=$(mktemp) || fail mktemp_failed "cannot create a temporary file"
  # stderr is kept separate rather than folded in with 2>&1: gh writes warnings
  # there on success too, and merging them corrupts the JSON being parsed.
  if ! meta=$(gh pr view "$pr" --repo "$remote_url" \
    --json baseRefName,state,isCrossRepository 2>"$gh_err"); then
    message=$(cat "$gh_err")
    rm -f "$gh_err"
    fail gh_failed "$message"
  fi
  rm -f "$gh_err"

  local base_ref
  base_ref=$(printf '%s' "$meta" | jq -r '.baseRefName // empty' 2>/dev/null)
  [ -n "$base_ref" ] ||
    fail no_base_ref "could not determine the base branch of PR #$pr from: $meta"

  local ref="$REF_PREFIX/head/pr-$pr"
  local base_local_ref="$REF_PREFIX/base/pr-$pr"

  # Both refspecs forced: a force-push on the PR makes its head non-fast-forward
  # against whatever a previous run left behind, and the base branch moves on its
  # own between runs. Either one stale gives a wrong merge-base.
  local out
  out=$(git fetch --no-tags "$REMOTE" \
    "+refs/pull/$pr/head:$ref" \
    "+refs/heads/$base_ref:$base_local_ref" 2>&1) ||
    fail fetch_failed "$out"

  local head_sha base_sha merge_base reused=false
  head_sha=$(git rev-parse "$ref" 2>/dev/null) ||
    fail fetch_failed "fetched refs/pull/$pr/head but $ref does not resolve"
  base_sha=$(git rev-parse "$base_local_ref" 2>/dev/null) ||
    fail fetch_failed "fetched $base_ref but $base_local_ref does not resolve"
  merge_base=$(git merge-base "$base_sha" "$head_sha" 2>/dev/null) ||
    fail no_merge_base "PR #$pr head and $base_ref share no common ancestor"

  local registered=false
  is_registered "$path" && registered=true

  if [ "$registered" = true ] && [ -d "$path" ]; then
    # A worktree from an earlier run sits on that run's head. Detached and never
    # written to, so forcing it forward is safe and cheaper than laying down a
    # fresh copy of the tree. may_touch() above already established that this
    # one is ours to take.
    out=$(git worktree unlock "$path" 2>&1) || true
    out=$(git -C "$path" checkout --detach --force "$ref" 2>&1) ||
      fail checkout_failed "$out"
    reused=true
  else
    # Registered with a missing directory is a killed run; unregistered with a
    # directory present is debris from one. Both clear the same way.
    if [ "$registered" = true ]; then
      git worktree unlock "$path" >/dev/null 2>&1 || true
      FORCE=1 prune_flowkit_metadata
    fi
    if [ -e "$path" ]; then
      rm -rf "$path" || fail stale_path "cannot remove leftover directory at $path"
    fi
    mkdir -p "$WT_ROOT" || fail mkdir_failed "cannot create $WT_ROOT"
    out=$(git worktree add --detach "$path" "$ref" 2>&1) ||
      fail worktree_add_failed "$out"
  fi

  if [ -n "$run_id" ]; then
    out=$(git worktree lock --reason "$(lock_reason_for "$run_id")" "$path" 2>&1) ||
      fail lock_failed "$out"
  fi

  jq -n \
    --argjson pr "$pr" \
    --arg path "$path" \
    --arg ref "$ref" \
    --arg remote "$REMOTE" \
    --arg base_ref "$base_ref" \
    --arg base_local_ref "$base_local_ref" \
    --arg head_sha "$head_sha" \
    --arg base_sha "$base_sha" \
    --arg merge_base "$merge_base" \
    --argjson reused "$reused" \
    --arg run "$run_id" \
    --argjson meta "$meta" \
    '{ok: true, pr: $pr, path: $path, ref: $ref, remote: $remote,
      run: (if $run == "" then null else $run end),
      base_ref: $base_ref, base_local_ref: $base_local_ref,
      head_sha: $head_sha, base_sha: $base_sha, merge_base: $merge_base,
      reused: $reused, state: $meta.state,
      is_cross_repository: $meta.isCrossRepository}'
}

# Sets REMOVED and, on failure, REMOVE_REASON/REMOVE_MESSAGE; returns non-zero
# instead of calling fail. Both callers capture stdout, and `fail` writing JSON
# there would make its exit status vanish into a subshell — a failed teardown
# would come back as {"ok": true, "removed": {...the error...}}, exit 0.
remove_one() {
  local pr="$1"
  local path="$WT_ROOT/pr-$pr"
  local out
  REMOVED=false
  REMOVE_REASON=""
  REMOVE_MESSAGE=""

  if is_registered "$path"; then
    # `git worktree remove --force` refuses a locked tree (it wants -f -f, which
    # nothing here uses), so the lock comes off first — but only once the caller
    # has established through may_touch() that this worktree is ours to remove.
    git worktree unlock "$path" >/dev/null 2>&1 || true
    if ! out=$(git worktree remove --force "$path" 2>&1); then
      REMOVE_REASON="worktree_remove_failed"
      REMOVE_MESSAGE="$out"
      return 1
    fi
    REMOVED=true
  elif [ -e "$path" ]; then
    if ! rm -rf "$path" 2>/dev/null; then
      REMOVE_REASON="stale_path"
      REMOVE_MESSAGE="cannot remove leftover directory at $path"
      return 1
    fi
    REMOVED=true
  fi

  if ! drop_refs_for_pr "$pr"; then
    REMOVE_REASON="ref_delete_failed"
    REMOVE_MESSAGE="removed the worktree but could not delete $REF_PREFIX/{head,base}/pr-$pr"
    return 1
  fi
}

parse_ownership_args() {
  RUN_ID=""
  FORCE=0
  PARSED_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --run)
        [ $# -ge 2 ] || fail bad_args "--run needs a value"
        RUN_ID="$2"
        shift 2
        ;;
      --run=*)
        RUN_ID="${1#--run=}"
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      *)
        PARSED_ARGS+=("$1")
        shift
        ;;
    esac
  done
  validate_run_id "$RUN_ID"
}

cmd_remove() {
  parse_ownership_args "$@"
  set -- ${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}
  require_repo

  local removed=0 pr path why
  local skipped="[]"

  if [ "${1:-}" = "--all" ]; then
    shift
    reject_extra_args "$@"
    while IFS=$'\t' read -r path _; do
      [ -n "$path" ] || continue
      pr=$(pr_from_path "$path")
      [[ "$pr" =~ ^[0-9]+$ ]] || continue
      # Skipping rather than failing: one worktree another run is using must not
      # abort the teardown of the ones this run does own.
      if ! why=$(may_touch "$path" "$RUN_ID"); then
        skipped=$(printf '%s' "$skipped" | jq \
          --argjson pr "$pr" --arg why "$why" '. + [{pr: $pr, reason: $why}]')
        continue
      fi
      remove_one "$pr" || fail "$REMOVE_REASON" "$REMOVE_MESSAGE"
      [ "$REMOVED" = true ] && removed=$((removed + 1))
    done < <(flowkit_worktrees)
    prune_flowkit_metadata
    [ -n "$RUN_ID" ] && rm -f "$(run_marker "$RUN_ID")"

    # Non-zero when anything was skipped, so a caller that only checks the exit
    # status can't report a clean teardown that wasn't one.
    local skipped_count
    skipped_count=$(printf '%s' "$skipped" | jq 'length')
    jq -n --argjson count "$removed" --argjson skipped "$skipped" \
      '{ok: (($skipped | length) == 0), removed_count: $count, skipped: $skipped}'
    [ "$skipped_count" = "0" ] || exit 3
    return
  fi

  validate_pr "${1:-}"
  pr="$1"
  shift
  reject_extra_args "$@"

  path="$WT_ROOT/pr-$pr"
  if ! why=$(may_touch "$path" "$RUN_ID"); then
    fail held_by_another_run "PR #$pr is $why — pass --force to take it over"
  fi

  remove_one "$pr" || fail "$REMOVE_REASON" "$REMOVE_MESSAGE"
  prune_flowkit_metadata
  jq -n --argjson pr "$pr" --argjson removed "$REMOVED" \
    '{ok: true, pr: $pr, removed: $removed}'
}

cmd_list() {
  require_repo
  reject_extra_args "$@"
  local entries="[]" path sha locked reason pr owner age now
  now=$(date -u +%s)
  while IFS=$'\t' read -r path sha locked reason; do
    [ -n "$path" ] || continue
    pr=$(pr_from_path "$path")
    # A directory under our root that isn't pr-<digits> was not put there by
    # this script; skipping keeps a hand-made one from breaking the output.
    [[ "$pr" =~ ^[0-9]+$ ]] || continue
    owner=$(run_from_reason "$reason")
    age=""
    case "$reason" in
      *"started="*)
        age="${reason##*started=}"
        age="${age%% *}"
        [[ "$age" =~ ^[0-9]+$ ]] && age=$((now - age)) || age=""
        ;;
    esac
    entries=$(printf '%s' "$entries" | jq \
      --argjson pr "$pr" --arg path "$path" --arg head_sha "$sha" \
      --argjson locked "$([ "$locked" = "1" ] && echo true || echo false)" \
      --arg run "$owner" --arg age "$age" \
      --argjson live "$(run_is_live "$owner" && echo true || echo false)" \
      '. + [{pr: $pr, path: $path, head_sha: $head_sha, locked: $locked,
             run: (if $run == "" then null else $run end),
             run_live: $live,
             age_seconds: (if $age == "" then null else ($age | tonumber) end)}]')
  done < <(flowkit_worktrees)
  jq -n --argjson worktrees "$(printf '%s' "$entries" | jq 'sort_by(.pr)')" \
    '{ok: true, worktrees: $worktrees}'
}

cmd_run_id() {
  require_repo
  reject_extra_args "$@"
  local id
  id="r$(date -u +%s)-$$-${RANDOM}"
  touch_run_marker "$id"
  jq -n --arg run "$id" '{ok: true, run: $run}'
}

cmd_prune() {
  parse_ownership_args "$@"
  set -- ${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}
  require_repo
  reject_extra_args "$@"

  local dirs_removed=0 refs_removed=0 path pr ref why
  local held="[]" other_live_run=false

  # A run that has started claiming worktrees may be sitting between its fetch
  # and its `git worktree add` right now, where the ref exists and the worktree
  # doesn't — indistinguishable from an orphaned ref. While any other run is
  # live, the ref sweep is skipped rather than risk pulling a ref out from under
  # it. Debris can wait; a review that silently loses a PR can't.
  if [ "$FORCE" != "1" ] && [ -d "$FLOWKIT_COMMON_DIR/flowkit/runs" ]; then
    local marker id
    for marker in "$FLOWKIT_COMMON_DIR"/flowkit/runs/*; do
      [ -f "$marker" ] || continue
      id=$(basename "$marker")
      if [ "$id" != "$RUN_ID" ] && run_is_live "$id"; then
        other_live_run=true
      elif ! run_is_live "$id"; then
        rm -f "$marker"
      fi
    done
  fi

  # Directories first, metadata second: a killed run can leave either a
  # registered worktree whose directory is gone or an unregistered directory,
  # and sweeping in this order clears both in a single pass.
  if [ -d "$WT_ROOT" ]; then
    for path in "$WT_ROOT"/pr-*; do
      [ -e "$path" ] || continue
      if ! why=$(may_touch "$path" "$RUN_ID"); then
        pr=$(pr_from_path "$path")
        held=$(printf '%s' "$held" | jq --arg pr "$pr" --arg why "$why" \
          '. + [{pr: $pr, reason: $why}]')
        continue
      fi
      if ! is_registered "$path"; then
        rm -rf "$path" && dirs_removed=$((dirs_removed + 1))
      fi
    done
  fi

  prune_flowkit_metadata

  # A ref with no worktree pins the PR's objects for nothing.
  if [ "$other_live_run" = false ]; then
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      pr=$(basename "$ref")
      pr="${pr#pr-}"
      if [ ! -d "$WT_ROOT/pr-$pr" ]; then
        git update-ref -d "$ref" 2>/dev/null && refs_removed=$((refs_removed + 1))
      fi
    done < <(git for-each-ref --format='%(refname)' \
      "$REF_PREFIX/head/" "$REF_PREFIX/base/" 2>/dev/null)
  fi

  jq -n --argjson dirs "$dirs_removed" --argjson refs "$refs_removed" \
    --argjson held "$held" --argjson deferred "$other_live_run" \
    '{ok: true, directories_removed: $dirs, refs_removed: $refs,
      held: $held, ref_sweep_deferred: $deferred}'
}

case "${1:-}" in
  add)     shift; cmd_add "$@" ;;
  remove)  shift; cmd_remove "$@" ;;
  list)    shift; cmd_list "$@" ;;
  prune)   shift; cmd_prune "$@" ;;
  run-id)  shift; cmd_run_id "$@" ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage
    fail bad_args "unknown subcommand '${1:-}'"
    ;;
esac
