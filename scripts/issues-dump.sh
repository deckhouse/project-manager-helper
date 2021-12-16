#!/bin/bash

# Get info for all issues in Github repo.
# https://docs.github.com/en/graphql/reference/objects#repository
#

# TODO: Keep tmpdir content of error to upload as artifact.

set -eo pipefail

if [[ -z ${REST_API_GITHUB_TOKEN} ]] ; then
  echo REST_API_GITHUB_TOKEN is not set
  exit 1
fi

# Settings.
REPO=deckhouse/deckhouse
PAGE_SIZE=100

# Query.
QUERY_TMPL=$(cat <<'EOF'
query {
  repository (
    owner:"##OWNER##",
    name:"##NAME##"
  ) {
    issues(
      ##AFTER_CURSOR##
      first: ##PAGE_SIZE##
    ) {
      nodes {
          id
          number
          title
          state
          author{ login }
          assignees (first: 100) {
            nodes {
              login
            }
          }
          labels (first: 100) {
            nodes {
              name
            }
          }
          milestone {
            number
            title
            url
          }  

          createdAt

          participants(first: 100){
            nodes {
              login
            }
          }
          lastComment: comments(last:1){
            nodes{
              createdAt
            }
          }
          comments {
            totalCount
          }

          reactions(first: 100) {
            totalCount
            nodes {
              user{ login }
            }
          }

          react_thumbs_down: reactions(content: THUMBS_DOWN ) {
            totalCount
          }
          react_confused: reactions(content: CONFUSED ) {
            totalCount
          }

          react_thumbs_up: reactions(content: THUMBS_UP ) {
            totalCount
          }
          react_heart: reactions(content: HEART ) {
            totalCount
          }
          react_hooray: reactions(content: HOORAY ) {
            totalCount
          }
          react_rocket: reactions(content: ROCKET ) {
            totalCount
          }

      }
      pageInfo {
        endCursor
        hasNextPage
      }
      totalCount
    }
  }
}  

EOF
)


# Do not edit below.

TMPDIR=$(mktemp -d ./tmp.issues.dump.XXXXXX)

cleanup() {
  rm -rf $TMPDIR
}

trap '(exit 130)' INT
trap '(exit 143)' TERM
trap 'rc=$?; cleanup; exit $rc' EXIT


api_request() {
  tmpl=graphql-curl-XXXXX
  curlResponse=$(mktemp $TMPDIR/$tmpl)
  curlHeaders=$(mktemp $TMPDIR/$tmpl)
  curlError=$(mktemp $TMPDIR/$tmpl)
  
  HTTP_STATUS=$(curl -sS \
    -w %{http_code} \
    -o $curlResponse \
    -D $curlHeaders \
    --header "Authorization: Bearer ${REST_API_GITHUB_TOKEN}" \
    --header "Accept: application/vnd.github.groot-preview+json" \
    -X POST \
    -d "$1" \
    https://api.github.com/graphql 2>$curlError
  )
  CURL_EXIT=$?

  # Parse headers to an object, parse response as json. Return json with exit code,
  # http status, curl error, headers and response.
  jq -n \
    --arg status "${HTTP_STATUS}" \
    --arg headers "$(sed 's/\r// ; /^$/d' $curlHeaders 2>/dev/null )" \
    --rawfile response "${curlResponse}" \
    --rawfile error "${curlError}" \
    --arg exit "${CURL_EXIT}" \
  '{ status: $status|tostring,
     response: ($response| try (.|fromjson) catch $response ),
     headers: ( $headers | 
                split("\n") | 
                map( select( .|startswith("HTTP")|not )) | 
                map( . |= (split(": ") | {(.[0]) : .[1]}) ) | 
                add
              ),
     error: $error|tostring,
     exit: $exit|tostring
   }' > "${2}"

}

