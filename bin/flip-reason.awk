# bin/flip-reason.awk — the server-log EVIDENCE CLASSIFIER, shared text.
#
# flip_reason(msg) maps one server-log line to a short cause in the Boxes
# pages' vocabulary, or "" when the line says nothing recognisable — better a
# blank cell than a guess. TWO consumers inject this file into their awk
# programs with $(cat …) and MUST keep classifying identically, which is why
# the function lives here and not in either of them:
#
#   bin/analyses/publish-insights.sh  the _subs-boxes.tsv reason sidecar the
#                                     home page's red-worklist Reason reads
#   bin/transfer/reports/failed.sh  the Reason column of the Failed
#                                     transfers list, classified per row from
#                                     that file's own drill page
#
# Order matters: the first pattern that matches wins, most specific first —
# a fingerprint rejection also mentions the connection it failed, and must
# not read "Connection failures".
function flip_reason(msg,   m) {
    m = tolower(msg)
    # the FTPS pull leg failing wholesale (2026-08-31, user request): the
    # verbatim message string IS the verdict, so it outranks every other rule
    if (m ~ /pull via ftps failed/) return "Pull via FTPS failed"
    if (m ~ /wrong server fingerprint|host key|fingerprint mismatch/) return "Wrong server fingerprint"
    if (m ~ /connection failure|could not be established|failed to connect|failed to create connection|connection refused|connection timed out|connection reset|unable to connect/) return "Connection failures"
    if (m ~ /receive file as/) return "Receive File As not set"
    if (m ~ /arsp0001|stop further route execution/) return "Route stopped"
    if (m ~ /authentication fail|password|publickey|public key|not authorized|login failed|permission denied/) return "Login errors (out)"
    if (m ~ /no such file|no such directory|does not exist/) return "No Dir"
    if (m ~ /file unavailable|file not found|requested action not taken/) return "Remote file unavailable"
    if (m ~ /listing files|listing the files|list files/) return "Listing failed"
    if (m ~ /transfer site id is not present/) return "Transfer site missing"
    if (m ~ /post client action/) return "Post-action failed"
    # The PeSIT delivery leg (ST -> CFT), rejected or torn down by the far
    # end: a negative SEND_CONF is the receiver REFUSING the file up front
    # (file already exists, a blocking I/O error on its side); a negative
    # ABORT_IND or a plain abort is the transfer dying MID-FLIGHT (checkpoint
    # mismatch, timeout). Two verdicts because the fixes differ — a refusal
    # is operational at the far end, an abort is protocol/network.
    if (m ~ /received negative send_conf/) return "PeSIT delivery refused"
    if (m ~ /pesitnetworkexception|received negative abort_ind/) return "PeSIT transfer aborted"
    # The LOCAL staged object (an /.stfs/ path) gone mid-operation — a
    # staging problem on the platform, not the remote end.
    if (m ~ /\.stfs\/.* not found/) return "Staged file missing"
    # Platform bookkeeping, like the staged object: the post-processing
    # action (a Delete after SendToPartner, in the case that found this)
    # cannot find the file's File Tracking entry. BEFORE the routing-step
    # rule — the AR0086 line can carry a "step {…}" tail and must not read
    # as a generic step failure.
    if (m ~ /could not find file tracking entry/) return "File Tracking entry missing"
    if (m ~ /arrc00|ar0111|step \{/) return "Routing step failed"
    return ""
}
