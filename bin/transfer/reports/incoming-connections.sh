#!/usr/bin/env bash
#
# incoming-connections.sh — one detail page per SIGHTED whitelisted IP:
# every data/flow-manager/base/_white.tsv entry whose result is green, red
# or blue (= the IP produced real transfers, or was sighted in the server
# log; the ~3k orange never-seen range entries get no page).
#
#   data/transfer/reports/details/incoming_connections/<slug>.rpt
#   data/transfer/reports/details/incoming_connections/_slugmap.tsv
#
# Rendered by bin/transfer/publish.sh (render_details) to
# docs/details/incoming_connections/. Page content: a Summary (result, the
# configured endpoint if the address maps to one, whitelisting accounts,
# traffic totals), the whitelisting accounts
# (acct KIND -> account detail pages), Activity per day, the Latest 10
# Files, and — for server-log-sighted IPs — the last 10 server log lines
# lifted from the unknown-whitelisting report's @data:loglines payload.
#
# ONE awk pass writes every page (the details.sh discipline — precompute
# everything, fork nothing per entity): the side inputs load into arrays
# via ARGV f= dispatch, $FILES is aggregated per IP off its host column in
# the same pass, and END prints each .rpt via print > outfile. No per-IP
# forks, no per-IP rescans of the traffic.
#
# Usage:
#   ./incoming-connections.sh    # reads the caches; no arguments
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

WHITE="$CONFIG_BASE/_white.tsv"
WACC="$CONFIG_XREF/_white-accounts.tsv"
UWRPT="$SERVER_REPORTS/unknown-whitelisting.rpt"
OUTDIR="$REPORTS_DIR/details/incoming_connections"
SLUGMAP="$OUTDIR/_slugmap.tsv"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
[ -f "$WHITE" ] || { echo "incoming-connections.sh: no $WHITE — nothing to do." >&2; exit 0; }
deps=("$WHITE")
[ -f "$WACC" ] && deps+=("$WACC")
[ -f "$UWRPT" ] && deps+=("$UWRPT")
skip_if_fresh "$SLUGMAP" "${BASH_SOURCE[0]}" "$FILES" "${deps[@]}"
echo "Building the incoming-connection (whitelisted IP) detail pages..." >&2

mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.rpt "$SLUGMAP"

stamp=$(date '+%Y-%m-%d %H:%M:%S')

# the side inputs ride in ARGV behind f= markers; the optional ones only
# when present (a missing cache degrades to an empty join, as before)
args=()
[ -f "$IP_HOSTS_FILE" ] && args+=( f=rev "$IP_HOSTS_FILE" )
args+=( f=white "$WHITE" )
[ -f "$WACC" ] && args+=( f=wacc "$WACC" )
[ -f "$UWRPT" ] && args+=( f=uw "$UWRPT" )
args+=( f=files "$FILES" )

