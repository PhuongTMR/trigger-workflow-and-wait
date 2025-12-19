#!/usr/bin/env bash
set -e

usage_docs() {
  echo ""
  echo "You can use this Github Action with:"
  echo "- uses: convictional/trigger-workflow-and-wait"
  echo "  with:"
  echo "    owner: keithconvictional"
  echo "    repo: myrepo"
  echo "    github_token: \${{ secrets.GITHUB_PERSONAL_ACCESS_TOKEN }}"
  echo "    workflow_file_name: main.yaml"
}
GITHUB_API_URL="${API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${SERVER_URL:-https://github.com}"

validate_args() {
  wait_interval=10 # Waits for 10 seconds
  if [ "${INPUT_WAIT_INTERVAL}" ]
  then
    wait_interval=${INPUT_WAIT_INTERVAL}
  fi

  first_wait_minutes=0 # Waits for 3 minutes
  if [ "${INPUT_FIRST_WAIT_MINUTES}" ]
  then
    first_wait_minutes=${INPUT_FIRST_WAIT_MINUTES}
  fi

  propagate_failure=true
  if [ -n "${INPUT_PROPAGATE_FAILURE}" ]
  then
    propagate_failure=${INPUT_PROPAGATE_FAILURE}
  fi

  trigger_workflow=true
  if [ -n "${INPUT_TRIGGER_WORKFLOW}" ]
  then
    trigger_workflow=${INPUT_TRIGGER_WORKFLOW}
  fi

  wait_workflow=true
  if [ -n "${INPUT_WAIT_WORKFLOW}" ]
  then
    wait_workflow=${INPUT_WAIT_WORKFLOW}
  fi

  sentry_project=""
  if [ -n "${INPUT_SENTRY_PROJECT}" ]
  then
    sentry_project=${INPUT_SENTRY_PROJECT}
  fi

  if [ -z "${INPUT_OWNER}" ]
  then
    echo "Error: Owner is a required argument."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_REPO}" ]
  then
    echo "Error: Repo is a required argument."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_GITHUB_TOKEN}" ]
  then
    echo "Error: Github token is required. You can head over settings and"
    echo "under developer, you can create a personal access tokens. The"
    echo "token requires repo access."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_WORKFLOW_FILE_NAME}" ]
  then
    echo "Error: Workflow File Name is required"
    usage_docs
    exit 1
  fi

  client_payload=$(echo '{}' | jq -c)
  if [ "${INPUT_CLIENT_PAYLOAD}" ]
  then
    client_payload=$(echo "${INPUT_CLIENT_PAYLOAD}" | jq -c)

    if [ -n "${sentry_project}" ]
    then
      client_payload=$(echo "$client_payload" | jq --arg sentry_project "$sentry_project" '. + {sentry_project: $sentry_project}')
    fi
  fi

  ref="main"
  if [ "$INPUT_REF" ]
  then
    ref="${INPUT_REF}"
  fi
}

lets_wait() {
  # echo "Sleeping for ${wait_interval} seconds"
  sleep "$wait_interval"
}

