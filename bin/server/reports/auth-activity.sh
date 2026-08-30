#!/usr/bin/env bash
#
# auth-activity.sh — successful inbound authentications: the complement to
# failed-logins. Every "[Ssh Default] User with login name \"…\", associated
# with account \"…\", successfully authenticated over SSH … Remote address: …"
# line records who connected, from where. Per account and per source IP — a
# baseline of who is actually logging in that the transfer logs don't give
# (they start at the transfer, after auth). A third table surfaces SHARED
# CERTIFICATES: one certificate serial authenticating many accounts.
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
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
# LINK_AWK — slug() matches bin/publish_lib.sh's slugify (the same function as
# entity-search.sh's SLUG_AWK); acctlink() returns the @{link=…} cell prefix
# for a known account (exact, also @endpoint-stripped), or "" when unresolved.
LINK_AWK='
    function slug(x){ x=tolower(x); gsub(/[^a-z0-9]+/,"-",x); sub(/^-+/,"",x); sub(/-+$/,"",x); return x }
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

# One pass. SSH successful-auth lines feed the account and source-IP tables;
# certificate-attempt lines feed the shared-certificate table. Emits:
#   AC <TAB> account <TAB> logins <TAB> nIPs <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   IP <TAB> ip <TAB> logins <TAB> nAccts <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   CT <TAB> serial <TAB> attempts <TAB> nAccts <TAB> buckets <TAB> first <TAB> last <TAB> loglines
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

        if (m ~ /Authentication attempt with certificate with serial number/) {
            ser = ""; if (match(m, /serial number [0-9A-Fa-f]+/)) ser = substr(m, RSTART + 14, RLENGTH - 14)
            if (ser == "") next
            na = 0; lst2 = ""
            if (match(m, /assigned to \[[^]]*\]/)) { lst2 = substr(m, RSTART + 13, RLENGTH - 14); na = gsub(/@/, "@", lst2) }
            # ONE serial can cover MANY distinct certificates (self-signed
            # default "01"): the certificate IDENTITY here is serial + its
            # assigned-account list, keyed "ser#seq" (seq in encounter order —
            # the cache order is fixed, so this is deterministic)
            if (!((ser "#" lst2) in cidof)) cidof[ser "#" lst2] = ser "#" (++cseq[ser])
            ck = cidof[ser "#" lst2]
            cc[ck]++; if (na > cn[ck]) cn[ck] = na
            addline("C" SUBSEP ck, $1 " " $2, lvlname($3) " " compname($4) "  " substr(m, 1, 200))
            if (d != "") {
                ccd[ck SUBSEP d]++
                if (!(ck in cfst) || d < cfst[ck]) cfst[ck] = d
                if (!(ck in clst) || d > clst[ck]) clst[ck] = d
            }
        }
    }
    END {
        for (k in aip) { split(k, a, SUBSEP); nip[a[1]]++ }
        for (k in ipa) { split(k, a, SUBSEP); nac[a[1]]++ }
        for (k in acd) { split(k, a, SUBSEP); abk[a[1]] = abk[a[1]] (abk[a[1]] ? "," : "") a[2] ":" acd[k] }
        for (k in ipd) { split(k, a, SUBSEP); ibk[a[1]] = ibk[a[1]] (ibk[a[1]] ? "," : "") a[2] ":" ipd[k] }
        for (k in ccd) { split(k, a, SUBSEP); cbk[a[1]] = cbk[a[1]] (cbk[a[1]] ? "," : "") a[2] ":" ccd[k] }
        naccts = 0; for (x in ac)  { naccts++; printf "AC\t%s%s\t%d\t%d\t%s\t%s\t%s\t%s\n", acctlink(x), x, ac[x], nip[x]+0, abk[x], afst[x], alst[x], lastlines("A" SUBSEP x) }
        nips = 0;   for (x in ipc) { nips++;   printf "IP\t%s\t%d\t%d\t%s\t%s\t%s\t%s\n", x, ipc[x], nac[x]+0, ibk[x], ifst[x], ilst[x], lastlines("I" SUBSEP x) }
        for (x in cc) printf "CT\t%s\t%d\t%d\t%s\t%s\t%s\t%s\n", x, cc[x], cn[x]+0, cbk[x], cfst[x], clst[x], lastlines("C" SUBSEP x)
        printf "TOT\t%d\t%d\t%d\n", tot+0, naccts+0, nips+0
    }
