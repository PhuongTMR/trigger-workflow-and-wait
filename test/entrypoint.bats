#!/usr/bin/env bats

# Test suite for entrypoint.sh

setup() {
  # Source the script functions without running main
  source_entrypoint() {
    # Extract functions from entrypoint.sh without executing main
    sed '/^main$/d' "$BATS_TEST_DIRNAME/../entrypoint.sh" > "$BATS_TMPDIR/entrypoint_functions.sh"
    source "$BATS_TMPDIR/entrypoint_functions.sh"
  }
  
  # Set required environment variables with defaults
  export INPUT_OWNER="test-owner"
  export INPUT_REPO="test-repo"
  export INPUT_GITHUB_TOKEN="test-token"
  export INPUT_WORKFLOW_FILE_NAME="test.yml"
  export GITHUB_OUTPUT="$BATS_TMPDIR/github_output"
  touch "$GITHUB_OUTPUT"
}

teardown() {
  rm -f "$BATS_TMPDIR/entrypoint_functions.sh"
  rm -f "$GITHUB_OUTPUT"
  unset INPUT_OWNER INPUT_REPO INPUT_GITHUB_TOKEN INPUT_WORKFLOW_FILE_NAME
  unset INPUT_WAIT_INTERVAL INPUT_FIRST_WAIT_MINUTES INPUT_PROPAGATE_FAILURE
  unset INPUT_TRIGGER_WORKFLOW INPUT_WAIT_WORKFLOW INPUT_REF INPUT_TRIGGER_TIMEOUT
  unset INPUT_CLIENT_PAYLOAD INPUT_SENTRY_PROJECT
}

# ============================================================================
# validate_args tests
# ============================================================================

@test "validate_args: sets default values correctly" {
  source_entrypoint
  validate_args
  
  [ "$wait_interval" -eq 10 ]
  [ "$first_wait_minutes" -eq 0 ]
  [ "$propagate_failure" = "true" ]
  [ "$trigger_workflow" = "true" ]
  [ "$wait_workflow" = "true" ]
  [ "$ref" = "main" ]
  [ "$trigger_timeout" -eq 120 ]
}

@test "validate_args: respects custom wait_interval" {
  export INPUT_WAIT_INTERVAL=30
  source_entrypoint
  validate_args
  
  [ "$wait_interval" -eq 30 ]
}

@test "validate_args: respects custom ref" {
  export INPUT_REF="develop"
  source_entrypoint
  validate_args
  
  [ "$ref" = "develop" ]
}

@test "validate_args: respects custom trigger_timeout" {
  export INPUT_TRIGGER_TIMEOUT=300
  source_entrypoint
  validate_args
  
  [ "$trigger_timeout" -eq 300 ]
}

@test "validate_args: respects custom propagate_failure=false" {
  export INPUT_PROPAGATE_FAILURE="false"
  source_entrypoint
  validate_args
  
  [ "$propagate_failure" = "false" ]
}

@test "validate_args: fails when owner is missing" {
  unset INPUT_OWNER
  source_entrypoint
  
  run validate_args
  [ "$status" -eq 1 ]
  [[ "$output" == *"Owner is a required argument"* ]]
}

@test "validate_args: fails when repo is missing" {
  unset INPUT_REPO
  source_entrypoint
  
  run validate_args
  [ "$status" -eq 1 ]
  [[ "$output" == *"Repo is a required argument"* ]]
}

@test "validate_args: fails when github_token is missing" {
  unset INPUT_GITHUB_TOKEN
  source_entrypoint
  
  run validate_args
  [ "$status" -eq 1 ]
  [[ "$output" == *"Github token is required"* ]]
}

@test "validate_args: fails when workflow_file_name is missing" {
  unset INPUT_WORKFLOW_FILE_NAME
  source_entrypoint
  
  run validate_args
  [ "$status" -eq 1 ]
  [[ "$output" == *"Workflow File Name is required"* ]]
}

@test "validate_args: parses client_payload as JSON" {
  export INPUT_CLIENT_PAYLOAD='{"key": "value", "num": 123}'
  source_entrypoint
  validate_args
  
  # Should be compacted JSON
  [ "$client_payload" = '{"key":"value","num":123}' ]
}

@test "validate_args: adds sentry_project to client_payload when both are set" {
  export INPUT_CLIENT_PAYLOAD='{"key": "value"}'
  export INPUT_SENTRY_PROJECT="my-sentry-project"
  source_entrypoint
  validate_args
  
  # sentry_project is only added when INPUT_CLIENT_PAYLOAD is also set
  [[ "$client_payload" == *'"sentry_project"'* ]]
  [[ "$client_payload" == *'my-sentry-project'* ]]
}

