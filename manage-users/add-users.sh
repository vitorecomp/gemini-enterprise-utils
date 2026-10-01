#!/usr/bin/env bash

# ==============================================================================
# Script: add-users.sh
# Description: Imports a list of users from a CSV file and assigns them a
#              Gemini Enterprise license via the Google Discovery Engine API
#              (userStores:batchUpdateUserLicenses).
#              Validates inputs, processes requests in configurable batches,
#              and provides detailed diagnostic output on errors.
# Auth: Uses Google Cloud CLI (gcloud) to generate a Bearer token dynamically.
# ==============================================================================

set -uo pipefail

# ==============================================================================
# Default Configuration
# ==============================================================================
CSV_FILE=""
PROJECT_ID=""
PROJECT_NUMBER=""
LICENSE_ID=""
LOCATION="global"
USER_STORE_ID="default_user_store"
BATCH_SIZE=10
VERBOSE=false
DRY_RUN=false

# Color codes (disabled if stdout is not a terminal)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

# ==============================================================================
# Logging Helpers
# ==============================================================================
timestamp() {
    date +"%Y-%m-%d %H:%M:%S"
}

log_info() {
    echo -e "${BLUE}[$(timestamp)] [INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[$(timestamp)] [OK]${NC}   $*"
}

log_warn() {
    echo -e "${YELLOW}[$(timestamp)] [WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[$(timestamp)] [ERROR]${NC} $*" >&2
}

log_debug() {
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${CYAN}[$(timestamp)] [DEBUG]${NC} $*"
    fi
}

# ==============================================================================
# Help / Usage
# ==============================================================================
usage() {
    cat <<EOF
${BOLD}Usage:${NC}
  $0 -f <csv_file> -p <project_id> [-n <project_number>] -i <license_id> [options]

${BOLD}Required Arguments:${NC}
  -f <csv_file>        Path to the CSV file containing user emails (one per line).
  -p <project_id>      Google Cloud Project ID (e.g., agent-space-demos).
  -i <license_id>      License Config ID (e.g., internal_gemini_ent_plus).

${BOLD}Optional Arguments:${NC}
  -n <project_number>  Google Cloud Project Number (e.g., 584757245252).
                       If omitted, resolved automatically via 'gcloud projects describe'.
  -a <account>         Google Cloud account email to use for authentication
                       (e.g., admin@gcp.altostrat.com).
  -l <location>        Discovery Engine location (default: global; e.g., global, us, eu).
  -b <batch_size>      Number of users per API batch request (default: 10).
  -v                   Enable verbose debug logging (prints full payloads and responses).
  -d                   Dry-run mode (validates CSV and prints batches without calling API).
  -h                   Display this help message.

${BOLD}Examples:${NC}
  $0 -f users.csv -p agent-space-demos -n 584757245252 -i internal_gemini_ent_plus
  $0 -f users.csv -p agent-space-demos -n 584757245252 -i internal_gemini_ent_plus -a user@gcp.altostrat.com
EOF
    exit 1
}

# ==============================================================================
# Parse Command-Line Arguments
# ==============================================================================
ACCOUNT=""
while getopts "f:p:n:i:a:l:b:vdh" opt; do
    case ${opt} in
        f ) CSV_FILE="$OPTARG" ;;
        p ) PROJECT_ID="$OPTARG" ;;
        n ) PROJECT_NUMBER="$OPTARG" ;;
        i ) LICENSE_ID="$OPTARG" ;;
        a ) ACCOUNT="$OPTARG" ;;
        l ) LOCATION="$OPTARG" ;;
        b ) BATCH_SIZE="$OPTARG" ;;
        v ) VERBOSE=true ;;
        d ) DRY_RUN=true ;;
        h ) usage ;;
        * ) usage ;;
    esac
done

# ==============================================================================
# Validate Parameters & Environment
# ==============================================================================
MISSING_PARAMS=()
[[ -z "$CSV_FILE" ]]   && MISSING_PARAMS+=("-f <csv_file>")
[[ -z "$PROJECT_ID" ]] && MISSING_PARAMS+=("-p <project_id>")
[[ -z "$LICENSE_ID" ]] && MISSING_PARAMS+=("-i <license_id>")

