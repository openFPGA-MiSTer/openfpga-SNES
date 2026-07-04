#!/usr/bin/env bash
# Sends a CI alert to a Telegram chat via the Bot API.
# Adapted from the MiSTer-DB9 Forks_MiSTer fork CI template.
# Usage: notify_error.sh REASON
#
# Severity is selected by the NOTIFY_LEVEL env var (default "error"):
#   error -> "CI build failed",  exit 1 (the build aborts)
#   warn  -> "CI build warning", exit 0 (report-only)

set -euo pipefail

if (( "$#" < 1 )); then
    >&2 echo "Must run $0 REASON"
    exit 1
fi

REASON="$1"

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"

LEVEL="${NOTIFY_LEVEL:-error}"
case "${LEVEL}" in
    warn)  HEADER="🟡 <b>CI build warning</b>" ;;
    *)     HEADER="🔴 <b>CI build failed</b>" ;;
esac

# Telegram parse_mode=HTML allows only a small tag subset; every interpolated
# value must be HTML-escaped so stray <, >, & don't break parsing.
html_escape () {
    printf '%s' "$1" | python3 -c 'import html,sys; sys.stdout.write(html.escape(sys.stdin.read()))'
}

# Derive clickable Telegram hashtags from REASON: "#<channel> #<core>".
hashtags_for () {
    printf '%s' "$1" | python3 -c '
import os, re, sys
reason = sys.stdin.read().strip()
tags = []
repo = os.environ.get("GITHUB_REPOSITORY", "").rsplit("/", 1)[-1]
core = re.sub(r"[^A-Za-z0-9]", "_", repo).strip("_") or None
words = reason.split()
if words and words[0].upper() in ("STABLE", "UNSTABLE", "UPSTREAM"):
    tags.append("#" + words[0].lower())
    words = words[1:]
cat = re.sub(r"[^a-z0-9]+", "_", " ".join(words).lower()).strip("_")
if cat:
    tags.append("#" + cat)
if core:
    tags.append("#" + core)
sys.stdout.write(" ".join(tags))
'
}

REPO="${GITHUB_REPOSITORY:-unknown/repo}"
SHA="${GITHUB_SHA:-}"
RUN_ID="${GITHUB_RUN_ID:-}"

REASON_HTML=$(html_escape "${REASON}")
REPO_HTML=$(html_escape "${REPO}")
SHA7="${SHA:0:7}"
HASHTAGS=$(hashtags_for "${REASON}")

TEXT="${HEADER}
<b>Reason:</b> <code>${REASON_HTML}</code>
<b>Commit:</b> <a href=\"https://github.com/${REPO}/commit/${SHA}\">${REPO_HTML}@${SHA7}</a>
<b>Run log:</b> <a href=\"https://github.com/${REPO}/actions/runs/${RUN_ID}\">#${RUN_ID}</a>"
[[ -n "${HASHTAGS}" ]] && TEXT="${TEXT}
${HASHTAGS}"

curl --fail-with-body --retry 3 --retry-delay 10 --retry-all-errors \
  --retry-connrefused --retry-max-time 120 --max-time 30 --request POST \
  --url "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TELEGRAM_CHAT_ID}" \
  -d "parse_mode=HTML" \
  -d "disable_web_page_preview=true" \
  --data-urlencode "text=${TEXT}"

echo "Telegram notification sent OK!"
[[ "${LEVEL}" == "warn" ]] && exit 0
exit 1