api() {
  path=$1; shift
  if response=$(curl --fail-with-body -sSL \
      "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/$path" \
      -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github.v3+json' \
      -H 'Content-Type: application/json' \
      "$@")
  then
    echo "$response"
  else
    echo >&2 "api failed:"
    echo >&2 "path: $path"
    echo >&2 "response: $response"
    if [[ "$response" == *'"Server Error"'* ]]; then
      echo >&2 "Server error - trying again"
    else
      exit 1
    fi
  fi
}

lets_wait() {
  local interval=${1:-$wait_interval}
  # echo >&2 "Sleeping for $interval seconds"
  sleep "$interval"
}

# Return the ids of the most recent workflow runs, optionally filtered by user
get_workflow_runs() {
  since=${1:?}

  query="event=workflow_dispatch&created=>=$since${INPUT_GITHUB_USER+&actor=}${INPUT_GITHUB_USER}&per_page=100"

  echo "Getting workflow runs using query: ${query}" >&2

  api "workflows/${INPUT_WORKFLOW_FILE_NAME}/runs?${query}" |
  jq -r '.workflow_runs[].id' |
  sort # Sort to ensure repeatable order, and lexicographically for compatibility with join
}

trigger_workflow() {
  START_TIME=$(date +%s)
  
  echo >&2 "Triggering workflow:"
  echo >&2 "  workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches"
  echo >&2 "  {\"ref\":\"${ref}\",\"inputs\":${client_payload}}"

  # Dispatch API returns empty on success (HTTP 204), discard output
  api "workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches" \
    --data "{\"ref\":\"${ref}\",\"inputs\":${client_payload}}" >/dev/null

  # Wait for a new run to appear that was created after START_TIME
  RUN_ID=""
  while [ -z "$RUN_ID" ]
  do
    lets_wait

    # Get recent runs and find one created after we triggered
    response=$(api "workflows/${INPUT_WORKFLOW_FILE_NAME}/runs?event=workflow_dispatch&per_page=10")
    
    # Find the most recent run created after START_TIME
    RUN_ID=$(echo "$response" | jq -r --arg start "$START_TIME" '
      [.workflow_runs[] | 
       select((.created_at | fromdateiso8601) >= ($start | tonumber))] |
      first | .id // empty
    ' 2>/dev/null)

    # Validate RUN_ID is a number
    if ! [[ "$RUN_ID" =~ ^[0-9]+$ ]]; then
      RUN_ID=""
      echo >&2 "Waiting for workflow run to appear..."
      echo >&2 "Response received: $response"
    fi
  done

  echo "$RUN_ID"
}

comment_downstream_link() {
  if response=$(curl --fail-with-body -sSL -X POST \
      "${INPUT_COMMENT_DOWNSTREAM_URL}" \
      -H "Authorization: Bearer ${INPUT_COMMENT_GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github.v3+json' \
      -d "{\"body\": \"Running downstream job at $1\"}")
  then
    echo "$response"
  else
    echo >&2 "failed to comment to ${INPUT_COMMENT_DOWNSTREAM_URL}:"
  fi
}

wait_for_workflow_to_finish() {
  last_workflow_id=${1:?}
  last_workflow_url="${GITHUB_SERVER_URL}/${INPUT_OWNER}/${INPUT_REPO}/actions/runs/${last_workflow_id}"
  first_wait_seconds=$(echo "${first_wait_minutes} * 60" | bc)

  echo "Waiting for workflow to finish:"
  echo "The workflow id is [${last_workflow_id}]."
  echo "The workflow logs can be found at ${last_workflow_url}"
  echo "workflow_id=${last_workflow_id}" >> $GITHUB_OUTPUT
  echo "workflow_url=${last_workflow_url}" >> $GITHUB_OUTPUT
  echo "Waiting for workflow to complete 🕖 ..."
  sleep $first_wait_seconds

  if [ -n "${INPUT_COMMENT_DOWNSTREAM_URL}" ]; then
    comment_downstream_link ${last_workflow_url}
  fi

  conclusion=null
  status=

  while [[ "${conclusion}" == "null" && "${status}" != "completed" ]]
  do
    lets_wait

    workflow=$(api "runs/$last_workflow_id")
    conclusion=$(echo "${workflow}" | jq -r '.conclusion')
    status=$(echo "${workflow}" | jq -r '.status')

    # echo "Checking conclusion [${conclusion}]"
    # echo "Checking status [${status}]"
    echo "conclusion=${conclusion}" >> $GITHUB_OUTPUT
  done

  if [[ "${conclusion}" == "success" && "${status}" == "completed" ]]
  then
    echo "Yes, success"
  else
    # Alternative "failure"
    echo "Conclusion is not success, it's [${conclusion}]."

    if [ "${propagate_failure}" = true ]
    then
      echo "Propagating failure to upstream job"
      exit 1
    fi
  fi
}

main() {
  validate_args

  if [ "${trigger_workflow}" = true ]
  then
    run_ids=$(trigger_workflow)
  else
    echo "Skipping triggering the workflow."
  fi

  if [ "${wait_workflow}" = true ]
  then
    for run_id in $run_ids
    do
      wait_for_workflow_to_finish "$run_id"
    done
  else
    echo "Skipping waiting for workflow."
  fi
}

main