if [[ ${#MISSING_PARAMS[@]} -gt 0 ]]; then
    log_error "Missing required parameter(s): ${MISSING_PARAMS[*]}"
    echo ""
    usage
fi

if [[ ! -f "$CSV_FILE" ]]; then
    log_error "CSV file not found at path: '$CSV_FILE'"
    exit 1
fi

if [[ ! -r "$CSV_FILE" ]]; then
    log_error "CSV file is not readable: '$CSV_FILE'"
    exit 1
fi

if ! [[ "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    log_error "Invalid batch size '$BATCH_SIZE'. Must be a positive integer."
    exit 1
fi

for cmd in curl gcloud; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Required command '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

# ==============================================================================
# JSON Formatting & Error Parsing Helpers
# ==============================================================================
pretty_print_json() {
    local raw_input="$1"
    if command -v jq >/dev/null 2>&1; then
        echo "$raw_input" | jq . 2>/dev/null || echo "$raw_input"
    elif command -v python3 >/dev/null 2>&1; then
        echo "$raw_input" | python3 -m json.tool 2>/dev/null || echo "$raw_input"
    else
        echo "$raw_input"
    fi
}

# Extracts a concise error summary from a Google Cloud API JSON response
extract_api_error_summary() {
    local json_body="$1"
    if command -v jq >/dev/null 2>&1; then
        echo "$json_body" | jq -r '
            if type == "object" and has("error") then
                "Code: \(.error.code // "N/A") | Status: \(.error.status // "N/A") | Message: \(.error.message // "Unknown error")"
            elif type == "object" and has("response") and (.response.errorSamples != null) then
                "Partial Failure in LRO: \((.response.errorSamples | tostring))"
            else
                empty
            end
        ' 2>/dev/null || true
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if isinstance(data, dict):
        if "error" in data and isinstance(data["error"], dict):
            err = data["error"]
            print(f"Code: {err.get(\"code\", \"N/A\")} | Status: {err.get(\"status\", \"N/A\")} | Message: {err.get(\"message\", \"Unknown error\")}")
        elif "response" in data and isinstance(data["response"], dict) and "errorSamples" in data["response"]:
            print(f"Partial Failure in LRO: {json.dumps(data[\"response\"][\"errorSamples\"])}")
except Exception:
    pass
' <<< "$json_body" 2>/dev/null || true
    fi
}

print_troubleshooting_hints() {
    local http_code="$1"
    log_error "Troubleshooting Hints (HTTP $http_code):"
    case "$http_code" in
        400)
            echo -e "  ${YELLOW}* INVALID_ARGUMENT / FAILED_PRECONDITION:${NC}" >&2
            echo -e "    - Verify that License Config ID '${BOLD}${LICENSE_ID}${NC}' exists in project '${BOLD}${PROJECT_ID}${NC}' (${PROJECT_NUMBER}) and location '${BOLD}${LOCATION}${NC}'." >&2
            echo -e "    - Check if your subscription has enough available seats for this batch." >&2
            echo -e "    - Ensure all user principal email addresses in this batch are valid." >&2
            ;;
        401)
            echo -e "  ${YELLOW}* UNAUTHENTICATED (ACCESS_TOKEN_TYPE_UNSUPPORTED / Account Restricted):${NC}" >&2
            echo -e "    1. If you see '${BOLD}ACCESS_TOKEN_TYPE_UNSUPPORTED${NC}' or '${BOLD}The account was restricted due to a domain admin's policies${NC}':" >&2
            echo -e "       Corporate domain policies (CBA/mTLS) block standard 'gcloud auth print-access-token' tokens when used with curl." >&2
            echo -e "       Fix by logging in with Application Default Credentials (ADC):" >&2
            echo -e "         ${BOLD}gcloud auth application-default login${NC}" >&2
            echo -e "    2. If the project '${BOLD}${PROJECT_ID}${NC}' belongs to a different domain (e.g., ${BOLD}@gcp.altostrat.com${NC}):" >&2
            echo -e "       Authenticate with that domain account and pass ${BOLD}-a <account>${NC}:" >&2
            echo -e "         ${BOLD}gcloud auth login your-user@gcp.altostrat.com${NC}" >&2
            echo -e "         ${BOLD}$0 -f $CSV_FILE -p $PROJECT_ID -n $PROJECT_NUMBER -i $LICENSE_ID -a your-user@gcp.altostrat.com${NC}" >&2
            ;;
        403)
            echo -e "  ${YELLOW}* PERMISSION_DENIED:${NC}" >&2
            echo -e "    - Ensure your account has the ${BOLD}discoveryengine.userStores.batchUpdateUserLicenses${NC} permission (e.g., ${BOLD}roles/discoveryengine.admin${NC})." >&2
            echo -e "    - Ensure the Discovery Engine API (${BOLD}discoveryengine.googleapis.com${NC}) is enabled on project '${BOLD}${PROJECT_ID}${NC}'." >&2
            ;;
        404)
            echo -e "  ${YELLOW}* NOT_FOUND:${NC}" >&2
            echo -e "    - Verify that Project ID '${BOLD}${PROJECT_ID}${NC}', Project Number '${BOLD}${PROJECT_NUMBER}${NC}', and Location '${BOLD}${LOCATION}${NC}' are correct." >&2
            echo -e "    - Verify that the API endpoint uses ':batchUpdateUserLicenses' on the UserStore resource." >&2
            ;;
        429)
            echo -e "  ${YELLOW}* RESOURCE_EXHAUSTED:${NC}" >&2
            echo -e "    - Rate limit or quota exceeded. Try reducing the batch size (-b) or retrying shortly." >&2
            ;;
        500|502|503|504)
            echo -e "  ${YELLOW}* SERVER_ERROR:${NC}" >&2
            echo -e "    - Transient backend error on Discovery Engine API. Retry the failed users." >&2
            ;;
        *)
            echo -e "  ${YELLOW}* UNEXPECTED HTTP STATUS:${NC} Inspect the full response body below for details." >&2
            ;;
    esac
}

