#!/usr/bin/env bash
#
# inbound-connections.sh — who connects IN to SecureTransport, over which
# protocol, from where. From the TM "User with login name "L", associated with
# account "A", had initiated a connection over SSH|PESIT|FTP. Remote address:
# <addr>" lines — the only place the per-protocol INBOUND connection volume
# exists (Auth Activity counts SSH auth successes only, Logon the screening
# funnel; FTP and PeSIT connection volume appears nowhere else). Five views:
#   By protocol       connection volume per protocol.
#   Per day           the SSH / PESIT / FTP daily trend.
#   By account        connections per account (protocol mix, distinct addresses).
#   By source address the remote peers that connect in, top 50.
#   Whitelist policies which Login Restriction Policy actually matches, from the
#                     "Allowed user … corresponding policy name '<P>'" lines.
#
# An account equal to a known transfer-log account links to its detail page
# (same alink mechanism as Transfer Outcomes); addresses stay plain — they are
# the partners' SOURCE addresses, not the configured outbound endpoints.
#
# Reads the parse cache (data/_parse.tsv). Writes data/inbound-connections.rpt.
#
# Usage:
#   ./inbound-connections.sh    # reads input/*.csv (via the cache), writes data/inbound-connections.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/inbound-connections.rpt"

# Entity cross-links: known account names from the transfer-side account report
# (ROW field 2 of its FIRST table) — same mechanism as transfer-outcomes.sh.
TDATA="$TRANSFER_REPORTS"
TACCT="$TDATA/account.rpt"
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
LINK_AWK='
    function acctlink(t,   s) {
        if (t in kacct) return "@{alink=accounts/" t "}"
        s = t; sub(/@.*$/, "", s)
        if (s in kacct) return "@{alink=accounts/" s "}"
        return ""
    }