# Substitute parameters in QUERY_TMLP
# $1 - endCursor from response to continue pagination or an empty string to start pagination.
prepare_query() {
  # A first part in REPO string 'owner/name'.
  owner=${REPO%/*}
  # A last part in REPO string 'owner/name'.
  name=${REPO#*/}
  # Cursor to continue pagination if needed.
  cursor="$1"
  if [[ -n $cursor ]] ; then
    cursor="after\\:\\ \"$cursor\","
  fi
  
  # Render query template.
  prepared=$(echo "$QUERY_TMPL" | sed "s/\#\#AFTER_CURSOR\#\#/$cursor/" | sed s/\#\#PAGE_SIZE\#\#/$PAGE_SIZE/ | sed s/\#\#OWNER\#\#/$owner/ | sed s/\#\#NAME\#\#/$name/ )

  # Return JSON suitable for Github API.
  jq -n --arg query "${prepared}" '{"query": $query }' -r
}


# Run graphql query several times until no pages left.
# '##' parameters are substituted with proper values.
# Note: Github API defines maximum page size as 100.
loop_dump() {
  HAS_NEXT_PAGE="true"
  END_CURSOR=
  while [[ "${HAS_NEXT_PAGE}" != "false" ]] ; do
    apiResponse=$(mktemp $TMPDIR/loop-dump-XXXXX)
    query=$(prepare_query ${END_CURSOR})
    api_request "${query}" "${apiResponse}"

    # Exit on request error
    read -r code error <<< "$(jq -r '.exit + " " + .error' "${apiResponse}")"
    #echo "code=$code, error=$error"
    if [[ $code != "0" ]] ; then
      echo "curl exited with code $code: $error"
      exit 1
    fi

    # Exit on query error
    hasErrors="$(jq -r '.response | has("errors") | tostring' "${apiResponse}")"
    if [[ $hasErrors == "true" ]] ; then
      errors="$(jq -r '.response | .errors//[] | map(.message) | add' "${apiResponse}")"
      echo "Github API error: ${errors}"
      exit 1
    fi

    # Get pageInfo: hasNextPage and a cursor to continue pagination.
    read -r HAS_NEXT_PAGE END_CURSOR <<< "$(jq -r '.response.data.repository.issues.pageInfo | (.hasNextPage|tostring) + " " + .endCursor' "${apiResponse}")"

    # Print issues.
    jq -c '.response.data.repository.issues.nodes[]' "${apiResponse}"
  done
}

# Convert JSON to csv:
# 1. Issue number as seen in url
# 2. Issue title
# 3. Issue state: OPEN, CLOSED
# 4. Author's login
# 5. Assignees logins separated by comma.
# 6. Labels with "type/" prefix separated by comma (prefix is ommited).
# 7. Milestone title.
# 8. Created at date in yyyy-mm-dd format.
# 9. Date of the latest comment in yyyy-mm-dd format.
# 10. Total number of comments.
# 11. Number of positive reactions (THUMB_UP, HEART, HOORAY, ROCKET).
# 12. Number of negative reactions (THUMB_DOWN, CONFUSED).
# 13. Number of participants: unique logins of users placed a comment or left a reaction on issue.
convert_to_csv() {
  cat <<EOF
"Issue #","Title","State","Author","Assignees","Type labels","Milestone","Created","Commented","Total comments","Positive reactions","Negative reactions","Participants"
EOF
  # Sort issues by number in ascending order before producing CSV.
  jq -s -r 'sort_by(.number)[] | [
    .number,
    .title,
    .state,
    .author.login,
    (.assignees.nodes | map(.login) | join(",") ),
    (.labels.nodes|map(select(.name|startswith("type/"))) | map(.name | sub("^type/"; "")) | join(",")),
    .milestone.title,
    (.createdAt //"" | sub("T.*"; "")),
    (.lastComment.nodes | first //{} | .createdAt //"" | sub("T.*"; "")),
    .comments.totalCount,
    ([.react_thumbs_up.totalCount, .react_heart.totalCount, .react_hooray.totalCount, .react_rocket.totalCount] | add),
    ([.react_thumbs_down.totalCount, .react_confused.totalCount] | add),
    ((.participants.nodes + .reactions.nodes) | map(.login//.user.login) | unique | length)
   ]
  | @csv'
}

# Print issues count and the latest issue number.
print_info() {
  jq -s -r 'sort_by(.number) | {"len": length|tostring , "last": .[-1].number|tostring} | "TOTAL: " + .len + "\nLAST ISSUE: #" + .last'
}

main() {
  case "$1" in
  dump)
    loop_dump > "$2"
    ;;
  info)
    cat "$2" | print_info
    ;;
  convert)
    cat "$2" | convert_to_csv
    ;;
  *)
    apiResp=$(mktemp $TMPDIR/api-resp-XXX)
    loop_dump | tee ${apiResp} | convert_to_csv > "$1"
    cat ${apiResp} | print_info
    ;;
  esac
}

main "$@"