# ==============================================================================
# Authentication & Project Number Resolution
# ==============================================================================
ACTIVE_ACCOUNT="${ACCOUNT:-$(gcloud config get-value account 2>/dev/null || echo "unknown")}"
TOKEN_SOURCE=""

if [[ "$DRY_RUN" == false ]]; then
    log_info "Generating access token via gcloud..."
    GCLOUD_ERR_FILE=$(mktemp)
    if [[ -n "$ACCOUNT" ]]; then
        # Explicit account requested via -a
        if TOKEN=$(gcloud auth print-access-token "$ACCOUNT" 2>"$GCLOUD_ERR_FILE") && [[ -n "$TOKEN" ]]; then
            TOKEN_SOURCE="gcloud auth print-access-token ($ACCOUNT)"
            log_success "Access token generated for account '$ACCOUNT'."
        else
            GCLOUD_ERR=$(cat "$GCLOUD_ERR_FILE")
            rm -f "$GCLOUD_ERR_FILE"
            log_error "Failed to obtain gcloud access token for account '$ACCOUNT'."
            [[ -n "$GCLOUD_ERR" ]] && log_error "gcloud stderr: $GCLOUD_ERR"
            log_error "Please authenticate using: gcloud auth login $ACCOUNT"
            exit 1
        fi
    elif TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null) && [[ -n "$TOKEN" ]]; then
        # Prefer Application Default Credentials (ADC) to avoid CBA/mTLS ACCESS_TOKEN_TYPE_UNSUPPORTED errors
        TOKEN_SOURCE="Application Default Credentials (gcloud auth application-default)"
        log_success "Access token generated via Application Default Credentials (ADC)."
    elif TOKEN=$(gcloud auth print-access-token 2>"$GCLOUD_ERR_FILE") && [[ -n "$TOKEN" ]]; then
        TOKEN_SOURCE="gcloud user credentials ($ACTIVE_ACCOUNT)"
        log_warn "ADC not configured; falling back to 'gcloud auth print-access-token' (account: $ACTIVE_ACCOUNT)."
        log_warn "Note: Corporate accounts (@google.com) may require 'gcloud auth application-default login' to avoid HTTP 401 ACCESS_TOKEN_TYPE_UNSUPPORTED."
    else
        GCLOUD_ERR=$(cat "$GCLOUD_ERR_FILE")
        rm -f "$GCLOUD_ERR_FILE"
        log_error "Failed to obtain gcloud access token."
        [[ -n "$GCLOUD_ERR" ]] && log_error "gcloud stderr: $GCLOUD_ERR"
        log_error "Please authenticate using: gcloud auth application-default login (or gcloud auth login)"
        exit 1
    fi
    rm -f "$GCLOUD_ERR_FILE"
