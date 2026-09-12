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
# ctx_enrich(msg, prev): a BARE "Permission denied" line says nothing on its
# own — the platform logs WHAT it was doing on the Info line just before it
# ("Deleting remote file: done.txt under /OUT/."). The collectors (failed.sh:
# the page candidates and the _errpage-evidence sidecar) pass that previous
# line here; the bare message comes back with it attached, so every consumer
# classifying the same text sees the context (2026-09-06, user report).
function ctx_enrich(msg, prev,   m) {
    m = tolower(msg); sub(/^[ \t]+/, "", m); sub(/[ \t.]+$/, "", m)
    if (m == "permission denied" && prev != "") return msg " [after: " substr(prev, 1, 120) "]"
    return msg
}
function flip_reason(msg,   m) {
    m = tolower(msg)
    # the FTPS pull leg failing wholesale (2026-08-31, user request): the
    # verbatim message string IS the verdict, so it outranks every other rule
    if (m ~ /pull via ftps failed/) return "Pull via FTPS failed"
    # the platform failing to READ (or write) a file on its OWN storage —
    # "IO Error reading file /data/FlowManager/<account>@<login>/<file>", or
    # the Java/POSIX "Input/output error" — a storage problem, never the
    # remote end (2026-09-06, user request: the IO errors server report).
    # BEFORE the connection rule: a torn-down session may follow the IO line,
    # but the IO line is the cause.
    if (m ~ /(^|[^a-z])io error|input\/output error/) return "IO error"
    # a READ TIMEOUT on the transfer's connection — "… Read timed out" (the
    # Java socket wording): the far end stopped answering mid-transfer.
    # BEFORE the connection rule, whose "connection failure" wrapping the
    # same line may carry would otherwise claim it (2026-09-08, user request).
    if (m ~ /read timed out/) return "Read timed out"
    # a STREAM READ/WRITE ERROR on the transfer's connection — a line that
    # STARTS with "Stream read/write error." (2026-09-12, user request; an
    # optional "[Ssh Default] " component tag may precede it): the data
    # stream broke mid-transfer. BEFORE the fingerprint / connection rules,
    # whose words the exception text after it may carry.
    if (m ~ /^(\[[^]]*\] *)?stream read\/write error\./) return "Stream read/write error"
    if (m ~ /wrong server fingerprint|host key|fingerprint mismatch/) return "Wrong server fingerprint"
    if (m ~ /connection failure|could not be established|failed to connect|failed to create connection|connection refused|connection timed out|connection reset|unable to connect/) return "Connection failures"
    if (m ~ /receive file as/) return "Receive File As not set"
    # the PUBLISH to the account failing — "ARPA0001: … An error occurred while
    # publishing the file {…} to an account. Step configuration suggests to
    # stop further route execution." — the file never reached the account;
    # BEFORE the Route stopped rule, whose "stop further route execution"
    # tail would otherwise claim it (2026-09-06, user report; the Step
    # {Publish} rule further down covers the AR0111 wording of the same).
    # Reads "Duplicate file" since 2026-09-12 (user request; it was "Publish
    # to account failed") — the same reason as the failed send below.
    if (m ~ /while publishing the file/) return "Duplicate file"
    # the SEND of the file to CFT failing — AR0074 "Could not send file: {…}
    # using transfer site: {AXWAY-CFT-PRODUCTION}", the ARSP0001 "An error
    # occurred while sending the file {…} to a partner site. Step
    # configuration suggests to stop further route execution" that follows
    # it, and the AR0111 Step {SendToPartner} line: one failed delivery leg.
    # The "partner site" of these lines is the CFT transfer site, never the
    # external partner (2026-09-06, user report + correction). The reason
    # reads "Duplicate file" since 2026-09-12 (user request; it was "Could
    # not send to CFT") — the server report "Could not send file" lists the
    # AR0074 lines themselves.
    if (m ~ /could not send file|while sending the file .* to a partner site|step \{sendtopartner\}/) return "Duplicate file"
    if (m ~ /arpa0001|arsp0001|stop further route execution/) return "Route stopped"
    # The platform refusing its OWN file: "Permission denied. <path> file is
    # marked as in-process by Advanced Routing." — the file is locked by a
    # routing step still holding it, not a credentials problem. BEFORE the
    # login rule, whose "permission denied" would otherwise claim it
    # (2026-09-06, user report on a UC1 flow).
    if (m ~ /marked as in-process/) return "File is marked as in-process"
    # the post-download DELETE of the remote file refused — the bare
    # "Permission denied" after a "Deleting remote file:" line (attached by
    # ctx_enrich), BEFORE the login rule (2026-09-06, user report)
    if (m ~ /deleting remote file/) return "Delete remote file failed"
    # a failure of the POST CLIENT ACTION — "Error deleting the file after a
    # post client action" included: the delete is the action's own step, so
    # this outranks the delete rules below (2026-09-06, user report)
    if (m ~ /post client action/) return "Post client action failed"
    if (m ~ /authentication fail|password|publickey|public key|not authorized|login failed|permission denied/) return "Login errors (out)"
    # The post-download DELETE of the remote file failing — "No such file:
    # Cannot delete file." (the file was fetched, then vanished or proved
    # undeletable at the partner): a delete problem, not a missing directory.
    # BEFORE the "no such file" rule, which read it as No Dir (2026-09-02,
    # user report on a UC3 flow whose 40 MB download had succeeded).
    if (m ~ /cannot delete|could not delete|failed to delete|error deleting/) return "Delete remote file failed"
    if (m ~ /no such file|no such directory|does not exist/) return "No Dir"
    if (m ~ /file unavailable|file not found|requested action not taken/) return "Remote file unavailable"
    if (m ~ /listing files|listing the files|list files/) return "Listing failed"
    if (m ~ /transfer site id is not present/) return "Transfer site missing"
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
    # the Advanced Routing PUBLISH step failing — "Step {Publish} with id {…}
    # finished with error … No files were processed.": the file never reached
    # the account it was to be published to. BEFORE the generic routing-step
    # rule (2026-09-06, user report on a UC2 flow).
    if (m ~ /step \{publish\}/) return "Duplicate file"   # was "Publish to account failed" (2026-09-12)
    if (m ~ /arrc00|ar0111|step \{/) return "Routing step failed"
    # LAST, the fallback with no error line at all (2026-09-10, user request):
    # the platform's own "Transfer end logged." bookend with "status":"error"
    # — an INFO record, admitted as a candidate by failed.sh only when it
    # names one of the File's own legs (the collectors keep every other
    # Info line out). What it marks, every time it was examined, is a
    # partner client tearing its connection down mid-transfer: the platform
    # books the error silently, no Error/Warning line anywhere. Any real
    # error line above outranks it (errors first, then the rest in page
    # order — the bookend closes the transfer, so it comes last). Reads
    # "Unknown error" since 2026-09-12 (user request; it was "Connection
    # dropped mid-transfer") — no error line says what went wrong.
    if (m ~ /"message":"transfer end logged\."/ && m ~ /"status":"error"/) return "Unknown error"
    return ""
}
