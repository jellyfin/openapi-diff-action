#!/bin/bash
set -euo pipefail

# Configuration
# renovate: datasource=docker depName=openapitools/openapi-diff
DOCKER_IMAGE="openapitools/openapi-diff:2.1.7"
# renovate: datasource=docker depName=tufin/oasdiff
OASDIFF_IMAGE="tufin/oasdiff:v1.11.7"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"
TEMP_DIR=$(mktemp -d)
SPECS_DIR=$(mktemp -d)

# Cleanup on exit
cleanup() {
    rm -rf "${TEMP_DIR}" "${SPECS_DIR}"
}
trap cleanup EXIT

# Flatten spec using oasdiff to resolve circular references
# See: https://github.com/OpenAPITools/openapi-diff/issues/124
flatten_spec() {
    local spec="$1"
    local name="$2"

    if [[ "$spec" == http://* ]] || [[ "$spec" == https://* ]]; then
        docker run --rm "${OASDIFF_IMAGE}" flatten "${spec}" --format json > "${SPECS_DIR}/${name}"
    else
        docker run --rm -v "${WORKSPACE_DIR}:/workspace:ro" \
            "${OASDIFF_IMAGE}" flatten "/workspace/${spec}" --format json > "${SPECS_DIR}/${name}"
    fi

    echo "/specs/${name}"
}

echo "::group::OpenAPI Diff Configuration"
echo "Docker Image: ${DOCKER_IMAGE}"
echo "Old Spec: ${INPUT_OLD_SPEC}"
echo "New Spec: ${INPUT_NEW_SPEC}"
echo "::endgroup::"

# Build Docker command arguments
DOCKER_ARGS=()
DOCKER_ARGS+=(--rm)
DOCKER_ARGS+=(-v "${WORKSPACE_DIR}:/workspace:ro")
DOCKER_ARGS+=(-v "${SPECS_DIR}:/specs:ro")
DOCKER_ARGS+=(-v "${TEMP_DIR}:/output:rw")

# Flatten spec files to resolve circular references that cause StackOverflowError
echo "::group::Flattening OpenAPI specs"
OLD_SPEC=$(flatten_spec "${INPUT_OLD_SPEC}" "old-spec.json")
NEW_SPEC=$(flatten_spec "${INPUT_NEW_SPEC}" "new-spec.json")
echo "::endgroup::"

# Build openapi-diff arguments
DIFF_ARGS=()
DIFF_ARGS+=("${OLD_SPEC}")
DIFF_ARGS+=("${NEW_SPEC}")

# Add state flag to capture diff state
DIFF_ARGS+=(--state)

# Log level
if [[ -n "${INPUT_LOG_LEVEL:-}" ]]; then
    DIFF_ARGS+=(-l "${INPUT_LOG_LEVEL}")
fi

# Output formats
if [[ -n "${INPUT_MARKDOWN:-}" ]]; then
    DIFF_ARGS+=(--markdown "/output/diff.md")
fi

if [[ -n "${INPUT_JSON:-}" ]]; then
    DIFF_ARGS+=(--json "/output/diff.json")
fi

if [[ -n "${INPUT_HTML:-}" ]]; then
    DIFF_ARGS+=(--html "/output/diff.html")
fi

if [[ -n "${INPUT_ASCIIDOC:-}" ]]; then
    DIFF_ARGS+=(--asciidoc "/output/diff.adoc")
fi

if [[ -n "${INPUT_TEXT:-}" ]]; then
    DIFF_ARGS+=(--text "/output/diff.txt")
fi

# Fail conditions
if [[ "${INPUT_FAIL_ON_BREAKING:-false}" == "true" ]]; then
    DIFF_ARGS+=(--fail-on-breaking)
fi

if [[ "${INPUT_FAIL_ON_CHANGED:-false}" == "true" ]]; then
    DIFF_ARGS+=(--fail-on-changed)
fi

# Headers for authenticated URLs
if [[ -n "${INPUT_HEADERS:-}" ]]; then
    IFS=',' read -ra HEADER_ARRAY <<< "${INPUT_HEADERS}"
    for header in "${HEADER_ARRAY[@]}"; do
        DIFF_ARGS+=(--header "${header}")
    done
fi

echo "::group::Running OpenAPI Diff"
echo "Command: docker run ${DOCKER_ARGS[*]} ${DOCKER_IMAGE} ${DIFF_ARGS[*]}"
echo "::endgroup::"

# Run openapi-diff and capture output
# Note: < /dev/null prevents docker from waiting for stdin in non-interactive environments
set +e
STATE_OUTPUT=$(docker run "${DOCKER_ARGS[@]}" "${DOCKER_IMAGE}" "${DIFF_ARGS[@]}" 2>&1 < /dev/null)
EXIT_CODE=$?
set -e

echo "::group::OpenAPI Diff Output"
echo "${STATE_OUTPUT}"
echo "::endgroup::"

# Extract state from output (the --state flag outputs the state as the last line)
STATE=$(echo "${STATE_OUTPUT}" | grep -E "^(no_changes|compatible|incompatible)$" | tail -1 || echo "unknown")

# If state not found in expected format, determine from exit code and content
if [[ "${STATE}" == "unknown" ]]; then
    if [[ ${EXIT_CODE} -eq 0 ]]; then
        # Check if there are any changes mentioned in the output
        if echo "${STATE_OUTPUT}" | grep -qi "no changes"; then
            STATE="no_changes"
        else
            STATE="compatible"
        fi
    else
        STATE="incompatible"
    fi
fi

# Determine boolean outputs
HAS_CHANGES="false"
IS_BREAKING="false"

if [[ "${STATE}" == "compatible" ]] || [[ "${STATE}" == "incompatible" ]]; then
    HAS_CHANGES="true"
fi

if [[ "${STATE}" == "incompatible" ]]; then
    IS_BREAKING="true"
fi

echo "Diff State: ${STATE}"
echo "Has Changes: ${HAS_CHANGES}"
echo "Is Breaking: ${IS_BREAKING}"

# Set outputs
echo "state=${STATE}" >> "${GITHUB_OUTPUT}"
echo "has_changes=${HAS_CHANGES}" >> "${GITHUB_OUTPUT}"
echo "is_breaking=${IS_BREAKING}" >> "${GITHUB_OUTPUT}"

# GitHub Actions has a 1MB limit for outputs
MAX_OUTPUT_SIZE=950000

# Post-process markdown to wrap Request/Return Type sections in collapsible details blocks
process_markdown() {
    local file="$1"
    awk '
    BEGIN { in_details = 0 }
    /^###### (Request|Return Type):/ {
        # Close any previous details block
        if (in_details) {
            print "</details>"
            print ""
        }
        print "<details>"
        print ""
        print $0
        print ""
        in_details = 1
        next
    }
    /^#####/ {
        # New endpoint section - close any open details block
        if (in_details) {
            print "</details>"
            print ""
            in_details = 0
        }
        print
        next
    }
    { print }
    END {
        if (in_details) {
            print "</details>"
        }
    }
    ' "$file"
}

