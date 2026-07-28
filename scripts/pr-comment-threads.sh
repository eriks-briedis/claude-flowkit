#!/usr/bin/env bash
# Deterministic fetch of the actionable reviewer feedback on the open PR for the
# current branch, used by the address-pr-comments command. Run from inside the
# target repo, with `gh` authenticated against its GitHub remote.
#
# "Actionable" = written by someone other than me, and not already resolved:
#   - unresolved inline review threads (including outdated ones — the code moved,
#     but the reviewer's point usually still stands; flagged via is_outdated)
#   - review summary bodies (submitted, non-empty)
#   - PR conversation comments
#
# Resolution state is only exposed by GraphQL (`pullRequest.reviewThreads`), not
# by `gh pr view --json comments` or the REST pulls/comments endpoint — which is
# the whole reason this lives in a script rather than being re-derived per run.
#
# Output: a single JSON object on stdout:
#   {pr, title, url, head_ref, base_ref, viewer, head_sha, counts, truncated,
#    unresolved_threads[], review_bodies[], pr_comments[]}
#
# Every item carries two identifiers, and they are not interchangeable:
#   - `id`  — display label (T1/T2…, R1…, C1…). POSITIONAL: it renumbers between
#             runs as threads get resolved. Use it for talking to the user only.
#   - `key` — the GraphQL node id. Stable for the life of the thread/comment.
#             This is the one to persist in cross-pass memory.
# Each item also carries `latest_foreign_comment_at`: the newest comment on it
# written by someone other than me. Comparing that against the timestamp stored
# in a previous pass is what makes "has the reviewer pushed back since?" a
# deterministic check rather than a judgment call.
set -euo pipefail

MAX_THREADS=100
MAX_THREAD_COMMENTS=50
MAX_REVIEWS=100
MAX_PR_COMMENTS=100

if ! pr_meta=$(gh pr view --json number,title,url,headRefName,baseRefName 2>&1); then
  echo "Could not resolve a PR for the current branch:" >&2
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
  | ([ $pr.reviewThreads.nodes[]
       | select(.isResolved | not)
       | select([.comments.nodes[] | (.author.login // "")] | any(. != $me))
       | {
           key: .id,
           path: .path,
           line: (.line // .originalLine),
           is_outdated: .isOutdated,
           diff_hunk: (.comments.nodes[0].diffHunk // ""),
           latest_foreign_comment_at: (
             [ .comments.nodes[]
               | select((.author.login // "") != $me)
               | .createdAt ] | sort | last
           ),
           comments: [ .comments.nodes[] | {
             comment_id: .databaseId,
             author: (.author.login // "ghost"),
             created_at: .createdAt,
             url: .url,
             body: .body
           } ]
         }
     ]
     | sort_by(.path, (.line // 0))
     | to_entries | map(.value + {id: "T\(.key + 1)"})) as $threads

  | ([ $pr.reviews.nodes[]
       | select(.state != "PENDING")
       | select((.author.login // "") != $me)
       | select(((.body // "") | gsub("\\s"; "")) != "")
       | {
           key: .id,
           author: (.author.login // "ghost"),
           state: .state,
           created_at: .createdAt,
           latest_foreign_comment_at: .createdAt,
           url: .url,
           body: .body
         }
     ]
     | sort_by(.created_at)
     | to_entries | map(.value + {id: "R\(.key + 1)"})) as $reviews

  | ([ $pr.comments.nodes[]
       | select((.author.login // "") != $me)
       | select(((.body // "") | gsub("\\s"; "")) != "")
       | {
           key: .id,
           author: (.author.login // "ghost"),
           created_at: .createdAt,
           latest_foreign_comment_at: .createdAt,
           url: .url,
           body: .body
         }
     ]
     | sort_by(.created_at)
     | to_entries | map(.value + {id: "C\(.key + 1)"})) as $comments

  | {
      pr: $pr.number,
      title: $pr.title,
      url: $pr.url,
      head_ref: $pr.headRefName,
      base_ref: $pr.baseRefName,
      head_sha: $pr.headRefOid,
      viewer: $me,
      counts: {
        unresolved_threads: ($threads | length),
        review_bodies: ($reviews | length),
        pr_comments: ($comments | length),
        total: (($threads | length) + ($reviews | length) + ($comments | length))
      },
      truncated: {
        threads: $pr.reviewThreads.pageInfo.hasNextPage,
        thread_comments: ([$pr.reviewThreads.nodes[] | .comments.pageInfo.hasNextPage] | any),
        reviews: $pr.reviews.pageInfo.hasNextPage,
        pr_comments: $pr.comments.pageInfo.hasNextPage
      },
      unresolved_threads: $threads,
      review_bodies: $reviews,
      pr_comments: $comments
    }
' <<<"$raw"
