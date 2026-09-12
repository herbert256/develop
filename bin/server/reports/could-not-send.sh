#!/usr/bin/env bash
#
# could-not-send.sh — "Could not send file" (2026-09-12, user request): the
# Advanced Routing AR0074 lines, one row per line, newest first. From the TM
# message
#
#   AR0074: [SECURETRANSPORT] [UC1_CD_IDM_ROTAFORM]  Could not send file:
#   {/.stfs/objects/…/krpdashboard-productie-20260910135425809.xml} using
#   transfer site: {UC1_CD_IDM_ROTAFORM_SFTP_SERVER_ROTAFORM} after
#   attempting {11} times.
#
# The ROUTE — the subscription — is the SECOND bracket group (the same
# reading as uc1-status.sh and flip-reason.awk, where this line is the
# "Duplicate file" reason); the File is the basename of the first {…} after
# "Could not send file:". The row is Date & time (to the second) ·
# Subscription · File; at most 1000 rows and 10 per subscription, the newest.
# The shared body — bin/server/arlist.sh — does the rest; publish-failed.sh
# and post-client-action.sh are its twins (the srv-errors group).
#
# Usage:
#   ./could-not-send.sh   # reads input/*.csv (via the cache), writes data/could-not-send.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../arlist.sh"
mkdir -p "$REPORTS_DIR"

AR_BASENAME=could-not-send
AR_TITLE="Could not send file"
AR_DESC='The Advanced Routing "Could not send file" errors (AR0074): the route gave up delivering a file to its transfer site — per line, newest first, with the subscription and the file.'
AR_KEYWORDS='could not send file,AR0074,send failed,transfer site,after attempting,advanced routing,delivery,cft,push,uc1,route'
AR_INTRO_NONE='No **Could not send file** line in this data window — no Advanced Routing route gave up delivering a file to its transfer site.'
AR_INTRO='**%s** "Could not send file" line(s) for **%s** subscription(s) on **%s** day(s) — an Advanced Routing route that gave up delivering a file to its transfer site after its retries (the AR0074 error, the "Duplicate file" reason of the failure pages). Newest first; the report shows at most **%s** rows and at most **%s** per subscription (**%s** shown here); the subscription opens its detail page.'
AR_NOTE='Source: the TM error "AR0074: [SECURETRANSPORT] [<subscription>]  Could not send file: {<path>} using transfer site: {<site>} after attempting {<n>} times." — the route is the second bracket, the File the last path element. At most %s rows and %s per subscription, the newest ones; the totals name what the log holds.'
AR_ENTITY=subscription
AR_FILE=1
AR_MATCH='Could not send file'
# the route (B2) is the subscription; the File = the basename of the first
# {…} after "Could not send file:" — no path, no row
AR_EXTRACT='ent = B2; b = index(BODY, "Could not send file:")
            if (b == 0) ent = ""; else { fn = basename(ar_brace(substr(BODY, b + 20))); if (fn == "") ent = "" }'

arlist_run