' <(known_names KA "$TACCT") "$PARSED")

IFS=$'\t' read -r _ tot naccts nips <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${tot:-0}" -eq 0 ]; then
    echo "No successful SSH authentication records found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi
n_cert=$(printf '%s\n' "$agg" | grep -c $'^CT\t' || true)
# max accounts on ONE certificate = field 4 (field 3 is the attempt count)
max_shared=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="CT" && $4>m{m=$4} END{print m+0}')
# serials appearing on MORE than one distinct certificate (for the display suffix)
multi_ser=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="CT"{split($2,p,"#"); c[p[1]]++} END{for(k in c) if(c[k]>1) printf " %s ", k}')

# The three row writers print STRAIGHT to stdout inside the page block below —
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

cert_rows() {
    while IFS=$'\t' read -r _ ser attempts nac bk fst lst lines; do
        [ -z "$ser" ] && continue
        # display: the serial, disambiguated when several DISTINCT certificates
        # share it ("01 (cert 2)")
        disp=${ser%%#*}; seq=${ser##*#}
        case $multi_ser in *" $disp "*) disp="$disp (cert $seq)" ;; esac
        ncell="$nac"; [ "$nac" -gt 1 ] 2>/dev/null && ncell="@{class=warn}$nac"
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$disp" "$attempts" "$ncell" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^CT\t' | sort -t"$(printf '\t')" -k3,3nr -k2,2)"
}

{
    printf 'TITLE\tAuthentication Activity\n'
    printf 'DESC\tSuccessful inbound SSH authentications per account and source IP, plus shared-certificate detection — the complement to Failed Logins.\n'
    printf 'INTRO\t**%s** successful SSH authentication(s) from **%s** account(s) across **%s** source IP(s). This is the baseline of who is actually connecting (Failed Logins shows only what did not get in). The certificate table flags **shared certificates** — one certificate authorizes up to **%s** accounts, so a single key compromise would expose all of them (rows are per distinct certificate; the self-signed default serial 01 covers several).\n' \
        "$tot" "$naccts" "$nips" "$max_shared"

    printf 'TABLE\tBy account\n'
    printf 'HEAD\tAccount\tLogins\tSource IPs\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnum\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\n'
    acct_rows
    printf 'TOTAL\tTotal (%s account(s))\t@{class=num}%s\t\t\t\n' "$naccts" "$tot"

    printf 'TABLE\tBy source IP\n'
    printf 'HEAD\tSource IP\tLogins\tAccounts\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnum\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\n'
    ip_rows
    printf 'TOTAL\tTotal (%s IP(s))\t@{class=num}%s\t\t\t\n' "$nips" "$tot"

    printf 'TABLE\tCertificates (shared-key detection)\n'
    printf 'HEAD\tCertificate serial\tAuth attempts\tAccounts on certificate\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnum\tnum\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\t-\n'
    cert_rows
    printf 'TOTAL\tTotal (%s certificate(s))\t\t\t\t\n' "$n_cert"

    printf 'NOTE\tSource: SSHD "successfully authenticated over SSH" lines (successful logins only; the @endpoint suffix is stripped from the account name, and an account known from the transfer logs links to its detail page). Logins are additive and re-total under the date filter; Source IPs and Accounts are distinct counts (kept at full-range). The certificate table counts "Authentication attempt with certificate" lines; "Accounts on certificate" is how many accounts that serial is authorized for — more than one (amber) means a shared key. Click a row to expand its 10 most recent authentications.\n'
    printf 'SUMMARY\tSuccessful auths: %s  |  Accounts: %s  |  Source IPs: %s  |  Max accounts on one cert: %s\n' "$tot" "$naccts" "$nips" "$max_shared"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($tot auth(s), $naccts account(s), $nips IP(s))." >&2
