#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <submission-file> <staple-target>" >&2
  exit 64
fi

SUBMISSION_FILE="$1"
STAPLE_TARGET="$2"
NOTARY_PROFILE="notary"

if [[ ! -e "$SUBMISSION_FILE" ]]; then
  echo "Notarization submission file does not exist: $SUBMISSION_FILE" >&2
  exit 1
fi

if [[ ! -e "$STAPLE_TARGET" ]]; then
  echo "Staple target does not exist: $STAPLE_TARGET" >&2
  exit 1
fi

SUBMIT_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/ajman-notary-submit.XXXXXX")"
cleanup() {
  rm -f "$SUBMIT_OUTPUT"
}
trap cleanup EXIT INT TERM

set +e
xcrun notarytool submit "$SUBMISSION_FILE" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait 2>&1 | tee "$SUBMIT_OUTPUT"
SUBMIT_EXIT=${PIPESTATUS[0]}
set -e

SUBMISSION_ID="$(awk '/^[[:space:]]*id:/ { print $2; exit }' "$SUBMIT_OUTPUT")"
SUBMISSION_STATUS="$(awk '
  /^[[:space:]]*status:/ {
    value = $0
    sub(/^[[:space:]]*status:[[:space:]]*/, "", value)
    status = value
  }
  END { print status }
' "$SUBMIT_OUTPUT")"

if [[ $SUBMIT_EXIT -ne 0 || "$SUBMISSION_STATUS" != "Accepted" ]]; then
  echo "Notarization failed: id=${SUBMISSION_ID:-unknown} status=${SUBMISSION_STATUS:-unknown}" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    echo "Full notarization log for $SUBMISSION_ID:" >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE"
  else
    echo "No submission ID was returned, so no notarization log can be requested." >&2
  fi
  exit 1
fi

xcrun stapler staple "$STAPLE_TARGET"
xcrun stapler validate "$STAPLE_TARGET"

echo "NOTARIZATION_RESULT submission_id=$SUBMISSION_ID status=$SUBMISSION_STATUS target=$STAPLE_TARGET"
