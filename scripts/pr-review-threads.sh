#!/usr/bin/env bash
# Deterministic fetch of everything already said on a PR, from the point of view
# of someone about to review it. Used by review-pr, review-quick, and
# pr-review-loop. Run from inside the target repo, with `gh` authenticated
# against its GitHub remote.
#
# Usage: pr-review-threads.sh [pr-number]
#   No argument -> the open PR for the current branch (standalone /review-pr,
#   /review-quick). With a number -> that PR (pr-review-loop, which iterates a
#   queue and may not have the branch checked out yet).
#
# This is the mirror image of pr-comment-threads.sh, and the filtering is the
# reason both exist:
#
#   pr-comment-threads.sh  author side  -> "what do I still have to act on"
#                                          (drops resolved threads and my own
#                                          comments; those aren't work)
#   pr-review-threads.sh   reviewer side -> "what has already been said here"
#                                          (drops nothing; my own prior thread
#                                          and a thread the author resolved are
#                                          both things a reviewer needs to see
#                                          before writing the same comment again)
#
# So: every inline thread comes back, flagged with is_resolved, is_outdated, and
# authored_by_me, and the caller decides what to do with it.
#
# `gh pr view --json body,comments,reviews` cannot stand in for this. Its
# `reviews` nodes carry only the review *summary* body — the line-level comments
# attached to a review are not in that payload at any depth, and thread
# resolution state isn't in the REST comments endpoint either. Both come from
# the GraphQL `pullRequest.reviewThreads` connection, which is why this is a
# script and not something the model reassembles per run.
#
# Output: a single JSON object on stdout:
#   {pr, title, url, head_ref, base_ref, head_sha, viewer, description,
#    counts, truncated, inline_threads[], review_bodies[], pr_comments[]}
#
# `key` on each item is the GraphQL node id — stable for the life of the
# thread/comment, so it survives threads being resolved between review rounds.
set -euo pipefail

MAX_THREADS=100
MAX_THREAD_COMMENTS=50
MAX_REVIEWS=100
MAX_PR_COMMENTS=100

