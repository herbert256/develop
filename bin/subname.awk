# bin/subname.awk — WHICH configured subscription a server-log line NAMES,
# shared awk text (2026-09-05, split out of bin/build/result.sh so the
# went-kaput report applies the identical rule). Inject AFTER $RENAMES_AWK
# (rn_canon_pfx) and call ros_load(base/_subscriptions.tsv) in BEGIN.
#
# subname(msg): every name-shaped token of the message tried, tail-stripped
# (_SCP_/_SSCP_/_CCP_) and rename-folded, against the roster (case-folded)
# -> the configured name; else the first UC-shaped token (a line naming a
# DECOMMISSIONED flow still attributes to that name rather than becoming an
# orphan of its ring); else "" — the line names no flow.
    function ros_load(f,   l9, a9) { while ((getline l9 < f) > 0) { split(l9, a9, "\t"); if (a9[1] != "") ROS[toupper(a9[1])] = a9[1] } close(f) }
    function subname(msg,   m, t, u, uc) {
        m = msg; uc = ""
        while (match(m, /[A-Za-z][A-Za-z0-9_-]*[_-][A-Za-z0-9_-]+/)) {
            t = substr(m, RSTART, RLENGTH); m = substr(m, RSTART + RLENGTH)
            sub(/_(SS?|C)CP_.*$/, "", t)
            t = rn_canon_pfx(t); u = toupper(t)
            if (u in ROS) return ROS[u]
            if (uc == "" && t ~ /^UC[0-9]+[_-]/) uc = t
        }
        return uc
    }
