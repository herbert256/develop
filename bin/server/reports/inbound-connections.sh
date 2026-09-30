#!/usr/bin/env bash
#
# inbound-connections.sh — CONNECTION VOLUME, in AND out (the first three
# tabs of the merged Connections report). From the TM "User with login name
# "L", associated with account "A", had initiated a connection over
# SSH|PESIT|FTP. Remote address: <addr>" lines. THE DIRECTION (2026-09-29):
# a partner connecting IN logs its login name; SecureTransport's own
# connection OUT to a partner logs login name "" (bin/logons.sh books those
# lines as our outbound connections, the Remote address being the TARGET).
# Until 2026-09-29 every line counted as inbound — the name of this script
# is historical. Three views, each split In / Out:
#   Connections per day   the In / Out and SSH / PESIT / FTP daily trend.
#   By account            connections per account (protocol mix, distinct addresses).
#   By address            the remote peers, top 50 by connections.
# (A "Whitelist policy usage" view went 2026-09-28 and the "by protocol"
# table 2026-09-29 — the per-day table carries its per-protocol split.)
#
# An account equal to a known transfer-log account links to its detail page
# (the alink mechanism — the renderer resolves it through the details
# slugmap); addresses stay plain. The account is the ACCOUNT: the log writes
# "ACCOUNT@LOGIN" on an inbound line and the bare ACCOUNT on an outbound one,
# so the @LOGIN tail is stripped: an account is ONE row, its In and Out
# together, whichever login connected (2026-09-29 audit). The row count is
# the inbound accounts (Logons > By account) plus the accounts only our
# outbound connections name.
#
# Reads the parse cache (data/server/cache/_parse.tsv). Writes
# data/server/reports/inbound-connections.rpt (the _inbound-addr.tsv sidecar
# went 2026-09-29 with its readers, the Whitelist audit and the Cleanup backlog).
#
# Usage:
#   ./inbound-connections.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/inbound-connections.rpt"