@test "validate_args: empty client_payload defaults to {}" {
  unset INPUT_CLIENT_PAYLOAD
  source_entrypoint
  validate_args
  
  [ "$client_payload" = '{}' ]
}

# ============================================================================
# lets_wait tests
# ============================================================================

@test "lets_wait: uses default wait_interval" {
  source_entrypoint
  wait_interval=1
  
  start=$(date +%s)
  lets_wait
  end=$(date +%s)
  
  [ $((end - start)) -ge 1 ]
}

@test "lets_wait: accepts custom interval parameter" {
  source_entrypoint
  wait_interval=10
  
  start=$(date +%s)
  lets_wait 1
  end=$(date +%s)
  
  [ $((end - start)) -ge 1 ]
  [ $((end - start)) -lt 5 ]
}

# ============================================================================
# API response parsing tests (using mock data)
# ============================================================================

@test "jq parsing: extracts run_id from workflow_runs response" {
  response='{"workflow_runs":[{"id":12345,"created_at":"2025-12-19T04:00:00Z"},{"id":12344,"created_at":"2025-12-19T03:00:00Z"}]}'
  start_time=$(date -d "2025-12-19T03:30:00Z" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "2025-12-19T03:30:00Z" +%s)
  
  run_id=$(echo "$response" | jq -r --arg start "$start_time" '
    [.workflow_runs[] | 
     select((.created_at | fromdateiso8601) >= ($start | tonumber))] |
    first | .id // empty
  ')
  
  [ "$run_id" = "12345" ]
}

@test "jq parsing: returns empty when no runs match time filter" {
  response='{"workflow_runs":[{"id":12345,"created_at":"2025-12-19T02:00:00Z"}]}'
  # Use a timestamp that's definitely after the run's created_at (2025-12-19T02:00:00Z = 1766109600)
  start_time="1766115000"  # ~1.5 hours after the run
  
  run_id=$(echo "$response" | jq -r --arg start "$start_time" '
    [.workflow_runs[] | 
     select((.created_at | fromdateiso8601) >= ($start | tonumber))] |
    first | .id // empty
  ')
  
  # Should be empty since no runs match
  [ -z "$run_id" ]
}

@test "jq parsing: handles empty workflow_runs array" {
  response='{"workflow_runs":[]}'
  start_time="1734567000"
  
  run_id=$(echo "$response" | jq -r --arg start "$start_time" '
    [.workflow_runs[] | 
     select((.created_at | fromdateiso8601) >= ($start | tonumber))] |
    first | .id // empty
  ' 2>/dev/null)
  
  [ -z "$run_id" ] || [ "$run_id" = "null" ]
}

@test "run_id validation: accepts numeric IDs" {
  RUN_ID="12345678"
  [[ "$RUN_ID" =~ ^[0-9]+$ ]]
}

@test "run_id validation: rejects non-numeric IDs" {
  RUN_ID="abc123"
  ! [[ "$RUN_ID" =~ ^[0-9]+$ ]]
}

@test "run_id validation: rejects empty string" {
  RUN_ID=""
  ! [[ "$RUN_ID" =~ ^[0-9]+$ ]]
}

@test "run_id validation: rejects curly brace" {
  RUN_ID="{"
  ! [[ "$RUN_ID" =~ ^[0-9]+$ ]]
}

# ============================================================================
# Integration test helpers
# ============================================================================

@test "usage_docs: outputs usage information" {
  source_entrypoint
  
  run usage_docs
  [ "$status" -eq 0 ]
  [[ "$output" == *"trigger-workflow-and-wait"* ]]
  [[ "$output" == *"github_token"* ]]
}

@test "environment defaults: GITHUB_API_URL defaults correctly" {
  unset API_URL
  source_entrypoint
  
  [ "$GITHUB_API_URL" = "https://api.github.com" ]
}

@test "environment defaults: GITHUB_API_URL respects custom API_URL" {
  export API_URL="https://github.example.com/api/v3"
  source_entrypoint
  
  [ "$GITHUB_API_URL" = "https://github.example.com/api/v3" ]
}

@test "environment defaults: GITHUB_SERVER_URL defaults correctly" {
  unset SERVER_URL
  source_entrypoint
  
  [ "$GITHUB_SERVER_URL" = "https://github.com" ]
}
