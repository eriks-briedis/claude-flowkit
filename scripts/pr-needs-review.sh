#!/usr/bin/env bash
# Deterministic replacement for the "which open PRs need my review" logic
# used by the pr-review-loop command. Run from inside the target repo,
# with `gh` authenticated against its GitHub remote.
#
# "Needs review" = PR is not authored by me, is not a draft, and is either
# review-requested/already-reviewed-by me, AND (I've never reviewed it OR
# someone else pushed commits or left a comment/reply after my latest review).
#
# Output: JSON array of {number, title, url, headRefName, status, reasons}
# status is "new" (never reviewed by me) or "updated" (activity since my
# last review). reasons (only present when status is "updated") is a subset
# of ["commits", "comments"] explaining why.
set -euo pipefail

REPO=$(gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"')
ME=$(gh api user --jq '.login')

combined=$(
  {
    gh pr list --state open --search "review-requested:@me" \
      --json number,title,url,author,isDraft,headRefName
    gh pr list --state open --search "reviewed-by:@me" \
      --json number,title,url,author,isDraft,headRefName
  } | jq -s 'add | unique_by(.number)'
)

candidates=$(echo "$combined" | jq --arg me "$ME" \
  '[.[] | select(.author.login != $me) | select(.isDraft == false)]')

results="[]"
while IFS= read -r row; do
  number=$(echo "$row" | jq -r '.number')

  last_review=$(gh api "repos/$REPO/pulls/$number/reviews" | jq -r \
    --arg me "$ME" '[.[] | select(.user.login == $me) | .submitted_at] | sort | last // empty')

  status=""
  reasons="[]"
  if [ -z "$last_review" ]; then
    status="new"
  else
    newest_commit=$(gh api "repos/$REPO/pulls/$number/commits" --jq \
      '[.[].commit.committer.date] | sort | last')

    # Newest comment from anyone other than me — both PR-conversation comments
    # and inline review-comment replies count, since a reply resolving a prior
    # finding (e.g. "this is out of scope") is exactly what should resurface
    # the PR even with zero new commits.
    newest_issue_comment=$(gh api "repos/$REPO/issues/$number/comments" | jq -r \
      --arg me "$ME" '[.[] | select(.user.login != $me) | .created_at] | sort | last // empty')
    newest_review_comment=$(gh api "repos/$REPO/pulls/$number/comments" | jq -r \
      --arg me "$ME" '[.[] | select(.user.login != $me) | .created_at] | sort | last // empty')
    newest_comment=$(printf '%s\n' "$newest_issue_comment" "$newest_review_comment" | sort | tail -1)

    commits_newer=false
    comments_newer=false
    [[ "$newest_commit" > "$last_review" ]] && commits_newer=true
    [[ -n "$newest_comment" && "$newest_comment" > "$last_review" ]] && comments_newer=true

    if [ "$commits_newer" = true ] || [ "$comments_newer" = true ]; then
      status="updated"
      reasons=$(jq -cn --argjson c "$commits_newer" --argjson m "$comments_newer" \
        '[if $c then "commits" else empty end, if $m then "comments" else empty end]')
    fi
  fi

  if [ -n "$status" ]; then
    if [ "$status" = "new" ]; then
      entry=$(echo "$row" | jq \
        '{number, title, url, headRefName, status: "new"}')
    else
      entry=$(echo "$row" | jq --argjson reasons "$reasons" \
        '{number, title, url, headRefName, status: "updated", reasons: $reasons}')
    fi
    results=$(echo "$results" | jq --argjson e "$entry" '. + [$e]')
  fi
done < <(echo "$candidates" | jq -c '.[]')

echo "$results" | jq 'sort_by(.number) | reverse'
