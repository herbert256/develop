#!/usr/bin/env bash
#
# ssh-key-auth.sh — SSH key-authentication failures and account lockouts. Three
# security signals the generic Failed Logins report doesn't separate out:
#   Key mismatches  "[Ssh Default] Authentication failed because no certificate is
#                    found for user "<account@endpoint>" … that contains the
#                    submitted key." — the presented key matches no stored cert.
#   Lockouts        "[Ssh Default] User '<login>' locked due to too many failed
#                    login attempts." — the account was locked out.
#   Outbound        "Authentication failure connecting to remote host <host> as
#                    user <user>: Publickey authentication was cancelled/failed" —
#                    ST failing to authenticate TO a partner with a key.
#
# Repeat offenders (a login that mismatches or locks out again and again) are a
# brute-force / stale-key signal. Names/hosts are shown as logged (mono); a
# user matching a known transfer-log account (exact or @endpoint-stripped) or
# a host known from the transfer logs is linked to its detail page — the rest
# stay plain text. Reads the parse cache (data/_parse.tsv). Writes data/ssh-key-auth.rpt.
#
# Usage:
#   ./ssh-key-auth.sh    # reads input/*.csv (via the cache), writes data/ssh-key-auth.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/ssh-key-auth.rpt"

# Entity cross-links: known account / remote-host names from the transfer-side
# reports (ROW field 2 of each report's FIRST table). A user that matches a
# known account (exact, also @endpoint-stripped) or a host equal to a known
# host gets an @{link=…} prefix on its cell (rendered by bin/publish_lib.sh
# the renderer as a link to its detail page); unresolved names stay plain text.
# Linking is skipped for a list whose transfer report is absent.
TDATA="$TRANSFER_REPORTS"
TACCT="$TDATA/account.rpt"
THOST="$TDATA/remote-host.rpt"
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
# LINK_AWK — slug() matches bin/publish_lib.sh's slugify (the same function as
# entity-search.sh's SLUG_AWK); acctlink()/hostlink() return the @{link=…} cell
# prefix for a resolved name, or "" when it stays unresolved.
LINK_AWK='
    function slug(x){ x=tolower(x); gsub(/[^a-z0-9]+/,"-",x); sub(/^-+/,"",x); sub(/-+$/,"",x); return x }
    function acctlink(t,   s) {
        if (t in kacct) return "@{alink=accounts/" t "}"
        s = t; sub(/@.*$/, "", s)
        if (s in kacct) return "@{alink=accounts/" s "}"
        return ""
    }
    function hostlink(t) { return (t in khost) ? "@{alink=hosts/" t "}" : "" }
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
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TACCT" "$THOST"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass. A shared acc(ns, name, date) accumulates count + per-date buckets +
# first/last into namespace-prefixed globals; addline() feeds the drill.
#   K <TAB> user <TAB> count <TAB> buckets <TAB> first <TAB> last <TAB> loglines   (key mismatches)
#   L <TAB> user <TAB> count <TAB> buckets <TAB> first <TAB> last <TAB> loglines   (lockouts)
#   O <TAB> host <TAB> count <TAB> buckets <TAB> first <TAB> last <TAB> loglines   (outbound failures)
#   TOT <TAB> nkey <TAB> nlock <TAB> nout <TAB> nkeyusers <TAB> nlockusers <TAB> nouthosts
agg=$(awk -F'\t' "$LOGLINES_AWK$LINK_AWK"'
    function acc(ns, nm, d,   k, dk) { k = ns SUBSEP nm; cnt[k]++
        if (d != "") { dk = k SUBSEP d; dd[dk]++
            if (!(dk in dseen)) { dseen[dk]=1; dlist[k] = dlist[k] (dlist[k]?",":"") d }
            if (!(k in fst) || d < fst[k]) fst[k]=d
            if (!(k in lst) || d > lst[k]) lst[k]=d } }
    $1 == "KA" { kacct[$2] = 1; next }                       # known-entity lists (first input)
    $1 == "KH" { khost[$2] = 1; next }
    {
        m = $5
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        line = lvlname($3) " " compname($4) "  " substr(m, 1, 200)
        if (m ~ /no certificate is found for user/) {
            if (match(m, /user "[^"]*"/)) { u = substr(m, RSTART+6, RLENGTH-7); acc("K", u, d); addline("K" SUBSEP u, $1 " " $2, line); tk++ }
        } else if (m ~ /locked due to too many failed login/) {
            if (match(m, /User '\''[^'\'']*'\''/)) { u = substr(m, RSTART+6, RLENGTH-7); acc("L", u, d); addline("L" SUBSEP u, $1 " " $2, line); tl++ }
        } else if (m ~ /Publickey authentication (was cancelled|failed)/ && m ~ /remote host /) {
            h = "(unknown)"; if (match(m, /remote host [^ ]+/)) { h = substr(m, RSTART+12, RLENGTH-12); sub(/:[0-9]+$/, "", h) }
            acc("O", h, d); addline("O" SUBSEP h, $1 " " $2, line); to++
        }
    }
    END {
        nk=0; nl=0; no=0
        for (k in cnt) {
            split(k, a, SUBSEP); ns=a[1]; nm=a[2]
            m2 = split(dlist[k], dz, ","); bk=""
            for (i=1;i<=m2;i++){ dd2=dz[i]; bk=bk (bk?",":"") dd2 ":" dd[k SUBSEP dd2] }
            if (ns=="K") nk++; else if (ns=="L") nl++; else if (ns=="O") no++
            lp = (ns=="O") ? hostlink(nm) : acctlink(nm)     # K/L are users, O is a remote host
            printf "%s\t%s%s\t%d\t%s\t%s\t%s\t%s\n", ns, lp, nm, cnt[k], bk, fst[k], lst[k], lastlines(k)
        }
        printf "TOT\t%d\t%d\t%d\t%d\t%d\t%d\n", tk+0, tl+0, to+0, nk, nl, no
    }
' <(known_names KA "$TACCT"; known_names KH "$THOST") "$PARSED")

IFS=$'\t' read -r _ t_key t_lock t_out n_ku n_lu n_oh <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ $(( t_key + t_lock + t_out )) -eq 0 ]; then
    echo "No SSH key-auth / lockout messages found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

rows_for() {   # $1 = namespace (K|L|O)
    while IFS=$'\t' read -r _ name count bk fst lst lines; do
        [ -z "$name" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$name" "$count" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $"^$1"$'\t' | sort -t"$(printf '\t')" -k3,3nr)"
}

{
    printf 'TITLE\tSSH Key Auth & Lockouts\n'
    printf 'DESC\tSSH key-authentication failures and account lockouts — key mismatches (submitted key matches no stored certificate), locked accounts, and outbound key-auth failures. A sharper security view than generic failed logins.\n'
    printf 'INTRO\t**%s** key mismatch(es) across **%s** user(s), **%s** account lockout(s) across **%s** user(s), and **%s** outbound key-auth failure(s) across **%s** host(s). A user that mismatches or locks out repeatedly is a stale-key or brute-force signal. Names are shown as logged. Click a row for its 10 most recent messages.\n' \
        "$t_key" "$n_ku" "$t_lock" "$n_lu" "$t_out" "$n_oh"

    printf 'TABLE\tKey mismatches (no certificate for submitted key)\twide\n'
    printf 'HEAD\tUser\tAttempts\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnumfailed\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\n'
    printf '%s\n' "$(rows_for K)"   # %s\n: $(rows_for) stripped the trailing newline
    printf 'TOTAL\tTotal (%s user(s))\t@{class=num failed}%s\t\t\n' "$n_ku" "$t_key"
    printf 'NOTE\tInbound: the presented public key matched no certificate stored for that user "account@endpoint". Attempts are additive and re-total under the date filter. Click a user for its 10 most recent mismatch messages.\n'

    printf 'TABLE\tAccount lockouts\n'
    printf 'HEAD\tUser\tLockouts\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnumfailed\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\n'
    printf '%s\n' "$(rows_for L)"
    printf 'TOTAL\tTotal (%s user(s))\t@{class=num failed}%s\t\t\n' "$n_lu" "$t_lock"
    printf 'NOTE\t"User \x27<login>\x27 locked due to too many failed login attempts." — the account was locked out. A login that locks out repeatedly is worth investigating.\n'

    printf 'TABLE\tOutbound key-auth failures (ST -> partner)\twide\n'
    printf 'HEAD\tRemote host\tFailures\tFirst seen\tLast seen\n'
    printf 'KIND\tmono\tnumfailed\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\n'
    printf '%s\n' "$(rows_for O)"
    printf 'TOTAL\tTotal (%s host(s))\t@{class=num failed}%s\t\t\n' "$n_oh" "$t_out"
    printf 'NOTE\tSecureTransport failing to authenticate TO a partner with a public key ("Publickey authentication was cancelled/failed"), per remote host (a host known from the transfer logs links to its detail page).\n'

    printf 'SUMMARY\tKey mismatches: %s (%s users)  |  Lockouts: %s (%s users)  |  Outbound key-auth failures: %s (%s hosts)\n' \
        "$t_key" "$n_ku" "$t_lock" "$n_lu" "$t_out" "$n_oh"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($t_key key-mismatch, $t_lock lockout(s), $t_out outbound)." >&2