'

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
ensure_parsed
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TACCT"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass. Emits TAB-separated:
#   P <TAB> proto <TAB> conns <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   Y <TAB> date <TAB> ssh <TAB> pesit <TAB> ftp <TAB> other <TAB> total
#   A <TAB> [alink]account <TAB> conns <TAB> protos <TAB> naddr <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   S <TAB> addr <TAB> conns <TAB> naccts <TAB> protos <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   W <TAB> policy <TAB> allowed <TAB> naccts <TAB> buckets <TAB> first <TAB> last
#   TOT <TAB> conns <TAB> nproto <TAB> nacct <TAB> naddr <TAB> allowed <TAB> npol <TAB> ndays
agg=$(awk -F'\t' "$LOGLINES_AWK$LINK_AWK"'
    # qval(m, key, q): the value right after `key` that is enclosed in quote
    # character q — "" when the key or its opening quote is absent.
    function qval(m, key, q,   p, s, e) { p = index(m, key); if (p == 0) return ""
        s = substr(m, p + length(key)); if (substr(s, 1, 1) != q) return ""
        s = substr(s, 2); e = index(s, q); return e ? substr(s, 1, e - 1) : "" }
    function addset(k, v) {   # union string with "/" separators, substring-safe
        if (!index("/" uni[k] "/", "/" v "/")) uni[k] = uni[k] (uni[k] ? "/" : "") v }
    function acc(ns, key, d,   k, dk) { k = ns SUBSEP key; cnt[k]++
        if (d != "") { dk = k SUBSEP d; dd[dk]++
            if (!(dk in dseen)) { dseen[dk]=1; dlist[k] = dlist[k] (dlist[k]?",":"") d }
            if (!(k in fst) || d < fst[k]) fst[k]=d
            if (!(k in lst) || d > lst[k]) lst[k]=d } }
    BEGIN { DQ = "\""; SQ = sprintf("%c", 39) }
    $1 == "KA" { kacct[$2] = 1; next }                       # known-account list (first input)
    {
        m = $5
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        # --- the whitelist-policy "Allowed user" lines ---
        if (index(m, "corresponding policy name ")) {
            pol = qval(m, "corresponding policy name ", SQ)
            if (pol != "") {
                wacct = qval(m, "corresponding account ", SQ)
                acc("W", pol, d); allowed++
                if (wacct != "" && !((pol SUBSEP wacct) in wpa)) { wpa[pol SUBSEP wacct]=1; wpn[pol]++ }
            }
            next
        }
        # --- the inbound-connection lines ---
        if (!index(m, "had initiated a connection over ")) next
        if (!match(m, /had initiated a connection over [A-Za-z0-9]+/)) next
        proto = substr(m, RSTART + 32, RLENGTH - 32)   # 32 = length of "had initiated a connection over "
        un = qval(m, "login name ", DQ)
        an = qval(m, "associated with account ", DQ)
        if (an == "") an = "(none)"
        addr = ""
        if (match(m, /Remote address: [^ ]+/)) { addr = substr(m, RSTART + 16, RLENGTH - 16); sub(/[.,;]+$/, "", addr) }
        if (addr == "") addr = "(none)"
        line = lvlname($3) " " compname($4) "  " substr(m, 1, 200)
        conns++

        acc("P", proto, d); addline("P" SUBSEP proto, $1 " " $2, line)
        acc("A", an, d);    addline("A" SUBSEP an, $1 " " $2, line)
        acc("S", addr, d);  addline("S" SUBSEP addr, $1 " " $2, line)
        addset("A" SUBSEP an, proto); addset("S" SUBSEP addr, proto)
        if (!((an SUBSEP addr) in aad)) { aad[an SUBSEP addr]=1; an_addr[an]++ }
        if (!((addr SUBSEP an) in saa)) { saa[addr SUBSEP an]=1; s_acct[addr]++ }
        if (d != "") {
            yseen[d] = 1; yt[d]++
            if (proto == "SSH") ys[d]++; else if (proto == "PESIT") yp[d]++
            else if (proto == "FTP") yf[d]++; else yo[d]++
        }
    }
    END {
        np=0; na=0; ns=0; nw=0
        for (k in cnt) {
            split(k, a, SUBSEP); nsp=a[1]; key=a[2]
            m2 = split(dlist[k], dz, ","); bk=""
            for (i=1;i<=m2;i++){ dd2=dz[i]; bk=bk (bk?",":"") dd2 ":" dd[k SUBSEP dd2] }
            if (nsp == "P") { np++
                printf "P\t%s\t%d\t%s\t%s\t%s\t%s\n", key, cnt[k], bk, fst[k], lst[k], lastlines(k) }
            else if (nsp == "A") { na++
                printf "A\t%s%s\t%d\t%s\t%d\t%s\t%s\t%s\t%s\n", acctlink(key), key, cnt[k], uni[k], an_addr[key]+0, bk, fst[k], lst[k], lastlines(k) }
            else if (nsp == "S") { ns++
                printf "S\t%s\t%d\t%d\t%s\t%s\t%s\t%s\t%s\n", key, cnt[k], s_acct[key]+0, uni[k], bk, fst[k], lst[k], lastlines(k) }
            else { nw++
                printf "W\t%s\t%d\t%d\t%s\t%s\t%s\n", key, cnt[k], wpn[key]+0, bk, fst[k], lst[k] }
        }
        ndays=0
        for (d in yseen) { ndays++
            printf "Y\t%s\t%d\t%d\t%d\t%d\t%d\n", d, ys[d]+0, yp[d]+0, yf[d]+0, yo[d]+0, yt[d]+0 }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", conns+0, np, na, ns, allowed+0, nw, ndays
    }
' <(known_names KA "$TACCT") "$PARSED")

IFS=$'\t' read -r _ t_conn n_proto n_acct n_addr t_allow n_pol n_days <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ $(( ${t_conn:-0} + ${t_allow:-0} )) -eq 0 ]; then
    # No inbound-connection messages in this log window — write an EMPTY-STATE
    # page (so the report still renders and its group-nav link never 404s).
    echo "No inbound-connection messages found — writing an empty report." >&2
    {
        printf 'TITLE\tInbound Connections\n'
        printf 'DESC\tWho connects in to SecureTransport, over which protocol (SSH, PeSIT, FTP), from which addresses — the per-protocol inbound connection volume.\n'
        printf 'KEYWORDS\twhitelist, login restriction policy, source IP, partner address\n'
        printf 'INTRO\tNo inbound-connection messages in this log window.\n'
        printf 'TABLE\tConnections by protocol\twide\n'
        printf 'HEAD\tProtocol\tConnections\tFirst\tLast\n'
        printf 'KIND\ttext\tnum\ttext\ttext\n'
        printf 'ROW\t@{colspan=4}No inbound-connection messages in this data window.\n'
        printf 'SUMMARY\tInbound connections: 0\n'
        printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    exit 0
fi

# The five row writers print STRAIGHT to stdout inside the page block below —
# a `rows+=$(printf …)` per row forks a subshell per row for nothing.
proto_rows() {
    while IFS=$'\t' read -r _ proto count bk fst lst lines; do
        [ -z "$proto" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$proto" "$count" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^P\t' | sort -t"$(printf '\t')" -k3,3nr -k2,2)"
}

day_rows() {
    while IFS=$'\t' read -r _ d s p f o t; do
        [ -z "$d" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$s" "$p" "$f" "$o" "$t"
    done <<< "$(printf '%s\n' "$agg" | grep $'^Y\t' | sort -t"$(printf '\t')" -k2,2)"
}

acct_rows() {
    while IFS=$'\t' read -r _ name count protos naddr bk fst lst lines; do
        [ -z "$name" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$name" "$count" "$protos" "$naddr" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^A\t' | sort -t"$(printf '\t')" -k3,3nr -k2,2)"
}

# Top 50 by connections: shown_addr / shown_conns carry the capped counts out to
# the total row (the block below is a brace group, not a subshell, so the label
# is built there — right after the rows are written).
shown_addr=0
shown_conns=0
addr_rows() {
    while IFS=$'\t' read -r _ addr count naccts protos bk fst lst lines; do
        [ -z "$addr" ] && continue
        [ "$shown_addr" -ge 50 ] && break
        shown_addr=$((shown_addr + 1)); shown_conns=$((shown_conns + count))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$addr" "$count" "$naccts" "$protos" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^S\t' | sort -t"$(printf '\t')" -k3,3nr -k2,2)"
}

pol_rows() {
    while IFS=$'\t' read -r _ pol count naccts bk fst lst; do
        [ -z "$pol" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\n' "$pol" "$count" "$naccts" "$fst" "$lst" "$bk"
    done <<< "$(printf '%s\n' "$agg" | grep $'^W\t' | sort -t"$(printf '\t')" -k3,3nr -k2,2)"
}

{
    printf 'TITLE\tInbound Connections\n'
    printf 'DESC\tWho connects in to SecureTransport, over which protocol (SSH, PeSIT, FTP), from which addresses — the per-protocol inbound connection volume.\n'
    printf 'KEYWORDS\twhitelist, login restriction policy, source IP, partner address\n'
    printf 'INTRO\t**%s** inbound connection(s) over **%s** protocol(s) from **%s** account(s) and **%s** source address(es) across **%s** day(s). This is connection VOLUME — every "had initiated a connection" line, before any transfer happens; Auth Activity counts SSH authentication successes and Logon the screening funnel. Whitelist policies matched **%s** allowed connection(s). Click a row for its 10 most recent connection lines.\n' \
        "$t_conn" "$n_proto" "$n_acct" "$n_addr" "$n_days" "$t_allow"

    printf 'TABLE\tConnections by protocol\twide\n'
    printf 'HEAD\tProtocol\tConnections\tFirst\tLast\n'
    printf 'KIND\ttext\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\n'
    proto_rows
    printf 'TOTAL\tTotal (%s protocol(s))\t@{class=num}%s\t\t\n' "$n_proto" "$t_conn"
    printf 'NOTE\tOne count per "had initiated a connection over <protocol>" line. FTP and PeSIT inbound volume appears in no other report. Counts are additive and re-total under the date filter.\n'

    printf 'TABLE\tConnections per day\twide\n'
    printf 'HEAD\tDate\tSSH\tPESIT\tFTP\tOther\tTotal\n'
    printf 'KIND\ttext\tnum\tnum\tnum\tnum\tnum\n'
    day_rows
    printf 'TOTAL\tTotal (%s day(s))\t\t\t\t\t@{class=num}%s\n' "$n_days" "$t_conn"
    printf 'NOTE\tThe daily protocol mix. A protocol falling silent, or a sudden connection spike from one day to the next, stands out here first.\n'

    printf 'TABLE\tBy account\twide\n'
    printf 'HEAD\tAccount\tConnections\tProtocols\tAddresses\tFirst\tLast\n'
    printf 'KIND\tmono\tnum\ttext\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\t-\n'
    acct_rows
    printf 'TOTAL\tTotal (%s account(s))\t@{class=num}%s\t\t\t\t\n' "$n_acct" "$t_conn"
    printf 'NOTE\tConnections per account (as logged; an account known from the transfer logs links to its detail page). Addresses is the distinct source addresses seen for that account over the whole period — it does not re-aggregate under the date filter. Click an account for its 10 most recent connection lines.\n'

    printf 'TABLE\tBy source address\twide\n'
    printf 'HEAD\tAddress\tConnections\tAccounts\tProtocols\tFirst\tLast\n'
    printf 'KIND\tmono\tnum\tnum\ttext\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\t-\n'
    addr_rows
    if [ "$shown_addr" -lt "${n_addr:-0}" ]; then
        addr_total_label="Top $shown_addr of $n_addr address(es)"
    else
        addr_total_label="Total ($n_addr address(es))"
    fi
    printf 'TOTAL\t%s\t@{class=num}%s\t\t\t\t\n' "$addr_total_label" "$shown_conns"
    printf 'NOTE\tThe partners'\'' SOURCE addresses (what actually connects in — the address the whitelist allows), not the configured outbound endpoints. Accounts is the distinct accounts seen from that address over the whole period. Top 50 by connections; the total row sums the shown rows. Click an address for its 10 most recent connection lines.\n'

    if [ "${t_allow:-0}" -gt 0 ]; then
        printf 'TABLE\tWhitelist policy usage\n'
        printf 'HEAD\tPolicy\tAllowed\tAccounts\tFirst\tLast\n'
        printf 'KIND\ttext\tnum\tnum\ttext\ttext\n'
        printf 'RECALC\t-\ts0\t-\t-\t-\n'
        pol_rows
        printf 'TOTAL\tTotal (%s polic(ies))\t@{class=num}%s\t\t\t\n' "$n_pol" "$t_allow"
        printf 'NOTE\tWhich Login Restriction Policy the "Allowed user … corresponding policy name" screening lines actually matched — the policies doing the work, next to Logon'\''s per-login funnel. Accounts is the distinct accounts allowed under that policy (whole period).\n'
    fi

    printf 'SUMMARY\tConnections: %s  |  Protocols: %s  |  Accounts: %s  |  Addresses: %s  |  Policy-allowed: %s (%s policies)\n' \
        "$t_conn" "$n_proto" "$n_acct" "$n_addr" "$t_allow" "$n_pol"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_conn connection(s), $n_acct account(s), $n_addr address(es), $t_allow policy-allowed)." >&2