# The slugmap is the freshness key (skip_if_fresh above), so the awk writes it
# incrementally to a .tmp; the finalize below publishes it LAST, after every
# page .rpt exists — a killed run leaves no slugmap and forces a rebuild
# instead of a fresh-looking partial one.
npages=$(LC_ALL=C awk -F'\t' \
    -v outdir="$OUTDIR" -v slugmap="$SLUGMAP.tmp" \
    -v stamp="$stamp" -v nfiles="${#files[@]}" '
    function hb(b) { if (b >= 1073741824) return sprintf("%.1f GB", b/1073741824)
                     if (b >= 1048576)    return sprintf("%.1f MB", b/1048576)
                     if (b >= 1024)       return sprintf("%.1f KB", b/1024)
                     return b " B" }

    # the address -> endpoint map: ip -> host (bin/ip.sh)
    f == "rev" { if ($1 != "" && $2 != "") ptrmap[$1] = tolower($2); next }

    # the sighted IPs (green/red/blue), in _white.tsv order
    f == "white" { if ($1 != "" && ($3 == "green" || $3 == "red" || $3 == "blue")) { ips[++nip] = $1; res[$1] = $3 }; next }

    # the whitelisting accounts per IP (deduped here, name-sorted in END;
    # the "" concat forces string compares, matching LC_ALL=C sort -u)
    f == "wacc" { if (($1 in res) && $2 != "" && !(($1, $2) in aseen)) { aseen[$1, $2] = 1; acc[$1, ++na[$1]] = $2 "" }; next }

    # the first @data:loglines payload per IP (unknown-whitelisting ROWs)
    f == "uw" {
        if ($1 == "ROW" && ($2 in res) && !($2 in logset))
            for (i = 3; i <= NF; i++)
                if (index($i, "@data:loglines=") == 1) { logset[$2] = 1; loglines[$2] = substr($i, 16); break }
        next
    }

    # the traffic: aggregate every $FILES row whose host (col 15) is sighted
    f == "files" {
        ip = $15; if (!(ip in res)) next
        n[ip]++; d = $4
        if (!((ip, d) in day)) { day[ip, d] = 1; ds[ip, ++nd[ip]] = d }
        df[ip, d]++
        if ($2 != "Failed" && $2 != "Expired") { ok[ip]++; dp[ip, d]++ } else { ko[ip]++; dfd[ip, d]++ }
        sz = $8 + 0; vol[ip] += sz; dv[ip, d] += sz
        if (fd[ip] == "" || d < fd[ip]) fd[ip] = d
        if (ld[ip] == "" || d > ld[ip]) ld[ip] = d
        # bounded latest-10 by sortkey (col 6), newest first
        line = $4 "\t" $5 "\t" $3 "\t" $12 "\t" $11 "\t" hb(sz) "\t" $2
        k = $6
        if (nt[ip] < 10 || k > tk[ip, 10]) {
            if (nt[ip] < 10) nt[ip]++
            for (i = nt[ip]; i > 1 && tk[ip, i-1] < k; i--) { tk[ip, i] = tk[ip, i-1]; tl[ip, i] = tl[ip, i-1] }
            tk[ip, i] = k; tl[ip, i] = line
        }
    }

    END {
        for (x = 1; x <= nip; x++) {
            ip = ips[x]; r = res[ip]
            slug = ip; gsub(/\./, "-", slug)
            print ip "\t" slug > slugmap
            out = outdir "/" slug ".rpt"

            # the configured endpoint this address maps to, if any (there is no
            # reverse DNS: an address the config does not name shows none)
            ptr = (ip in ptrmap) ? ptrmap[ip] : ""
            if (ptr == ip) ptr = ""

            if (r == "green")    rlabel = "OK — last transfer processed"
            else if (r == "red") rlabel = "Error — last transfer failed"
            else                 rlabel = "Server log only — never a transfer"

            nacc = (ip in na) ? na[ip] : 0
            nn = (ip in n) ? n[ip] : 0

            printf "TITLE\t%s\n", ip > out
            printf "META\tdirclass\tres-%s\n", r > out
            printf "TABLE\tSummary\tnosearch\n" > out
            printf "HEAD\tMetric\tValue\n" > out
            printf "KIND\ttext\ttext\n" > out
            printf "ROW\tIP address\t%s\n", ip > out
            if (ptr != "") printf "ROW\tConfigured endpoint\t%s\n", ptr > out
            printf "ROW\tResult\t%s\n", rlabel > out
            printf "ROW\tWhitelisted by\t%d account(s)\n", nacc > out
            if (nn) {
                printf "ROW\tFiles\t%d (%d OK, %d Error)\n", nn, ok[ip]+0, ko[ip]+0 > out
                printf "ROW\tVolume\t%s\n", hb(vol[ip]) > out
                printf "ROW\tFirst seen\t%s\n", fd[ip] > out
                printf "ROW\tLast seen\t%s\n", ld[ip] > out
            }
            printf "TOTAL\tTotal (%d rows)\t\n", 4 + (ptr != "" ? 1 : 0) + (nn ? 4 : 0) - 1 > out
            if (nn) {
                # per-day table, date ascending (insertion sort — few days)
                for (i = 1; i <= nd[ip]; i++) sd[i] = ds[ip, i]
                for (i = 2; i <= nd[ip]; i++) { v = sd[i]; for (j = i - 1; j >= 1 && sd[j] > v; j--) sd[j+1] = sd[j]; sd[j+1] = v }
                printf "TABLE\tActivity per day\n" > out
                printf "HEAD\tDate\tFiles\tError\tOK\tVolume\n" > out
                printf "KIND\ttext\tnum\tnumfailed\tnumprocessed\ttext\n" > out
                for (i = 1; i <= nd[ip]; i++) { d = sd[i]
                    printf "ROW\t%s\t%d\t%s\t%s\t%s\n", d, df[ip, d], (((ip, d) in dfd) ? dfd[ip, d] : ""), (((ip, d) in dp) ? dp[ip, d] : ""), hb(dv[ip, d] + 0) > out }
                printf "TOTAL\tTotal (%d days)\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t%s\n", nd[ip], nn, ko[ip]+0, ok[ip]+0, hb(vol[ip]) > out
                printf "TABLE\tLatest %d Files\n", nt[ip] > out
                printf "HEAD\tDate\tTime\tAccount\tSubscription\tFile\tSize\tOutcome\n" > out
                printf "KIND\ttext\ttext\tacct\tsite\tfile\ttext\ttext\n" > out
                for (i = 1; i <= nt[ip]; i++) {
                    split(tl[ip, i], a, "\t")
                    oc = a[7]
                    if (oc != "Failed" && oc != "Expired") oc = "@{class=processed}OK"; else oc = "@{class=failed}Error"
                    printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", a[1], a[2], a[3], a[4], a[5], a[6], oc > out
                }
                printf "TOTAL\tTotal (%d shown)\t\t\t\t\t\t\n", nt[ip] > out
            }
            if (nacc) {
                # the whitelisting accounts (name-sorted, byte order)
                for (i = 1; i <= nacc; i++) sa[i] = acc[ip, i]
                for (i = 2; i <= nacc; i++) { v = sa[i]; for (j = i - 1; j >= 1 && sa[j] > v; j--) sa[j+1] = sa[j]; sa[j+1] = v }
                printf "TABLE\tWhitelisted by\tnosearch\n" > out
                printf "HEAD\tAccount\n" > out
                printf "KIND\tacct\n" > out
                for (i = 1; i <= nacc; i++) printf "ROW\t%s\n", sa[i] > out
                printf "TOTAL\tTotal (%d account(s))\n", nacc > out
            }
            if ((ip in logset) && loglines[ip] != "") {
                # the last-10 server log lines (\x1f-separated payload)
                printf "TABLE\tLast 10 server log lines\twide\n" > out
                printf "HEAD\tServer log line\n" > out
                printf "KIND\tmono\n" > out
                m = split(loglines[ip], ll, "\037"); cnt = 0
                for (i = 1; i <= m; i++) {
                    rec = ll[i]
                    if (rec !~ /[^ \t\n]/) continue        # blank record (the old per-record NF gate)
                    gsub(/\t/, " ", rec)
                    printf "ROW\t%s\n", rec > out
                    cnt++
                }
                printf "TOTAL\tTotal (%d line(s))\n", cnt > out
            }
            printf "FOOT\tGenerated on %s from %s file(s)\n", stamp, nfiles > out
            close(out)
            np++
        }
        print np + 0
    }
' "${args[@]}")

# zero sighted IPs (e.g. base results not yet colored) -> no slugmap was
# written; leave an empty one rather than letting sort(1) fail the build
[ -f "$SLUGMAP.tmp" ] || : > "$SLUGMAP.tmp"
LC_ALL=C sort -o "$SLUGMAP.tmp" "$SLUGMAP.tmp"
mv "$SLUGMAP.tmp" "$SLUGMAP"
echo "Data written to $OUTDIR ($npages incoming-connection page(s))." >&2