# Function to truncate content if it exceeds the limit
truncate_output() {
    local file="$1"
    local size
    size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
    if [[ ${size} -gt ${MAX_OUTPUT_SIZE} ]]; then
        head -c ${MAX_OUTPUT_SIZE} "$file"
        echo ""
        echo ""
        echo "> [!WARNING]"
        echo "> Output truncated (${size} bytes exceeded ${MAX_OUTPUT_SIZE} byte limit). View the full report in the action artifacts."
    else
        cat "$file"
    fi
}

# Process and write markdown output
if [[ -f "${TEMP_DIR}/diff.md" ]] && [[ -s "${TEMP_DIR}/diff.md" ]]; then
    # Post-process markdown to add collapsible sections
    process_markdown "${TEMP_DIR}/diff.md" > "${TEMP_DIR}/diff-processed.md"
    mv "${TEMP_DIR}/diff-processed.md" "${TEMP_DIR}/diff.md"

    # Write to GitHub job summary (truncated for large diffs)
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        truncate_output "${TEMP_DIR}/diff.md" >> "${GITHUB_STEP_SUMMARY}"
    fi

    # Copy to user-specified location if provided (full content, not truncated)
    if [[ -n "${INPUT_MARKDOWN:-}" ]]; then
        mkdir -p "$(dirname "${WORKSPACE_DIR}/${INPUT_MARKDOWN}")" 2>/dev/null || true
        cp "${TEMP_DIR}/diff.md" "${WORKSPACE_DIR}/${INPUT_MARKDOWN}"
        echo "Markdown report written to: ${INPUT_MARKDOWN}"
    fi

    # Write PR comment body file (uses file I/O to avoid ARG_MAX limits)
    # This file is used by the action.yml PR commenting steps via body-path
    PR_COMMENT_FILE="${WORKSPACE_DIR}/.openapi-diff-pr-comment.md"
    {
        echo "<!--openapi-diff-workflow-comment-->"
        echo "## OpenAPI Diff Report"
        echo ""
        case "${STATE}" in
            no_changes) echo "**Status:** No Changes" ;;
            compatible) echo "**Status:** Compatible Changes" ;;
            *) echo "**Status:** Incompatible (Breaking) Changes" ;;
        esac
        echo ""
        echo "<details>"
        echo "<summary>Expand to see details</summary>"
        echo ""
        truncate_output "${TEMP_DIR}/diff.md"
        echo ""
        echo "</details>"
        echo ""
        echo "---"
        echo "*Generated by [openapi-diff-action](https://github.com/Shadowghost/openapi-diff-action)*"
    } > "${PR_COMMENT_FILE}"
    echo "pr_comment_file=${PR_COMMENT_FILE}" >> "${GITHUB_OUTPUT}"
