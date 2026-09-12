#!/usr/bin/env bash
#
# publish-failed.sh — "Publish to account failed" (2026-09-12, user request):
# the Advanced Routing ARPA0001 lines, one row per line, newest first. From
# the TM message
#
#   ARPA0001: [SECURETRANSPORT] [UC2_ODV_MAIA_SCHUBERGPHILIS]  An error
#   occurred while publishing the file {AIMAPF_NL81ABNA0438073703_11-09-2026.XML}
#   to an account. Step configuration suggests to stop further route execution
#
# The ROUTE — the subscription — is the SECOND bracket group (flip-reason.awk
# reads the same line as the "Duplicate file" reason); the File is the {…}
# after "while publishing the file". The row is Date & time (to the second)
# · Subscription · File; at most 1000 rows and 10 per subscription, the
# newest. The shared body — bin/server/arlist.sh — does the rest.
#
# Usage:
#   ./publish-failed.sh   # reads input/*.csv (via the cache), writes data/publish-failed.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../arlist.sh"
mkdir -p "$REPORTS_DIR"

AR_BASENAME=publish-failed
AR_TITLE="Publish to account failed"
AR_DESC='The Advanced Routing "An error occurred while publishing the file … to an account" errors (ARPA0001): the route could not publish a file into its account — per line, newest first, with the subscription and the file.'
AR_KEYWORDS='publish to account failed,publishing the file,ARPA0001,publish,route stopped,advanced routing,delivery,uc2,route'
AR_INTRO_NONE='No **publish to account** failure in this data window — no Advanced Routing route failed to publish a file into its account.'
AR_INTRO='**%s** "publishing the file … to an account" error line(s) for **%s** subscription(s) on **%s** day(s) — an Advanced Routing route that could not publish a file into its account and stopped (the ARPA0001 error, the "Duplicate file" reason of the failure pages). Newest first; the report shows at most **%s** rows and at most **%s** per subscription (**%s** shown here); the subscription opens its detail page.'
AR_NOTE='Source: the TM error "ARPA0001: [SECURETRANSPORT] [<subscription>]  An error occurred while publishing the file {<file>} to an account. Step configuration suggests to stop further route execution" — the route is the second bracket, the File the braces. At most %s rows and %s per subscription, the newest ones; the totals name what the log holds.'
AR_ENTITY=subscription
AR_FILE=1
AR_MATCH='while publishing the file'
# the route (B2) is the subscription; the File = the {…} after "while
# publishing the file" (its basename, should a path ever appear)
AR_EXTRACT='ent = B2; b = index(BODY, "while publishing the file")
            if (b == 0) ent = ""; else fn = basename(ar_brace(substr(BODY, b)))'

arlist_run
