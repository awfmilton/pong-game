#!/bin/bash

# scripts/jules-monitor.sh <issue-number> [--repo <owner/repo>]

ISSUE_NUM=$1
if [ -n "$ISSUE_NUM" ]; then
    shift
fi

REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "awfmilton/mcp-manager")
PR_NUM=""
GATE_PASSED=false
CI_FAILED_SINCE=""
LAST_JULES_CHECK=0
JULES_CHECK_INTERVAL=300 # 5 minutes
LAST_HEARTBEAT=$(date +%s)
HEARTBEAT_INTERVAL=300 # 5 minutes
LOOP_COUNT=0  # for MONITOR_TEST_ITERATIONS — bounded loop in test mode (default unbounded)

function log_event() {
  echo "$1"
  LAST_HEARTBEAT=$(date +%s)
}

while [ "$#" -gt 0 ]; do
    case $1 in
        --repo) REPO="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$ISSUE_NUM" ]; then
    echo "Usage: $0 <issue-number> [--repo <owner/repo>]"
    exit 1
fi

# Primary detection — PR search (independent of Jules commenting)
function detect_pr_via_search() {
  gh pr list --repo "$REPO" --state open --search "mentions:$ISSUE_NUM" \
    --json number --jq '.[0].number // empty' 2>/dev/null
}

# Fallback detection — original comment-scan method (keeps backward compat)
function detect_pr_via_comments() {
  gh issue view "$ISSUE_NUM" --repo "$REPO" --json comments \
    --jq '[.comments[].body | scan("pull/([0-9]+)") | .[0]] | last // empty' 2>/dev/null
}

# Actor-state monitoring — scan Jules's latest comment for error keywords
function detect_jules_state() {
  gh issue view "$ISSUE_NUM" --repo "$REPO" --json comments \
    --jq '[.comments[] | select(.author.login | test("jules"; "i")) | .body] | .[-1] // empty' 2>/dev/null
}

# Authoritative actor state — Jules CLI session status
# Returns one of: PLANNING | IN_PROGRESS | COMPLETED | FAILED | UNAVAILABLE
# UNAVAILABLE when `jules` binary is absent, user not logged in, or no session row for this repo.
function detect_jules_cli_status() {
  if ! command -v jules >/dev/null 2>&1; then
    echo "UNAVAILABLE"
    return 0
  fi

  local row
  row=$(jules remote list --session 2>/dev/null | grep -F "$REPO" | head -1)
  if [ -z "$row" ]; then
    echo "UNAVAILABLE"
    return 0
  fi

  case "$row" in
    *"Failed"*)      echo "FAILED" ;;
    *"Completed"*)   echo "COMPLETED" ;;
    *"In Progress"*) echo "IN_PROGRESS" ;;
    *"Planning"*)    echo "PLANNING" ;;
    *)               echo "UNAVAILABLE" ;;
  esac
}