else
    log_info "Dry-run mode enabled: skipping gcloud token generation."
    TOKEN="DRY_RUN_TOKEN"
    TOKEN_SOURCE="dry-run"
fi

if [[ -z "$PROJECT_NUMBER" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        log_warn "No project number (-n) provided in dry-run mode; using placeholder '000000000000'."
        PROJECT_NUMBER="000000000000"
    else
        log_info "Project number (-n) not provided. Resolving via gcloud for project '$PROJECT_ID'..."
        GCLOUD_ERR_FILE=$(mktemp)
        if ! PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>"$GCLOUD_ERR_FILE") || [[ -z "$PROJECT_NUMBER" ]]; then
            GCLOUD_ERR=$(cat "$GCLOUD_ERR_FILE")
            rm -f "$GCLOUD_ERR_FILE"
            log_error "Failed to resolve project number for project '$PROJECT_ID'."
            [[ -n "$GCLOUD_ERR" ]] && log_error "gcloud stderr: $GCLOUD_ERR"
            log_error "Please pass the project number explicitly using -n <project_number>."
            exit 1
        fi
        rm -f "$GCLOUD_ERR_FILE"
        log_success "Resolved Project Number: $PROJECT_NUMBER"
    fi
fi

# ==============================================================================
# Construct Resource Paths & API Endpoint
# ==============================================================================
if [[ "$LOCATION" == "global" ]]; then
    API_HOST="discoveryengine.googleapis.com"
else
    API_HOST="${LOCATION}-discoveryengine.googleapis.com"
fi

LICENSE_CONFIG="projects/${PROJECT_NUMBER}/locations/${LOCATION}/licenseConfigs/${LICENSE_ID}"
PARENT_USER_STORE="projects/${PROJECT_ID}/locations/${LOCATION}/userStores/${USER_STORE_ID}"
URL="https://${API_HOST}/v1alpha/${PARENT_USER_STORE}:batchUpdateUserLicenses"

log_info "Configuration Summary:"
echo "  Project ID:          $PROJECT_ID"
echo "  Project Number:      $PROJECT_NUMBER"
echo "  Location:            $LOCATION"
echo "  Auth Token Source:   $TOKEN_SOURCE"
echo "  License Config Path: $LICENSE_CONFIG"
echo "  Target Endpoint:     POST $URL"
echo "  Batch Size:          $BATCH_SIZE"
echo "  Verbose Mode:        $VERBOSE"
echo "  Dry-Run Mode:        $DRY_RUN"

# ==============================================================================
# Read & Validate CSV File Before Sending Batches
# ==============================================================================
log_info "Reading and validating users from '$CSV_FILE'..."

declare -a VALID_USERS=()
declare -A SEEN_EMAILS=()
LINE_NUM=0
SKIPPED_HEADERS_OR_EMPTY=0
SKIPPED_INVALID=0
SKIPPED_DUPLICATES=0

# Read all lines including the last line even if it lacks a trailing newline
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    ((LINE_NUM++))

    # Strip carriage returns, take the first CSV column, and trim surrounding quotes/whitespace
    clean_line="${raw_line//$'\r'/}"
    first_col="${clean_line%%,*}"
    # Trim leading and trailing whitespace and double/single quotes
    email=$(echo "$first_col" | sed -e "s/^[[:space:]\"']*//" -e "s/[[:space:]\"']*$//")

    # Skip empty lines or comments
    if [[ -z "$email" || "$email" == \#* ]]; then
        ((SKIPPED_HEADERS_OR_EMPTY++))
        continue
    fi

    # Skip common header row names (case-insensitive exact match)
    email_lower="${email,,}"
    if [[ "$email_lower" == "email" || "$email_lower" == "emails" || \
          "$email_lower" == "userprincipal" || "$email_lower" == "user_principal" || \
          "$email_lower" == "user" || "$email_lower" == "username" ]]; then
        log_debug "Line $LINE_NUM: Skipping CSV header '$email'"
        ((SKIPPED_HEADERS_OR_EMPTY++))
        continue
    fi

    # Validate basic email structure (user@domain.tld)
    if ! [[ "$email" =~ ^[^[:space:]@\"\'\\]+@[^[:space:]@\"\'\\]+\.[^[:space:]@\"\'\\]+$ ]]; then
        log_warn "Line $LINE_NUM: Skipping invalid email address format: '$email'"
        ((SKIPPED_INVALID++))
        continue
    fi

    # Deduplicate emails (case-insensitive)
    if [[ -n "${SEEN_EMAILS[$email_lower]:-}" ]]; then
        log_warn "Line $LINE_NUM: Skipping duplicate email '$email' (first seen on line ${SEEN_EMAILS[$email_lower]})"
        ((SKIPPED_DUPLICATES++))
        continue
    fi

    SEEN_EMAILS["$email_lower"]="$LINE_NUM"
    VALID_USERS+=("$email")
done < "$CSV_FILE"

TOTAL_USERS=${#VALID_USERS[@]}
log_info "CSV Parsing Complete: $TOTAL_USERS valid user(s) queued ($SKIPPED_HEADERS_OR_EMPTY empty/header line(s), $SKIPPED_DUPLICATES duplicate(s), $SKIPPED_INVALID invalid line(s))."

if [[ $TOTAL_USERS -eq 0 ]]; then
    log_error "No valid user emails found in '$CSV_FILE'. Nothing to process."
    exit 1
fi

TOTAL_BATCHES=$(( (TOTAL_USERS + BATCH_SIZE - 1) / BATCH_SIZE ))
log_info "Processing $TOTAL_USERS user(s) across $TOTAL_BATCHES batch(es) (up to $BATCH_SIZE users per batch)..."

# ==============================================================================
# Batch Processing Function
# ==============================================================================
send_batch() {
    local batch_num="$1"
    local total_batches="$2"
    shift 2
    local batch_emails=("$@")
    local item_count=${#batch_emails[@]}

    echo ""
    log_info "------------------------------------------------------------------------"
    log_info "Sending Batch #${batch_num}/${total_batches} (${item_count} user(s))"
    log_info "Users in batch: ${batch_emails[*]}"

    # Build JSON array of UserLicense objects
    local user_objects=""
    local email_item
    for email_item in "${batch_emails[@]}"; do
        local item_json="{\"userPrincipal\":\"${email_item}\",\"licenseConfig\":\"${LICENSE_CONFIG}\"}"
        if [[ -n "$user_objects" ]]; then
            user_objects="${user_objects},${item_json}"
        else
            user_objects="${item_json}"
        fi
    done

    local payload
    payload=$(cat <<EOF
{
  "inlineSource": {
    "userLicenses": [
      $user_objects
    ],
    "updateMask": "userPrincipal,licenseConfig"
  },
  "deleteUnassignedUserLicenses": false
}
EOF
)

    if [[ "$VERBOSE" == true || "$DRY_RUN" == true ]]; then
        log_debug "Request URL: POST $URL"
        log_debug "Request Payload:"
        pretty_print_json "$payload"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_success "[DRY-RUN] Batch #${batch_num}/${total_batches} validated (${item_count} user(s))."
        return 0
    fi

    local resp_body_file
    local curl_err_file
    resp_body_file=$(mktemp)
    curl_err_file=$(mktemp)

    local http_code
    local curl_exit=0
    http_code=$(curl -sS -X POST "$URL" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Goog-User-Project: ${PROJECT_ID}" \
        -d "$payload" \
        -o "$resp_body_file" \
        -w "%{http_code}" \
        2>"$curl_err_file") || curl_exit=$?

    local resp_body
    local curl_err
    resp_body=$(cat "$resp_body_file")
    curl_err=$(cat "$curl_err_file")
    rm -f "$resp_body_file" "$curl_err_file"

    # 1. Handle transport/network level curl failure
    if [[ $curl_exit -ne 0 ]]; then
        log_error "Batch #${batch_num}/${total_batches} FAILED due to a cURL network/transport error (exit code: $curl_exit)."
        [[ -n "$curl_err" ]] && log_error "cURL stderr: $curl_err"
        log_error "Affected users (${item_count}): ${batch_emails[*]}"
        log_error "Request Payload Sent:"
        pretty_print_json "$payload" >&2
        return 1
    fi

    # 2. Check for HTTP error status codes (non-2xx)
    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        log_error "Batch #${batch_num}/${total_batches} FAILED with HTTP Status Code: ${BOLD}${http_code}${NC}"
        log_error "Endpoint: POST $URL"
        log_error "Affected users (${item_count}): ${batch_emails[*]}"

        local err_summary
        err_summary=$(extract_api_error_summary "$resp_body")
        if [[ -n "$err_summary" ]]; then
            log_error "API Error Summary: ${BOLD}${err_summary}${NC}"
        fi

        print_troubleshooting_hints "$http_code"

        log_error "Full API Error Response:"
        pretty_print_json "$resp_body" >&2

        log_error "Request Payload Sent:"
        pretty_print_json "$payload" >&2
        return 1
    fi

    # 3. Check if the 200 OK Long-Running Operation (LRO) body contains an embedded error
    local lro_error
    lro_error=$(extract_api_error_summary "$resp_body")
    if [[ -n "$lro_error" ]]; then
        log_error "Batch #${batch_num}/${total_batches} returned HTTP $http_code, but the operation reported an error:"
        log_error "${BOLD}${lro_error}${NC}"
        log_error "Affected users (${item_count}): ${batch_emails[*]}"
        log_error "Full Operation Response:"
        pretty_print_json "$resp_body" >&2
        return 1
    fi

    log_success "Batch #${batch_num}/${total_batches} succeeded (HTTP ${http_code}) — assigned license to ${item_count} user(s)."
    if [[ "$VERBOSE" == true ]]; then
        log_debug "API Response:"
        pretty_print_json "$resp_body"
    fi
    return 0
}

# ==============================================================================
# Execute Batches & Track Results
# ==============================================================================
SUCCEEDED_BATCHES=0
FAILED_BATCHES=0
SUCCEEDED_USERS_COUNT=0
declare -a FAILED_USERS=()

for (( batch_idx=0; batch_idx<TOTAL_BATCHES; batch_idx++ )); do
    BATCH_NUM=$(( batch_idx + 1 ))
    OFFSET=$(( batch_idx * BATCH_SIZE ))
    CURRENT_BATCH_EMAILS=("${VALID_USERS[@]:OFFSET:BATCH_SIZE}")

    if send_batch "$BATCH_NUM" "$TOTAL_BATCHES" "${CURRENT_BATCH_EMAILS[@]}"; then
        ((SUCCEEDED_BATCHES++))
        SUCCEEDED_USERS_COUNT=$(( SUCCEEDED_USERS_COUNT + ${#CURRENT_BATCH_EMAILS[@]} ))
    else
        ((FAILED_BATCHES++))
        FAILED_USERS+=("${CURRENT_BATCH_EMAILS[@]}")
    fi
done

# ==============================================================================
# Final Summary Report
# ==============================================================================
echo ""
log_info "========================================================================"
log_info "Execution Summary"
log_info "========================================================================"
echo "  Total Valid Users:    $TOTAL_USERS"
echo "  Total Batches:        $TOTAL_BATCHES"
echo "  Successful Batches:   $SUCCEEDED_BATCHES ($SUCCEEDED_USERS_COUNT user(s))"
echo "  Failed Batches:       $FAILED_BATCHES (${#FAILED_USERS[@]} user(s))"

if [[ $FAILED_BATCHES -gt 0 ]]; then
    echo ""
    log_error "Completed with errors! The following ${#FAILED_USERS[@]} user(s) could not be updated:"
    for failed_email in "${FAILED_USERS[@]}"; do
        echo "  - $failed_email" >&2
    done
    exit 1
fi

echo ""
log_success "Completed successfully! All $TOTAL_BATCHES batch(es) ($SUCCEEDED_USERS_COUNT user(s)) were processed."
exit 0