else
    # Write PR comment body file even when no markdown diff exists
    PR_COMMENT_FILE="${WORKSPACE_DIR}/.openapi-diff-pr-comment.md"
    {
        echo "<!--openapi-diff-workflow-comment-->"
        echo "## OpenAPI Diff Report"
        echo ""
        echo "**Status:** No Changes"
        echo ""
        echo "No API changes detected."
        echo ""
        echo "---"
        echo "*Generated by [openapi-diff-action](https://github.com/Shadowghost/openapi-diff-action)*"
    } > "${PR_COMMENT_FILE}"
    echo "pr_comment_file=${PR_COMMENT_FILE}" >> "${GITHUB_OUTPUT}"
fi

# Copy other formats if requested
if [[ -f "${TEMP_DIR}/diff.json" ]] && [[ -s "${TEMP_DIR}/diff.json" ]] && [[ -n "${INPUT_JSON:-}" ]]; then
    mkdir -p "$(dirname "${WORKSPACE_DIR}/${INPUT_JSON}")" 2>/dev/null || true
    cp "${TEMP_DIR}/diff.json" "${WORKSPACE_DIR}/${INPUT_JSON}"
    echo "JSON report written to: ${INPUT_JSON}"
fi

if [[ -n "${INPUT_HTML:-}" ]] && [[ -f "${TEMP_DIR}/diff.html" ]]; then
    mkdir -p "$(dirname "${WORKSPACE_DIR}/${INPUT_HTML}")" 2>/dev/null || true
    cp "${TEMP_DIR}/diff.html" "${WORKSPACE_DIR}/${INPUT_HTML}"
    echo "HTML report written to: ${INPUT_HTML}"
fi

if [[ -n "${INPUT_ASCIIDOC:-}" ]] && [[ -f "${TEMP_DIR}/diff.adoc" ]]; then
    mkdir -p "$(dirname "${WORKSPACE_DIR}/${INPUT_ASCIIDOC}")" 2>/dev/null || true
    cp "${TEMP_DIR}/diff.adoc" "${WORKSPACE_DIR}/${INPUT_ASCIIDOC}"
    echo "Asciidoc report written to: ${INPUT_ASCIIDOC}"
fi

if [[ -n "${INPUT_TEXT:-}" ]] && [[ -f "${TEMP_DIR}/diff.txt" ]]; then
    mkdir -p "$(dirname "${WORKSPACE_DIR}/${INPUT_TEXT}")" 2>/dev/null || true
    cp "${TEMP_DIR}/diff.txt" "${WORKSPACE_DIR}/${INPUT_TEXT}"
    echo "Text report written to: ${INPUT_TEXT}"
fi

# Handle exit code for fail conditions
if [[ ${EXIT_CODE} -ne 0 ]]; then
    if [[ "${INPUT_FAIL_ON_BREAKING:-false}" == "true" ]] && [[ "${IS_BREAKING}" == "true" ]]; then
        echo "::error::Breaking changes detected in OpenAPI specification"
        exit 1
    elif [[ "${INPUT_FAIL_ON_CHANGED:-false}" == "true" ]] && [[ "${HAS_CHANGES}" == "true" ]]; then
        echo "::error::Changes detected in OpenAPI specification"
        exit 1
    fi
fi

echo "OpenAPI diff completed successfully. State: ${STATE}"