while true; do
  # Test-mode bounded loop: when MONITOR_TEST_ITERATIONS is set, exit after that many iterations.
  # In normal operation (env var unset), the loop runs indefinitely.
  if [ -n "$MONITOR_TEST_ITERATIONS" ] && [ "$LOOP_COUNT" -ge "$MONITOR_TEST_ITERATIONS" ]; then
    log_event "TEST_EXIT:reached MONITOR_TEST_ITERATIONS=$MONITOR_TEST_ITERATIONS"
    exit 0
  fi
  LOOP_COUNT=$((LOOP_COUNT + 1))

  NOW=$(date +%s)

  # Actor-state monitoring - every 5 min
  # Precedence: jules CLI status (authoritative) > comment-keyword scan (fallback for users without `jules`).
  if [ $((NOW - LAST_JULES_CHECK)) -ge $JULES_CHECK_INTERVAL ]; then
    LAST_JULES_CHECK=$NOW

    CLI_STATUS=$(detect_jules_cli_status)
    case "$CLI_STATUS" in
      FAILED)
        if [ -z "$PR_NUM" ]; then
          log_event "JULES_FAILED:$ISSUE_NUM (jules CLI status=Failed)"
          exit 1
        fi
        ;;
      COMPLETED)
        if [ -z "$PR_NUM" ]; then
          log_event "JULES_COMPLETED:$ISSUE_NUM — awaiting PR detection"
        fi
        ;;
      UNAVAILABLE)
        # Fall through to the comment-keyword scan below.
        STATE_TEXT=$(detect_jules_state)
        if [ -n "$STATE_TEXT" ]; then
          if echo "$STATE_TEXT" | grep -qiE "error|failed|couldn't|unable|apologize"; then
            if [ -z "$PR_NUM" ]; then
              log_event "JULES_FAILED:$ISSUE_NUM"
              exit 1
            fi
          fi
        fi
        ;;
    esac
  fi

  # Always scan for the LATEST PR link.
  # Jules creates a NEW PR on each re-label — follow the latest open one.
  LATEST=$(detect_pr_via_search)
  if [ -z "$LATEST" ]; then
    LATEST=$(detect_pr_via_comments)
  fi

  if [ -n "$LATEST" ] && [ "$LATEST" != "$PR_NUM" ]; then
    NEW_STATE=$(gh pr view "$LATEST" --repo "$REPO" --json state --jq '.state' 2>/dev/null)
    if [ "$NEW_STATE" = "OPEN" ]; then
      PR_NUM="$LATEST"
      GATE_PASSED=false
      CI_FAILED_SINCE=""
      log_event "PR_DETECTED:$PR_NUM"

      # Auto run gate check
      GATE_RESULT=$(bash scripts/gate-check.sh "$PR_NUM" --repo "$REPO" --issue "$ISSUE_NUM")
      if [ $? -ne 0 ]; then
        # Run again with --post-on-fail to notify Jules
        bash scripts/gate-check.sh "$PR_NUM" --repo "$REPO" --issue "$ISSUE_NUM" --post-on-fail > /dev/null
        log_event "GATE_FAIL:$PR_NUM — feedback posted, Jules re-labeled"
        PR_NUM="" # Reset to watch for the new PR
        continue
      else
        GATE_PASSED=true
        log_event "GATE_PASS:$PR_NUM"
      fi
    fi
  fi

  if [ -n "$PR_NUM" ]; then
    DATA=$(gh pr view "$PR_NUM" --repo "$REPO" \
      --json state,statusCheckRollup \
      --jq '{
        state:   .state,
        pending: ([.statusCheckRollup // [] | .[] | select(.status != "COMPLETED")] | length),
        failed:  ([.statusCheckRollup // [] | .[] | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED")] | length),
        passed:  ([.statusCheckRollup // [] | .[] | select(.conclusion == "SUCCESS")] | length),
        total:   (.statusCheckRollup // [] | length),
        failingChecks: [.statusCheckRollup // [] | .[] | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED") | .context]
      }' 2>/dev/null)

    STATE=$(echo "$DATA" | jq -r '.state // empty')

    if [ "$STATE" = "MERGED" ]; then
      log_event "PR_MERGED:$PR_NUM"
      exit 0
    fi

    if [ "$STATE" = "CLOSED" ]; then
      log_event "PR_CLOSED_RESETTING:$PR_NUM"
      PR_NUM=""
      GATE_PASSED=false
      CI_FAILED_SINCE=""
    else
      FAILED=$(echo  "$DATA" | jq -r '.failed  // 0')
      PENDING=$(echo "$DATA" | jq -r '.pending // 1')
      TOTAL=$(echo   "$DATA" | jq -r '.total   // 0')
      PASSED=$(echo  "$DATA" | jq -r '.passed  // 0')

      if [ "$FAILED" -gt 0 ]; then
        if [ -z "$CI_FAILED_SINCE" ]; then
          CI_FAILED_SINCE=$(date +%s)
          log_event "CI_FAILED:$PR_NUM — waiting up to 10 min for CI Fixer"
        else
          NOW=$(date +%s)
          ELAPSED=$((NOW - CI_FAILED_SINCE))
          if [ "$ELAPSED" -gt 600 ]; then
            FAILING_NAMES=$(echo "$DATA" | jq -r '.failingChecks | join(", ")')
            REVIEW_BODY="@jules CI has been failing for 10+ minutes and the CI Fixer has not self-healed. Please investigate and push a fix to this branch. Failing checks: $FAILING_NAMES."
            if gh pr review "$PR_NUM" --repo "$REPO" --comment --body "$REVIEW_BODY" 2>/dev/null; then
              log_event "CI_TIMEOUT:$PR_NUM — review comment posted (Jules should push fix to same branch)"
            else
              # Fallback: review comment failed for some reason, fall back to the old re-label trigger
              gh pr comment "$PR_NUM" --repo "$REPO" --body "$REVIEW_BODY"
              gh issue edit "$ISSUE_NUM" --repo "$REPO" --remove-label jules
              gh issue edit "$ISSUE_NUM" --repo "$REPO" --add-label jules
              log_event "CI_TIMEOUT:$PR_NUM — review comment failed, fell back to re-label trigger"
              PR_NUM=""
            fi
            CI_FAILED_SINCE=""
          fi
        fi
      elif [ "$PENDING" -eq 0 ] && [ "$TOTAL" -gt 0 ] && [ "$PASSED" -eq "$TOTAL" ]; then
        if [ "$GATE_PASSED" = true ]; then
          CHANGED_FILES=$(gh pr view "$PR_NUM" --repo "$REPO" --json files --jq '[.files[].path]')
          IS_SENSITIVE=$(echo "$CHANGED_FILES" | grep -qE "(vault\.js|keychain\.js|schema\.sql|license\.js|preload\.js|mcp-server\.js)" && echo 1 || echo 0)

          if [ "$IS_SENSITIVE" -eq 1 ]; then
            SENSITIVE_FILES=$(echo "$CHANGED_FILES" | jq -r '.[] | select(test("(vault\\.js|keychain\\.js|schema\\.sql|license\\.js|preload\\.js|mcp-server\\.js)"))')
            log_event "NOTIFY_USER:$PR_NUM — sensitive files changed, Orchestrator + human approval required before merge"
            echo "Sensitive files detected: $SENSITIVE_FILES"
          else
            log_event "NOTIFY_USER:$PR_NUM — CI green + gate pass; Orchestrator code review required before merge (no auto-merge)"
          fi
          exit 0
        else
          log_event "CI_PASSED:$PR_NUM — running gate check"
          bash scripts/gate-check.sh "$PR_NUM" --repo "$REPO" --issue "$ISSUE_NUM" --post-on-fail
          # Re-run loop will pick up GATE_PASSED
        fi
      fi
    fi
  fi

  # Heartbeat every 5 min when nothing changed
  if [ $((NOW - LAST_HEARTBEAT)) -ge $HEARTBEAT_INTERVAL ]; then
      log_event "WAITING:$ISSUE_NUM"
  fi

  # Skip sleep in test mode so tests run fast; sleep 60 in normal mode.
  if [ -z "$MONITOR_TEST_ITERATIONS" ]; then
    sleep 60
  fi
done
