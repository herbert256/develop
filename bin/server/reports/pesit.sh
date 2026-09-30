#!/usr/bin/env bash
#
# pesit.sh — the PeSIT problem lines of the server log, as ONE sidecar:
# pesit-slots.tsv (date<TAB>slot0-47<TAB>out<TAB>in, nonzero slots only), the
# PeSIT graph view of the dashboards overview (summed to 6-hour slots) and
# the day pages (as-is). NO PAGE since 2026-09-27 (user request: the
# Operations & Capacity group went), and NO .rpt since 2026-09-29 (audit: the
# five tables of pesit.rpt had no reader) — the direction classification
# lives HERE only, never duplicated downstream.
#
# A PROBLEM line is every non-Info PESITD (component P) row plus every
# non-Info TM line naming FPDU / PeSIT or carrying a negative response or a
# diagCode; classify() gives its DIRECTION — OUT = ST -> CFT (the TM PeSIT
# client), IN = CFT -> ST (the PESITD server). classify() is FIRST-MATCH in a
# fixed order (the PesitNetworkException wrappers before the bare FPDU lines
# they quote), so the pick never depends on iteration order.
#
# Usage:
#   ./pesit.sh    # reads the parse cache, writes data/server/reports/pesit-slots.tsv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
# the 30-minute direction-split sidecar (date<TAB>slot0-47<TAB>out<TAB>in,
# nonzero slots only): the dashboards overview (summed to 6-hour slots) and
# the day pages (as-is) read it for their PeSIT hero view — the problem
# classification lives HERE only, never duplicated downstream.
SLOTS="$REPORTS_DIR/pesit-slots.tsv"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$SLOTS"   # no data for this ENV (an env-split legitimate state)
    exit 0
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# ONE pass over the cache: the 30-minute slot counts per direction.
agg=$(awk -F'\t' '
    function jdn(y,m,d,  a){ a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return d+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,  a,b,c,dd,e,mm,day,mon,yr){ a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d",yr,mon,day) }
    # class -> "direction|display name"; OUT = ST->CFT (TM client), IN = CFT->ST (PESITD server)
    function classify(c, m) {
        if (c == "P") {
            if (m ~ /Network error: Connection reset/)                        return "IN|Connection reset by the CFT"
            if (m ~ /exceeded the maximum number of allowed connection/)      return "IN|ST connection ceiling hit (max 100)"
            if (m ~ /exceeded the maximum number of allowed sessions/)        return "IN|ST session ceiling hit"
            if (m ~ /Error sending event|Unable to submit event/)             return "IN|Internal event delivery problem"
            if (m ~ /Send negative FPDU_ACREATE/)                             return "IN|Transfer refused by ST (negative ACREATE sent)"
            return "IN|Other inbound (PESITD) problem"
        }
        # the [Pesit Default] tagged incoming-profile setup error is an
        # INBOUND problem whatever component logged it (2026-09-28 fix: it fell
        # through to the outbound chain as "Other outbound (client) problem")
        if (m ~ /used for incoming transfer/)                               return "IN|Incoming transfer profile without Receive File As"
        if (m ~ /Received negative SEND_CONF/)                                return "OUT|Transfer rejected mid-send (negative SEND_CONF)"
        if (m ~ /Received negative ABORT_IND/)                                return "OUT|Aborted by the CFT (negative ABORT_IND)"
        if (m ~ /Received negative CONNECT_CONF/) {
            if (m ~ /diagCode=309/)                                           return "OUT|CFT connection limit (RCONNECT 309)"
            return "OUT|Connection refused by the CFT (negative CONNECT_CONF)"
        }
        if (m ~ /aborted before SENDENDED/)                                   return "OUT|Transfer aborted before completion (SENDENDED)"
        if (m ~ /Invalid FPDU_AWRITE/)                                        return "OUT|Checkpoint mismatch (invalid FPDU_AWRITE)"
        if (m ~ /Too many connections for this CT/)                           return "OUT|CFT connection limit (RCONNECT 309)"
        if (m ~ /required SSL/)                                               return "OUT|SSL required / handshake mismatch (code 399)"
        if (m ~ /Blocking I\/O error/)                                        return "OUT|CFT file I/O error (Blocking I/O)"
        if (m ~ /File already exists/)                                        return "OUT|File already exists at the CFT"
        if (m ~ /Failure in opening file/)                                    return "OUT|CFT failed to open the file"
        if (m ~ /FPDU_LOGIN/ && m ~ /Network incident/)                       return "OUT|Login failed - network incident (FPDU_LOGIN)"
        if (m ~ /FPDU_ABORT/ && m ~ /Time out/)                               return "OUT|Timeout (FPDU_ABORT)"
        if (m ~ /Receive negative FPDU_ACREATE/)                              return "OUT|Transfer refused by the CFT (negative ACREATE, unspecified)"
        if (m ~ /FPDU_ADESELECT/)                                             return "OUT|Session deselect refused (negative ADESELECT)"
        return "OUT|Other outbound (client) problem"
    }
    # one qualifying problem line (d already date-validated): its 30-minute
    # slot (0-47) on its direction
    function prob(d,   t2, cp, s) {
        t2 = $2
        split(classify($4, $5), cp, "|")
        s = (t2 ~ /^[0-9][0-9]:[0-9][0-9]/) ? substr(t2, 1, 2) * 2 + (substr(t2, 4, 2) + 0 >= 30 ? 1 : 0) : 0
        if (cp[1] == "OUT") souts[d, s]++; else sins[d, s]++
        allday[d] = 1
    }
    $4 == "P" {
        if ($3 == "I") next
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        prob(d)
        next
    }
    $4 == "T" && $3 != "I" {
        # TM lines qualify on FPDU/PeSIT keywords OR the negative-response
        # shapes that carry neither ("Received negative CONNECT_CONF/ABORT_IND
        # response: diagCode=..." — 4,160 real ST->CFT failures)
        if ($5 !~ /FPDU|[Pp][Ee][Ss][Ii][Tt]|Received negative|diagCode=/) next
        d = $1; if (d !~ /^[0-9][0-9][0-9][0-9]-/) next
        prob(d)
        next
    }
    END {
        mn = 0; mx0 = 0
        for (d in allday) { split(d, pp, "-"); j = jdn(pp[1]+0, pp[2]+0, pp[3]+0); if (mn == 0 || j < mn) mn = j; if (j > mx0) mx0 = j }
        if (mn == 0) exit
        # a CALENDAR walk, so the order is deterministic — never awk hash order
        for (j = mn; j <= mx0; j++) {
            d = fromjdn(j)
            for (s = 0; s < 48; s++)
                if ((d, s) in souts || (d, s) in sins)
                    printf "%s\t%d\t%d\t%d\n", d, s, souts[d, s]+0, sins[d, s]+0
        }
    }
' "$(srv_subset noninfo)")   # the non-Info lines (2026-09-30): both rules skip level I

if [ -z "$agg" ]; then echo "No PeSIT problem records found." >&2; rm -f "$SLOTS"; exit 0; fi
# tmp+mv, so its readers never see a torn write
printf '%s\n' "$agg" > "$SLOTS.tmp"
mv "$SLOTS.tmp" "$SLOTS"

echo "Data written to $SLOTS ($(printf '%s\n' "$agg" | wc -l | tr -d ' ') nonzero 30-minute slot(s))." >&2
