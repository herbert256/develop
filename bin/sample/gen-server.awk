# bin/sample/gen-server.awk — stage 5: sorted S rows -> per-day server CSVs.
# Input: the S rows of _events.tsv sorted by absms DESCENDING; one
# logEntry_MM-DD.csv per day, header first. All 20 fields double-quoted;
# embedded quotes doubled; the \x01 placeholder becomes a REAL newline inside
# the quoted Message — the multi-line record shape the parser re-joins.
#
#   awk -F'\t' -f prelude.awk -f gen-server.awk -v DIR=input/<env>/server
BEGIN {
    HDR = "Time, Level, Component, Thread, Message, Filename, Class, Method, Line, Account or Login, Stack Trace, Activity, Transferred File, Client Hostname, Edge Hostname, Server Hostname, Node Name, Session ID, Session Start Time, Transfer ID"
    LV["I"] = "INFO"; LV["W"] = "WARN"; LV["E"] = "ERROR"
    STK = "java.lang.IllegalStateException: SafeCluster has been shutdown at com.tangosol.coherence.component.util.SafeCluster.ensureRunningCluster(SafeCluster.java:625) at java.base/java.lang.Thread.run(Unknown Source)"
}
function q(s) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
$1 != "S" { next }
{
    abs = $2 + 0
    day = abs_iso(abs)
    if (day != CUR) {
        if (CUR != "") close(OUTF)
        CUR = day
        OUTF = DIR "/logEntry_" substr(day, 6, 2) "-" substr(day, 9, 2) ".csv"
        print HDR > OUTF
    }
    # the message is everything after the 5th field (it never contains a TAB)
    msg = $0
    for (i = 1; i <= 5; i++) sub(/^[^\t]*\t/, "", msg)
    gsub(/\x01/, "\n", msg)
    sid = $5
    srnd(hash("sfmt|" abs "|" substr(msg, 1, 24)))
    stack = ($4 == "ADMIN" && $3 == "W") ? STK : "UNKNOWN"
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", \
        q(fmt_ts(abs)), q(LV[$3]), q($4), q("requestExecutor" (800000 + rint(99999))), q(msg), \
        q("BaseConfigAgent.java"), q("com.tumbleweed.st.server.tm.agents.BaseConfigAgent"), \
        q("logAuthResultMessage"), q(300 + rint(400)), q("UNKNOWN"), q(stack), q("UNKNOWN"), \
        q("UNKNOWN"), q("UNKNOWN"), q("UNKNOWN"), q("UNKNOWN"), q("192.0.2.76"), \
        q(sid == "" ? "UNKNOWN" : sid), q(sid == "" ? "unknown" : fmt_ts(abs - 5000 - rint(60000))), q("UNKNOWN") > OUTF
}
