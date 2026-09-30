#!/usr/bin/env bash
#
# auth-activity.sh — successful inbound authentications: the complement to
# failed-logins. Every "[Ssh Default] User with login name \"…\", associated
# with account \"…\", successfully authenticated over SSH … Remote address: …"
# line records who connected, from where. Per account and per source IP — a
# baseline of who is actually logging in that the transfer logs don't give
# (they start at the transfer, after auth). (The third table — shared
# certificates per serial, the Logons › Certificates tab — went 2026-09-30,
# user request.)
#
# Reads the parse cache (data/_parse.tsv: 1=date, 2=time, 4=component, 5=message).
# Accounts are shown as logged with the @endpoint suffix stripped (mono); an
# account matching a known transfer-log account is linked to its detail page,
# the rest stay plain text.
#
# Usage:
#   ./auth-activity.sh    # reads input/*.csv (via the cache), writes data/auth-activity.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/auth-activity.rpt"

# Entity cross-links: known account names from the transfer Account report
# (ROW field 2 of its FIRST table). An account that matches a known one —
# exactly, or after stripping its @endpoint suffix — gets an @{link=…} prefix
# on its cell (rendered by bin/publish_lib.sh render_cell as a link to its
# detail page); unresolved accounts stay plain text. Linking is skipped when
# the transfer report is absent.
TDATA="$TRANSFER_REPORTS"
TACCT="$TDATA/account.rpt"
# (known_names: bin/server/lib.sh since 2026-09-30)
# + every CONFIGURED account (2026-09-30 audit S-01: an account with a detail
# page but no transfer is absent from account.rpt and stayed unlinked)
base_names() {   # $1 marker  $2 base cache — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1 != "" { print M "\t" $1 }' "$2"
}
# LINK_AWK — acctlink() returns the @{alink=…} cell prefix (resolved through
# the slugmap at render time) for a known account (exact, also @endpoint-stripped), or "" when unresolved.
LINK_AWK="$SRV_ACCTLINK_AWK"   # bin/server/lib.sh (2026-09-30)

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No files matching '*.csv' found in '$INPUT_DIR'" >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass. SSH successful-auth lines feed the account and source-IP tables. Emits:
#   AC <TAB> account <TAB> logins <TAB> nIPs <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   IP <TAB> ip <TAB> logins <TAB> nAccts <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   TOT <TAB> logins <TAB> naccts <TAB> nips
agg=$(awk -F'\t' "$LOGLINES_AWK$LINK_AWK"'
    $1 == "KA" { kacct[$2] = 1; next }                       # known-account list (first input)
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        m = $5

        if (m ~ /successfully authenticated over SSH/) {
            acct = ""; if (match(m, /account "[^"]*"/)) acct = substr(m, RSTART + 9, RLENGTH - 10)
            sub(/@.*$/, "", acct)                      # drop the @FE… endpoint suffix
            if (acct == "") acct = "(blank)"
            ip = ""; if (match(m, /Remote address: [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) ip = substr(m, RSTART + 16, RLENGTH - 16)
            if (ip == "") ip = "(none)"
            # the LOGIN the line names — the auth-logins.tsv sidecar (2026-08-31,
            # the multi-FE accounts): entity-coverage composes the In-side
            # logon proof per login there, since a logon by login A proves
            # nothing for login B flows on the same account
            lgn = ""; if (match(m, /login name "[^"]*"/)) lgn = substr(m, RSTART + 12, RLENGTH - 13)
            if (lgn != "") al9[acct SUBSEP lgn]++
            tot++
            ac[acct]++; ipc[ip]++
            aip[acct SUBSEP ip] = 1; ipa[ip SUBSEP acct] = 1
            addline("A" SUBSEP acct, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
            addline("I" SUBSEP ip,   $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
            if (d != "") {
                acd[acct SUBSEP d]++
                if (!(acct in afst) || d < afst[acct]) afst[acct] = d
                if (!(acct in alst) || d > alst[acct]) alst[acct] = d
                ipd[ip SUBSEP d]++
                if (!(ip in ifst) || d < ifst[ip]) ifst[ip] = d
                if (!(ip in ilst) || d > ilst[ip]) ilst[ip] = d
            }
            next
        }
    }
    END {
        for (k in aip) { split(k, a, SUBSEP); nip[a[1]]++ }
        for (k in ipa) { split(k, a, SUBSEP); nac[a[1]]++ }
        for (k in acd) { split(k, a, SUBSEP); abk[a[1]] = abk[a[1]] (abk[a[1]] ? "," : "") a[2] ":" acd[k] }
        for (k in ipd) { split(k, a, SUBSEP); ibk[a[1]] = ibk[a[1]] (ibk[a[1]] ? "," : "") a[2] ":" ipd[k] }
        naccts = 0; for (x in ac)  { naccts++; printf "AC\t%s%s\t%d\t%d\t%s\t%s\t%s\t%s\n", acctlink(x), x, ac[x], nip[x]+0, abk[x], afst[x], alst[x], lastlines("A" SUBSEP x) }
        nips = 0;   for (x in ipc) { nips++;   printf "IP\t%s\t%d\t%d\t%s\t%s\t%s\t%s\n", x, ipc[x], nac[x]+0, ibk[x], ifst[x], ilst[x], lastlines("I" SUBSEP x) }
        for (x in al9) { split(x, a9, SUBSEP); printf "AL\t%s\t%s\t%d\n", a9[1], a9[2], al9[x] }   # hash order — the shell sorts the sidecar
        printf "TOT\t%d\t%d\t%d\n", tot+0, naccts+0, nips+0
    }
' <(known_names KA "$TACCT"; base_names KA "$CONFIG_BASE/_accounts.tsv") "$PARSED")

# the per-(account, login) sidecar (see the AL comment above): account <TAB>
# login <TAB> successful logons. Sorted (never awk hash order), atomic.
AUTHL_OUT="$REPORTS_DIR/auth-logins.tsv"
printf '%s\n' "$agg" | { grep $'^AL\t' || true; } | cut -f2- | LC_ALL=C sort > "$AUTHL_OUT.tmp" && mv "$AUTHL_OUT.tmp" "$AUTHL_OUT"

IFS=$'\t' read -r _ tot naccts nips <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${tot:-0}" -eq 0 ]; then
    echo "No successful SSH authentication records found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

# The two row writers print STRAIGHT to stdout inside the page block below —
# a `rows+=$(printf …)` per row forks a subshell per row for nothing.
acct_rows() {
    while IFS=$'\t' read -r _ acct logins nip bk fst lst lines; do
        [ -z "$acct" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$acct" "$logins" "$nip" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^AC\t' | sort -t"$(printf '\t')" -k3,3nr)"
}

ip_rows() {
    while IFS=$'\t' read -r _ ip logins nac bk fst lst lines; do
        [ -z "$ip" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$ip" "$logins" "$nac" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^IP\t' | sort -t"$(printf '\t')" -k3,3nr)"
}


{
    printf 'TITLE\tAuthentication Activity\n'

    printf 'TABLE\tBy account\n'
    printf 'HEAD\tAccount\tLogins\tSource IPs\tFirst seen\tLast seen\n'
    printf 'KIND\tacct\tnum\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\n'
    acct_rows
    printf 'TOTAL\tTotal (%s account(s))\t@{class=num}%s\t\t\t\n' "$naccts" "$tot"

    printf 'TABLE\tBy source IP\n'
    printf 'HEAD\tSource IP\tLogins\tAccounts\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnum\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\n'
    ip_rows
    printf 'TOTAL\tTotal (%s IP(s))\t@{class=num}%s\t\t\t\n' "$nips" "$tot"


    printf 'FOOT\n'
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot auth(s), $naccts account(s), $nips IP(s))." >&2