# Entity cross-links: known account names from the transfer-side account report
# (ROW field 2 of its FIRST table).
TDATA="$TRANSFER_REPORTS"
TACCT="$TDATA/account.rpt"
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
# + every CONFIGURED account (2026-09-30 audit S-01: an account with a detail
# page but no transfer is absent from account.rpt and stayed unlinked)
base_names() {   # $1 marker  $2 base cache — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1 != "" { print M "\t" $1 }' "$2"
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

# One pass. Emits TAB-separated:
#   Y <TAB> date <TAB> in <TAB> out <TAB> ssh <TAB> pesit <TAB> ftp <TAB> other <TAB> total
#   A <TAB> [alink]account <TAB> conns <TAB> in <TAB> out <TAB> protos <TAB> naddr <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   S <TAB> addr <TAB> conns <TAB> in <TAB> out <TAB> naccts <TAB> protos <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   TOT <TAB> conns <TAB> nproto <TAB> nacct <TAB> naddr <TAB> ndays <TAB> in <TAB> out <TAB> ssh <TAB> pesit <TAB> ftp <TAB> other
# buckets = date:total:in:out (RECALC s0 / s1 / s2)
agg=$(awk -F'\t' "$LOGLINES_AWK$LINK_AWK"'
    # qval(m, key, q): the value right after `key` that is enclosed in quote
    # character q — "" when the key or its opening quote is absent.
    function qval(m, key, q,   p, s, e) { p = index(m, key); if (p == 0) return ""
        s = substr(m, p + length(key)); if (substr(s, 1, 1) != q) return ""
        s = substr(s, 2); e = index(s, q); return e ? substr(s, 1, e - 1) : "" }
    function addset(k, v) {   # union string with "/" separators, substring-safe
        if (!index("/" uni[k] "/", "/" v "/")) uni[k] = uni[k] (uni[k] ? "/" : "") v }
    function acc(ns, key, d, io,   k, dk) { k = ns SUBSEP key; cnt[k]++
        if (io == "I") cin[k]++; else cout[k]++
        if (d != "") { dk = k SUBSEP d; dd[dk]++
            if (io == "I") ddi[dk]++; else ddo[dk]++
            if (!(dk in dseen)) { dseen[dk]=1; dlist[k] = dlist[k] (dlist[k]?",":"") d }
            if (!(k in fst) || d < fst[k]) fst[k]=d
            if (!(k in lst) || d > lst[k]) lst[k]=d } }
    BEGIN { DQ = "\""; SQ = sprintf("%c", 39) }
    $1 == "KA" { kacct[$2] = 1; next }                       # known-account list (first input)
    {
        m = $5
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        # --- the connection lines ---
        if (!index(m, "had initiated a connection over ")) next
        if (!match(m, /had initiated a connection over [A-Za-z0-9]+/)) next
        proto = substr(m, RSTART + 32, RLENGTH - 32)   # 32 = length of "had initiated a connection over "
        # THE DIRECTION (2026-09-29): a partner connecting IN logs its login
        # name; SecureTransport opening a connection OUT logs login name ""
        # (bin/logons.sh books those as OUR outbound connections, the Remote
        # address being the TARGET) — until this day every line counted as
        # inbound, and the Whitelist audit / Cleanup backlog read our
        # outbound targets as partner source addresses. ONE TEST, the one
        # bin/logons.sh applies (2026-09-29 audit — an absent key or a
        # single-quoted name used to read as Out here): the literal
        # login name "" = Out, a login NAMED in either quote style = In, a
        # line with neither is no connection this report can place (skipped)
        if (index(m, "login name " DQ DQ)) io = "O"
        else { un = qval(m, "login name ", DQ); if (un == "") un = qval(m, "login name ", SQ)
               if (un == "") next
               io = "I" }
        an = qval(m, "associated with account ", DQ)
        sub(/@.*$/, "", an)                                  # ACCOUNT@LOGIN -> the account (see the header)
        if (an == "") an = "(none)"
        addr = ""
        if (match(m, /Remote address: [^ ]+/)) { addr = substr(m, RSTART + 16, RLENGTH - 16); sub(/[.,;]+$/, "", addr) }
        if (addr == "") addr = "(none)"
        line = lvlname($3) " " compname($4) "  " substr(m, 1, 200)
        conns++; if (io == "I") cin_t++; else cout_t++
        if (!(proto in PS)) { PS[proto] = 1; np++ }
        acc("A", an, d, io);   addline("A" SUBSEP an, $1 " " $2, line)
        acc("S", addr, d, io); addline("S" SUBSEP addr, $1 " " $2, line)
        addset("A" SUBSEP an, proto); addset("S" SUBSEP addr, proto)
        if (!((an SUBSEP addr) in aad)) { aad[an SUBSEP addr]=1; an_addr[an]++ }
        if (!((addr SUBSEP an) in saa)) { saa[addr SUBSEP an]=1; s_acct[addr]++ }
        if (d != "") {
            yseen[d] = 1; yt[d]++
            if (io == "I") yi[d]++; else yx[d]++
            if (proto == "SSH") ys[d]++; else if (proto == "PESIT") yp[d]++
            else if (proto == "FTP") yf[d]++; else yo[d]++
        }
    }
    END {
        na=0; ns=0
        for (k in cnt) {
            split(k, a, SUBSEP); nsp=a[1]; key=a[2]
            m2 = split(dlist[k], dz, ","); bk=""
            for (i=1;i<=m2;i++){ dd2=dz[i]; bk=bk (bk?",":"") dd2 ":" dd[k SUBSEP dd2] ":" (ddi[k SUBSEP dd2]+0) ":" (ddo[k SUBSEP dd2]+0) }
            if (nsp == "A") { na++
                printf "A\t%s%s\t%d\t%d\t%d\t%s\t%d\t%s\t%s\t%s\t%s\n", acctlink(key), key, cnt[k], cin[k]+0, cout[k]+0, uni[k], an_addr[key]+0, bk, fst[k], lst[k], lastlines(k) }
            else if (nsp == "S") { ns++
                printf "S\t%s\t%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\n", key, cnt[k], cin[k]+0, cout[k]+0, s_acct[key]+0, uni[k], bk, fst[k], lst[k], lastlines(k) }
        }
        ndays=0
        for (d in yseen) { ndays++
            ts_t += ys[d]; tp_t += yp[d]; tf_t += yf[d]; to_t += yo[d]   # the per-day TOTAL row sums
            printf "Y\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", d, yi[d]+0, yx[d]+0, ys[d]+0, yp[d]+0, yf[d]+0, yo[d]+0, yt[d]+0 }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", conns+0, np+0, na, ns, ndays, cin_t+0, cout_t+0, ts_t+0, tp_t+0, tf_t+0, to_t+0
    }
' <(known_names KA "$TACCT"; base_names KA "$CONFIG_BASE/_accounts.tsv") "$PARSED")

IFS=$'\t' read -r _ t_conn n_proto n_acct n_addr n_days t_in t_out t_ssh t_pesit t_ftp t_other <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"

TITLE_TXT='Connection volume'
if [ "${t_conn:-0}" -eq 0 ]; then
    # No connection messages in this log window — write an EMPTY-STATE page
    # (so the report still renders and its group-nav link never 404s).
    echo "No connection messages found — writing an empty report." >&2
    {
        printf 'TITLE\t%s\n' "$TITLE_TXT"
        # one stub per table of the full report, so the merged Connections
        # tabs keep their places
        for _t in 'Connections per day' 'By account' 'By address'; do
            printf 'TABLE\t%s\twide\n' "$_t"
            printf 'HEAD\t%s\n' "$_t"
            printf 'KIND\ttext\n'
            printf 'ROW\tNo connection messages in this data window.\n'
        done
        printf 'FOOT\n'
    } > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    exit 0
fi

nz() { [ "${1:-0}" = 0 ] && printf '' || printf '%s' "$1"; }   # a count cell shows blank, never 0

# The row writers print STRAIGHT to stdout inside the page block below —
# a `rows+=$(printf …)` per row forks a subshell per row for nothing.
day_rows() {
    while IFS=$'\t' read -r _ d i o s p f x t; do
        [ -z "$d" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$(nz "$i")" "$(nz "$o")" "$(nz "$s")" "$(nz "$p")" "$(nz "$f")" "$(nz "$x")" "$t"
    done <<< "$(printf '%s\n' "$agg" | grep $'^Y\t' | LC_ALL=C sort -t"$(printf '\t')" -k2,2)"
}

acct_rows() {
    while IFS=$'\t' read -r _ name count ci co protos naddr bk fst lst lines; do
        [ -z "$name" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$name" "$(nz "$ci")" "$(nz "$co")" "$count" "$protos" "$naddr" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^A\t' | LC_ALL=C sort -t"$(printf '\t')" -k3,3nr -k2,2)"
}

# Top 50 by connections: shown_addr / shown_conns carry the capped counts out to
# the total row (the block below is a brace group, not a subshell, so the label
# is built there — right after the rows are written).
shown_addr=0
shown_conns=0
shown_in=0
shown_out=0
addr_rows() {
    while IFS=$'\t' read -r _ addr count ci co naccts protos bk fst lst lines; do
        [ -z "$addr" ] && continue
        [ "$shown_addr" -ge 50 ] && break
        shown_addr=$((shown_addr + 1)); shown_conns=$((shown_conns + count)); shown_in=$((shown_in + ci)); shown_out=$((shown_out + co))
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$addr" "$(nz "$ci")" "$(nz "$co")" "$count" "$naccts" "$protos" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^S\t' | LC_ALL=C sort -t"$(printf '\t')" -k3,3nr -k2,2)"
}

{
    printf 'TITLE\t%s\n' "$TITLE_TXT"

    printf 'TABLE\tConnections per day\twide\n'
    printf 'HEAD\tDate\tIn\tOut\tSSH\tPESIT\tFTP\tOther\tTotal\n'
    printf 'KIND\ttext\tnum\tnum\tnum\tnum\tnum\tnum\tnum\n'
    day_rows
    printf 'TOTAL\tTotal (%s day(s))\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\n' \
        "$n_days" "$(nz "${t_in:-0}")" "$(nz "${t_out:-0}")" "$(nz "${t_ssh:-0}")" "$(nz "${t_pesit:-0}")" "$(nz "${t_ftp:-0}")" "$(nz "${t_other:-0}")" "$t_conn"

    printf 'TABLE\tBy account\twide\n'
    printf 'HEAD\tAccount\tIn\tOut\tConnections\tProtocols\tAddresses\tFirst\tLast\n'
    printf 'KIND\tacct\tnum\tnum\tnum\ttext\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts1\ts2\ts0\t-\t-\t-\t-\n'
    acct_rows
    printf 'TOTAL\tTotal (%s account(s))\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\t\t\t\n' "$n_acct" "$(nz "${t_in:-0}")" "$(nz "${t_out:-0}")" "$t_conn"

    printf 'TABLE\tBy address\twide\n'
    printf 'HEAD\tAddress\tIn\tOut\tConnections\tAccounts\tProtocols\tFirst\tLast\n'
    printf 'KIND\tmono\tnum\tnum\tnum\tnum\ttext\ttext\ttext\n'
    printf 'RECALC\t-\ts1\ts2\ts0\t-\t-\t-\t-\n'
    addr_rows
    if [ "$shown_addr" -lt "${n_addr:-0}" ]; then
        addr_total_label="Top $shown_addr of $n_addr address(es)"
    else
        addr_total_label="Total ($n_addr address(es))"
    fi
    printf 'TOTAL\t%s\t@{class=num}%s\t@{class=num}%s\t@{class=num}%s\t\t\t\t\n' "$addr_total_label" "$(nz "$shown_in")" "$(nz "$shown_out")" "$shown_conns"

    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_conn connection(s): $t_in in, $t_out out; $n_acct account(s), $n_addr address(es))." >&2
