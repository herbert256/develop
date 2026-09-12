#!/usr/bin/env bash
#
# post-client-action.sh — "Post client action error" (2026-09-12, user
# request): the Advanced Routing ARRC0009 lines, one row per line, newest
# first. From the TM message
#
#   ARRC0009: [CD_ARIVA_HAANSADVOCATEN@FE000225] []  Error deleting the
#   file after a post client action.
#
# The FIRST bracket is <account>@<login> on these receive-side lines (the
# route bracket is empty), so the entity is the ACCOUNT — the part before
# the @ — linked to its detail page. The row is Date & time (to the second)
# · Account; at most 1000 rows and 10 per account, the newest. The shared
# body — bin/server/arlist.sh — does the rest.
#
# Usage:
#   ./post-client-action.sh   # reads input/*.csv (via the cache), writes data/post-client-action.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../arlist.sh"
mkdir -p "$REPORTS_DIR"

AR_BASENAME=post-client-action
AR_TITLE="Post client action error"
AR_DESC='The Advanced Routing post client action errors (ARRC0009 "Error deleting the file after a post client action." and its kin): the action that runs after a file was received failed — per line, newest first, with the account.'
AR_KEYWORDS='post client action,ARRC0009,error deleting the file,post-processing,receive,account,advanced routing'
AR_INTRO_NONE='No **post client action** error in this data window — no action that runs after a received file failed.'
AR_INTRO='**%s** post client action error line(s) for **%s** account(s) on **%s** day(s) — the Advanced Routing action that runs after a file was received (the delete, typically) failed, the ARRC0009 line, the "Post client action failed" reason of the failure pages. Newest first; the report shows at most **%s** rows and at most **%s** per account (**%s** shown here); the account opens its detail page.'
AR_NOTE='Source: the TM error "ARRC0009: [<account>@<login>] []  Error deleting the file after a post client action." (any AR line whose text names a post client action) — the account is the first bracket, before the @. At most %s rows and %s per account, the newest ones; the totals name what the log holds.'
AR_ENTITY=account
AR_FILE=0
AR_MATCH='post client action'
# the account = the first bracket before the @; the body must be about a
# post client action (the prefilter matched the raw message)
AR_EXTRACT='if (BODY ~ /post client action/) { ent = B1; sub(/@.*$/, "", ent) }'

arlist_run
