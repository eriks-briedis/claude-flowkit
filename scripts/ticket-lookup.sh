#!/usr/bin/env bash
# Resolve a ticket key to its title/description from a sprint CSV in the repo, so a
# review command can skip asking the user for text the repo already has. Used by
# review, review-quick, review-pr, and pr-review-loop.
#
#   ticket-lookup.sh <TICKET-KEY> [--csv <path>]
#
# Default CSV path is <repo-root>/tickets/sprint.csv.
#
# Always exits 0 and always prints one JSON object. A miss is not an error — the
# calling command falls back to asking the user, exactly as it did before.
#
#   hit:  {"found": true, "key": ..., "title": ..., "description": ...,
#          "acceptance_criteria": ..., "type": ..., "status": ..., "source": ...}
#         Fields whose column is absent or empty are omitted, not emitted blank.
#
#   miss: {"found": false, "reason": "no_key_given" | "no_python" | "no_csv"
#                                    | "unreadable" | "no_key_column" | "no_match"}
#
# Column names are matched dynamically, not hardcoded to one export shape. A Jira
# CSV export ("Issue key", "Summary", "Custom field (Acceptance Criteria)") and a
# hand-rolled id,title,description file both resolve.

set -uo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: ticket-lookup.sh <TICKET-KEY> [--csv <path>]

  <TICKET-KEY>   e.g. ABC-1234. Matched case-insensitively, exact — never fuzzy.
  --csv <path>   Override the default <repo-root>/tickets/sprint.csv.
EOF
}

key=""
csv_path=""

while [ $# -gt 0 ]; do
  case "$1" in
    --csv)
      if [ $# -lt 2 ]; then
        usage
        printf '{"found": false, "reason": "no_csv"}\n'
        exit 0
      fi
      csv_path="$2"
      shift 2
      ;;
    --csv=*)
      csv_path="${1#--csv=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      [ -n "$key" ] || key="$1"
      shift
      ;;
  esac
done

if [ -z "$key" ]; then
  usage
  printf '{"found": false, "reason": "no_key_given"}\n'
  exit 0
fi

root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$root" ] || root="$PWD"
[ -n "$csv_path" ] || csv_path="$root/tickets/sprint.csv"

if ! command -v python3 >/dev/null 2>&1; then
  printf '{"found": false, "reason": "no_python"}\n'
  exit 0
fi

if [ ! -f "$csv_path" ]; then
  printf '{"found": false, "reason": "no_csv"}\n'
  exit 0
fi

if [ ! -r "$csv_path" ]; then
  printf '{"found": false, "reason": "unreadable"}\n'
  exit 0
fi

python3 - "$key" "$csv_path" "$root" <<'PY'
import csv
import json
import os
import re
import sys

# Ordered per logical field: whatever matches first wins. Jira's own column names
# lead, generic ones follow, so both export shapes resolve without configuration.
CANDIDATES = {
    "key": ["issuekey", "key", "ticket", "ticketkey", "issue", "id"],
    "title": ["summary", "title", "name"],
    "description": ["description", "desc", "details", "body"],
    "acceptance_criteria": ["acceptancecriteria", "acceptance", "ac"],
    "type": ["issuetype", "type"],
    "status": ["status"],
}

CUSTOM_FIELD = re.compile(r"^custom field\s*\((.*)\)$", re.IGNORECASE | re.DOTALL)


def emit(payload):
    print(json.dumps(payload, indent=2, ensure_ascii=False))
    sys.exit(0)


def normalize(header):
    return re.sub(r"[^a-z0-9]", "", (header or "").strip().lower())


def unwrap(header):
    match = CUSTOM_FIELD.match((header or "").strip())
    return match.group(1) if match else None


def build_maps(header_row):
    """normalized name -> column indices, kept separate so a real column always
    outranks a custom field that happens to normalize to the same name."""
    raw, unwrapped = {}, {}
    for index, name in enumerate(header_row):
        plain = normalize(name)
        if plain:
            raw.setdefault(plain, []).append(index)
        inner = unwrap(name)
        if inner:
            inner_norm = normalize(inner)
            if inner_norm:
                unwrapped.setdefault(inner_norm, []).append(index)
    return raw, unwrapped


def indices_for(field, raw, unwrapped):
    for candidate in CANDIDATES[field]:
        for mapping in (raw, unwrapped):
            if candidate in mapping:
                return mapping[candidate]
    return []


def value_at(row, indices):
    """Duplicate headers are everywhere in a Jira export; first non-empty wins."""
    for index in indices:
        if index < len(row):
            cell = (row[index] or "").strip()
            if cell:
                return cell
    return None


def display_path(path, root):
    absolute = os.path.abspath(path)
    if root:
        try:
            relative = os.path.relpath(absolute, root)
        except ValueError:
            return absolute
        if not relative.startswith(".."):
            return relative
    return absolute


def main():
    wanted, path = sys.argv[1].strip(), sys.argv[2]
    root = sys.argv[3] if len(sys.argv) > 3 else ""

    # Jira descriptions run long, and the module default rejects them outright.
    csv.field_size_limit(16 * 1024 * 1024)

    with open(path, newline="", encoding="utf-8-sig", errors="replace") as handle:
        reader = csv.reader(handle)
        try:
            header_row = next(reader)
        except StopIteration:
            emit({"found": False, "reason": "no_match"})

        raw, unwrapped = build_maps(header_row)
        key_indices = indices_for("key", raw, unwrapped)
        if not key_indices:
            emit({"found": False, "reason": "no_key_column"})

        columns = {
            field: indices_for(field, raw, unwrapped)
            for field in CANDIDATES
            if field != "key"
        }
        target = wanted.casefold()

        for row in reader:
            row_key = value_at(row, key_indices)
            if not row_key or row_key.casefold() != target:
                continue
            result = {"found": True, "key": row_key}
            for field in ("title", "description", "acceptance_criteria", "type", "status"):
                cell = value_at(row, columns[field])
                if cell is not None:
                    result[field] = cell
            result["source"] = display_path(path, root)
            emit(result)

    emit({"found": False, "reason": "no_match"})


try:
    main()
except SystemExit:
    raise
except Exception:
    # A broken CSV must never take a review down with it.
    print(json.dumps({"found": False, "reason": "unreadable"}, indent=2))
PY
