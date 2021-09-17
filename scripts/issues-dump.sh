#!/bin/bash

# Get info for all issues in Github repo.
if [[ -z ${REST_API_GITHUB_TOKEN} ]] ; then
  echo REST_API_GITHUB_TOKEN is not set
  exit 1
fi

# Settings.
REPO=deckhouse/deckhouse
PAGE_SIZE=32

# Query.
QUERY_TMPL=$(cat <<'EOF'
query {
  repository (
    owner:"deckhouse",
    name:"deckhouse"
  ) {
    issues(
      ##AFTER_CURSOR##
      first: ##PAGE_SIZE##,
      orderBy: { field: CREATED_AT, direction: ASC}
    ) {
      nodes {
          id
          number
          title
          state
          author{ login }
          assignees (first: 10) {
            nodes {
              login
            }
          }
          labels (first: 20) {
            nodes {
              name
            }
          }
          milestone {
            number
            url
          }  
          createdAt
          lastComment: comments(last:1){
            nodes{
              createdAt
            }
          }
          comments {
            totalCount
          }
          reactions {
            totalCount
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


          react_laugh: reactions(content: LAUGH ) {
            totalCount
          }
          react_eyes: reactions(content: EYES ) {
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
    --arg response "$(cat $curlResponse)" \
    --arg error "$(cat $curlError)" \
    --arg exit "${CURL_EXIT}" \
  '{ status: $status,
     response: ($response| try (.|fromjson) catch $response ),
     headers: ( $headers | 
                split("\n") | 
                map( select( .|startswith("HTTP")|not )) | 
                map( . |= (split(": ") | {(.[0]) : .[1]}) ) | 
                add
              ),
     error: $error,
     exit: $exit
   }'
}

# Substitute parameters in QUERY_TMLP
# $1 - endCursor from response to continue pagination or an empty string to start pagination.
prepare_query() {
  cursor="$1"
  if [[ -n $cursor ]] ; then
    cursor="after\\:\\ \"$cursor\","
  fi
  prepared=$(echo "$QUERY_TMPL" | sed "s/\#\#AFTER_CURSOR\#\#/$cursor/" | sed s/\#\#PAGE_SIZE\#\#/$PAGE_SIZE/ )
  jq -n --arg query "${prepared}" '{"query": $query }' -r
}



loop_dump() {
  HAS_NEXT_PAGE="true"
  END_CURSOR=
  while [[ "${HAS_NEXT_PAGE}" != "false" ]] ; do
    query=$(prepare_query ${END_CURSOR})
    api_resp=$(api_request "${query}")
    #echo $query
    #echo ${api_resp}
    
    # Exit on request error
    read -r code error <<< "$(jq -n --argjson root "${api_resp}" '$root.exit + " " + $root.error' -r )"
    #echo "code=$code, error=$error"
    if [[ $code != "0" ]] ; then
      echo "curl exited with code $code: $error"
      exit 1
    fi

    # Exit on query error
    hasErrors="$(jq -n --argjson root "${api_resp}" -r '$root.response | has("errors") | tostring')"
    if [[ $hasErrors == "true" ]] ; then
      errors="$(jq -n --argjson root "${api_resp}" -r '$root.response | .errors//[] | map(.message) | add')"
      echo "Github API error: ${errors}"
      exit 1
    fi

    # Get pageInfo: hasNextPage and a cursor to continue pagination.
    read -r HAS_NEXT_PAGE END_CURSOR <<< "$(jq -n --argjson root "${api_resp}" '$root.response.data.repository.issues.pageInfo | (.hasNextPage|tostring) + " " + .endCursor' -r)"

    # Print issues.
    jq -n --argjson root "${api_resp}" '$root.response.data.repository.issues.nodes[]' -c
  done
}

# convert json to csv:
# labels: get labels with "type/" prefix
# assignees: join logins with a comma
# sum "positive" reactions
# sum "negative" reactions
convert_to_csv() {
  jq -r '[
    .number,
    .title,
    .state,
    .author.login,
    (.assignees.nodes | map(.login) | join(",") ),
    (.labels.nodes|map(select(.name|startswith("type/"))) | map(.name | sub("^type/"; "")) | join(",")),
    .milestone.number,
    .createdAt,
    (.lastComment.nodes | first //{} | .createdAt),
    .comments.totalCount,
    ([.react_thumbs_down.totalCount, .react_confused.totalCount] | add),
    ([.react_thumbs_up.totalCount, .react_heart.totalCount, .react_hooray.totalCount, .react_rocket.totalCount] | add)
   ] 
  | @csv'
}

main() {
  apiResp=$(mktemp $TMPDIR/api-resp-XXX)
  loop_dump | tee ${apiResp} | convert_to_csv
}


main "$@"