if [ $# -gt 1 ]; then
  echo "usage: $(basename "$0") [pr-number]" >&2
  exit 2
fi

if [ $# -eq 1 ]; then
  if ! [[ "$1" =~ ^[0-9]+$ ]]; then
    echo "pr-number must be a number, got: $1" >&2
    exit 2
  fi
  pr_ref=("$1")
else
  pr_ref=()
fi

# ${arr[@]+...} guard: on bash 3.2 an empty array under `set -u` is an unbound
# variable, and macOS still ships 3.2 as /bin/bash.
if ! pr_meta=$(gh pr view ${pr_ref[@]+"${pr_ref[@]}"} --json number,title,url,headRefName,baseRefName 2>&1); then
  if [ ${#pr_ref[@]} -eq 1 ]; then
    echo "Could not resolve PR #${pr_ref[0]}:" >&2
  else
    echo "Could not resolve a PR for the current branch:" >&2
  fi
  echo "$pr_meta" >&2
  exit 1
fi

number=$(jq -r '.number' <<<"$pr_meta")
url=$(jq -r '.url' <<<"$pr_meta")

# Derive owner/repo from the PR URL rather than `gh repo view` — for a PR opened
# from a fork, the threads live on the base repo, which is what the URL points at.
owner=$(sed -E 's#^https?://[^/]+/([^/]+)/([^/]+)/pull/.*#\1#' <<<"$url")
name=$(sed -E 's#^https?://[^/]+/([^/]+)/([^/]+)/pull/.*#\2#' <<<"$url")

if [ -z "$owner" ] || [ -z "$name" ] || [ "$owner" = "$url" ]; then
  echo "Could not parse owner/repo out of PR url: $url" >&2
  exit 1
fi

me=$(gh api user --jq '.login')

raw=$(gh api graphql \
  -F owner="$owner" \
  -F name="$name" \
  -F number="$number" \
  -F maxThreads="$MAX_THREADS" \
  -F maxThreadComments="$MAX_THREAD_COMMENTS" \
  -F maxReviews="$MAX_REVIEWS" \
  -F maxPrComments="$MAX_PR_COMMENTS" \
  -f query='
query(
  $owner: String!, $name: String!, $number: Int!,
  $maxThreads: Int!, $maxThreadComments: Int!,
  $maxReviews: Int!, $maxPrComments: Int!
) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number
      title
      url
      body
      headRefName
      baseRefName
      headRefOid
      reviewThreads(first: $maxThreads) {
        pageInfo { hasNextPage }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          comments(first: $maxThreadComments) {
            pageInfo { hasNextPage }
            nodes {
              databaseId
              author { login }
              body
              createdAt
              url
              diffHunk
            }
          }
        }
      }
      reviews(first: $maxReviews) {
        pageInfo { hasNextPage }
        nodes {
          id
          author { login }
          state
          body
          createdAt
          url
        }
      }
      comments(first: $maxPrComments) {
        pageInfo { hasNextPage }
        nodes {
          id
          author { login }
          body
          createdAt
          url
        }
      }
    }
  }
}')

jq --arg me "$me" '
  .data.repository.pullRequest as $pr

  # No filtering here by design — see the header. A thread is "mine" when I
  # opened it; replies from other people on my thread do not change that.
  | ([ $pr.reviewThreads.nodes[]
       | {
           key: .id,
           path: .path,
           line: (.line // .originalLine),
           is_resolved: .isResolved,
           is_outdated: .isOutdated,
           authored_by_me: ((.comments.nodes[0].author.login // "") == $me),
           diff_hunk: (.comments.nodes[0].diffHunk // ""),
           comments: [ .comments.nodes[] | {
             comment_id: .databaseId,
             author: (.author.login // "ghost"),
             created_at: .createdAt,
             url: .url,
             body: .body
           } ]
         }
     ]
     | sort_by(.path, (.line // 0))) as $threads

  # Summary bodies only. Plain approvals with no text carry no information for a
  # reviewer, and a PENDING review is an unsubmitted draft.
  | ([ $pr.reviews.nodes[]
       | select(.state != "PENDING")
       | select(((.body // "") | gsub("\\s"; "")) != "")
       | {
           key: .id,
           author: (.author.login // "ghost"),
           authored_by_me: ((.author.login // "") == $me),
           state: .state,
           created_at: .createdAt,
           url: .url,
           body: .body
         }
     ]
     | sort_by(.created_at)) as $reviews

  | ([ $pr.comments.nodes[]
       | select(((.body // "") | gsub("\\s"; "")) != "")
       | {
           key: .id,
           author: (.author.login // "ghost"),
           authored_by_me: ((.author.login // "") == $me),
           created_at: .createdAt,
           url: .url,
           body: .body
         }
     ]
     | sort_by(.created_at)) as $comments

  | {
      pr: $pr.number,
      title: $pr.title,
      url: $pr.url,
      head_ref: $pr.headRefName,
      base_ref: $pr.baseRefName,
      head_sha: $pr.headRefOid,
      viewer: $me,
      description: ($pr.body // ""),
      counts: {
        inline_threads: ($threads | length),
        unresolved_inline_threads: ([$threads[] | select(.is_resolved | not)] | length),
        review_bodies: ($reviews | length),
        pr_comments: ($comments | length)
      },
      truncated: {
        threads: $pr.reviewThreads.pageInfo.hasNextPage,
        thread_comments: ([$pr.reviewThreads.nodes[] | .comments.pageInfo.hasNextPage] | any),
        reviews: $pr.reviews.pageInfo.hasNextPage,
        pr_comments: $pr.comments.pageInfo.hasNextPage
      },
      inline_threads: $threads,
      review_bodies: $reviews,
      pr_comments: $comments
    }
' <<<"$raw"
