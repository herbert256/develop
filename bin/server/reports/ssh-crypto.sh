#!/usr/bin/env bash
#
# ssh-crypto.sh — the cryptography actually negotiated on every successful
# authentication, plus the connection parameters the server flagged as
# insecure/deprecated. A security-posture inventory that the transfer logs
# cannot give: what cipher / key exchange / MAC / public-key algorithms are in
# live use, and where weak ones remain.
#
# Two message families in the TM component carry the negotiated parameters
# ("Connection security parameters: …"), in three shapes:
#   A (SSH/PeSIT/HTTPS auth): "… cipher suite: X; Key exchange: Y; HMAC: Z; Public Key: W."
#   B (FTPS/PeSIT initiated): "… cipher: X, MAC: Z, Key Exchange: Y, Public Key: W."
#   C (certificate auth):     "… client certificate provided: Cipher: X, MAC: Z,
#                              Key Exchange: Y, Public Key: W." (capital Cipher
#                              after an infix — 53,807 lines, ALL ssh-rsa, were
#                              silently dropped before shape C was handled)
# and one warning family flags a deprecated parameter with the account,
# subscription (transfer site) and remote host that used it:
#   "Insecure or deprecated SSH connection parameter used: [Cipher: aes128-cbc]
#    by Account \"…\" , Transfer site: \"…\", connecting to remote host: …"
#
# Weak = known-deprecated per category: CBC/3DES/RC4/arcfour ciphers,
# SHA-1 based key exchange / MAC, and ssh-rsa / ssh-dss host keys (SHA-1
# signatures). Names in the deprecated-warning table are shown as logged.
#
# The page also carries the protocol & credential HYGIENE signals (formerly the
# standalone Protocol Hygiene report, folded in here 2026-07): the
# connection-level problems that aren't crypto-algorithm posture and aren't a
# specific transfer failure. Five signals classified from the TM messages:
#   ASCII fallback        "ASCII transfers are not supported … Binary transfer mode will be used."
#   FTPS est. failed      "Trying to establish an FTPS connection with protocols […] failed."
#   CONFIG_PASSWD read    "[…] Error reading CONFIG_PASSWD state variable"
#   Certificate chain     "Error in certificate chain for Subject DN:CN=<subject>"
#   Disconnect error      "Error during disconnect operation: …"
# plus a table breaking the certificate-chain errors down by their CN subject
# (the PUBKEY_/PRIVKEY_ key names), which is the actionable part. An env with
# negotiations but no hygiene signals simply omits the two hygiene tables.
#
# Usage:
#   ./ssh-crypto.sh    # reads input/*.csv (via the cache), writes data/ssh-crypto.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/ssh-crypto.rpt"

# Entity cross-links for the deprecated-parameter table: known account /
# subscription / remote-host names from the transfer-side reports (ROW field 2
# of each report's FIRST table). A resolved name gets an @{link=…} prefix on
# its cell (rendered by bin/publish_lib.sh render_cell as a link to its detail
# page); unresolved names stay plain text. Linking is skipped for a list whose
# transfer report is absent.
TDATA="$TRANSFER_REPORTS"
TACCT="$TDATA/account.rpt"
TSITE="$TDATA/subscription.rpt"
THOST="$TDATA/remote-host.rpt"
known_names() {   # $1 marker  $2 transfer .rpt — emits "marker<TAB>name" lines
    [ -f "$2" ] || return 0
    awk -F'\t' -v M="$1" '$1=="TABLE"{t++; if(t>1)exit} t==1&&$1=="ROW"{print M "\t" $2}' "$2"
}
# LINK_AWK — slug() matches bin/publish_lib.sh's slugify (the same function as
# entity-search.sh's SLUG_AWK). sitelink(): exact match or unique prefix of one
# known subscription (the server truncates long names; same rule as
# site-failures.sh); acctlink(): exact match, also @endpoint-stripped;
# hostlink(): exact match.
LINK_AWK='
    function slug(x){ x=tolower(x); gsub(/[^a-z0-9]+/,"-",x); sub(/^-+/,"",x); sub(/-+$/,"",x); return x }
    # RENAMES (2026-08): a server line keeps the name that was current when it
    # was written, so fold it to the CURRENT one before matching the roster —
    # which carries current names, the transfer parse having folded them — and
    # DISPLAY the folded name, so the page names the flow as the configuration
    # does. rn_canon_pfx also covers the truncated old spelling the server
    # writes, folding only when every completion agrees.
    function sitecanon(t,   k, hits, full, c) {
        c = rn_canon_pfx(t)
        if (c in ksite) return c
        hits = 0
        for (k in ksite) if (index(k, c) == 1) { hits++; full = k; if (hits > 1) { hits = 0; break } }
        return hits == 1 ? full : c
    }
    function sitelink(t,   k, hits, full) {
        t = sitecanon(t)
        if (t in ksite) return "@{alink=subscriptions/" t "}"
        hits = 0
        for (k in ksite) if (index(k, t) == 1) { hits++; full = k; if (hits > 1) return "" }
        return hits == 1 ? "@{alink=subscriptions/" full "}" : ""
    }
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
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$TACCT" "$TSITE" "$THOST"
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# One pass. For each negotiated-parameters line: classify protocol, pull the
# cipher / key exchange / MAC / public-key values (both shapes), count each per
# category and per day. For each deprecated-parameter warning: pull the flagged
# parameter, account, subscription and host. For each hygiene signal: classify
# the category (and the CN subject on a cert-chain error). Every Share is
# computed HERE, in the pass that holds the totals. Emits TAB-separated records:
#   CT <TAB> category <TAB> negotiations <TAB> weak (the per-category totals)
#   P <TAB> proto <TAB> count <TAB> share <TAB> buckets
#   H|K|M|U <TAB> algo <TAB> count <TAB> share <TAB> weak(0/1) <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   D <TAB> count <TAB> parameter <TAB> account <TAB> subscription <TAB> host <TAB> buckets <TAB> first <TAB> last <TAB> loglines
#   S <TAB> catkey <TAB> count <TAB> level <TAB> buckets <TAB> first <TAB> last <TAB> loglines   (hygiene signals)
#   C <TAB> subject <TAB> count <TAB> buckets <TAB> first <TAB> last <TAB> loglines              (cert-chain subjects)
#   HT <TAB> total <TAB> ncats <TAB> nsubjects                                                   (hygiene totals)
#   AN <TAB> signal <TAB> count <TAB> first <TAB> last <TAB> buckets <TAB> loglines               (algorithm-negotiation failures)
#   ANT <TAB> incidents <TAB> nrows <TAB> nsoftware <TAB> top software <TAB> its count <TAB> first <TAB> last
#   PT <TAB> suite <TAB> version <TAB> count <TAB> first <TAB> last <TAB> weeks(clines) <TAB> buckets <TAB> loglines  (PeSIT TLS)
#   PTT <TAB> total <TAB> ncombos <TAB> first TLS date
#   TOT <TAB> negotiations <TAB> deprecated
agg=$(awk -F'\t' -v RNF="$RENAMES_FILE" "$LOGLINES_AWK$RENAMES_AWK$LINK_AWK"'
    BEGIN { rn_load(RNF) }
    # Julian-day helpers (same as bin/day) for the PeSIT-TLS per-week fold —
    # weeks bucket on their MONDAY date, computed from the JDN, never `date`
    function jdn(y,m2,dd,  a){ a=int((14-m2)/12); y=y+4800-a; m2=m2+12*a-3; return dd+int((153*m2+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    function fromjdn(j,  a,b,c,dd,e,mm,day,mon,yr){ a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e=c-int(1461*dd/4); mm=int((5*e+2)/153); day=e-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d",yr,mon,day) }
    function bump(cat, lv,   d) {
        cat_cnt[cat]++; cat_lv[cat]=lv; htot++
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        if (d != "") {
            cat_d[cat SUBSEP d]++
            if (!((cat SUBSEP d) in cds)) { cds[cat SUBSEP d]=1; cdl[cat] = cdl[cat] (cdl[cat]?",":"") d }
            if (!(cat in cf) || d < cf[cat]) cf[cat]=d
            if (!(cat in cl) || d > cl[cat]) cl[cat]=d
        }
        addline("S" SUBSEP cat, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
    }
    function weak(cat, a,   s) {
        s = tolower(a)
        if (cat == "H") return (s ~ /cbc|3des|arcfour|rc4|blowfish|-des-|_des_|des-cbc|null|tls_rsa_/) ? 1 : 0
        if (cat == "K") return (s ~ /sha1|group1-|-group1$|nistp1/)                                   ? 1 : 0
        if (cat == "M") return (s ~ /md5|sha1|-96/)                                                    ? 1 : 0
        if (cat == "U") return (s ~ /^ssh-rsa$|^ssh-dss$|^ssh-dsa$|^x509v3-sign-rsa$/)                 ? 1 : 0
        return 0
    }
    function acc(cat, algo, d,   k) {
        sub(/[. ]+$/, "", algo)          # TLS suites log a trailing "." (cipher-only lines); drop it
        if (algo == "") return
        k = cat SUBSEP algo
        cnt[k]++
        addline(k, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
        if (d != "") {
            cd[k SUBSEP d]++
            if (!(k in fst) || d < fst[k]) fst[k] = d
            if (!(k in lst) || d > lst[k]) lst[k] = d
        }
    }
    $1 == "KA" { kacct[$2] = 1; next }                       # known-entity lists (first input)
    $1 == "KS" { ksite[$2] = 1; next }
    $1 == "KH" { khost[$2] = 1; next }
    {
        d = substr($1, 1, 10); if (d !~ /^[0-9][0-9][0-9][0-9]-/) d = ""
        m = $5

        if (m ~ /Connection security parameters: (cipher|client certificate provided: Cipher:)/) {
            if (m ~ /\[Ssh Default\]/)        proto = "SSH"
            else if (m ~ /\[Pesit Default\]/) proto = "PeSIT"
            else if (m ~ /\[Http Default\]/)  proto = "HTTPS"
            else if (match(m, /connection over [A-Za-z]+/)) {
                proto = substr(m, RSTART + 16, RLENGTH - 16)
                if (proto == "PESIT") proto = "PeSIT"; else if (proto == "FTP") proto = "FTPS"
            } else proto = "(other)"

            cph = ""
            if (match(m, /cipher suite: [^;,]+/))      cph = substr(m, RSTART + 14, RLENGTH - 14)
            else if (match(m, /cipher: [^;,]+/))       cph = substr(m, RSTART + 8,  RLENGTH - 8)
            else if (match(m, /Cipher: [^;,]+/))       cph = substr(m, RSTART + 8,  RLENGTH - 8)   # shape C (cert auth)
            kex = ""
            if (match(m, /[Kk]ey [Ee]xchange: [^;,]+/)) { kex = substr(m, RSTART, RLENGTH); sub(/^[Kk]ey [Ee]xchange: /, "", kex) }
            mac = ""
            if (match(m, /HMAC: [^;,]+/))              mac = substr(m, RSTART + 6, RLENGTH - 6)
            else if (match(m, /MAC: [^;,]+/))          mac = substr(m, RSTART + 5, RLENGTH - 5)
            pk = ""
            if (match(m, /Public Key: [^;,]+/))        { pk = substr(m, RSTART + 12, RLENGTH - 12); sub(/\.+$/, "", pk) }

            neg++
            pc[proto]++; if (d != "") pcd[proto SUBSEP d]++
            acc("H", cph, d); acc("K", kex, d); acc("M", mac, d); acc("U", pk, d)
            next
        }

        if (m ~ /Insecure or deprecated SSH connection parameter/) {
            param = ""; if (match(m, /\[[A-Za-z ]+: [^]]+\]/)) { param = substr(m, RSTART + 1, RLENGTH - 2) }
            if (param == "") next
            acct = "(unknown)"; if (match(m, /Account "[^"]*"/)) acct = substr(m, RSTART + 9, RLENGTH - 10)
            site = "(unknown)"; if (match(m, /Transfer site: "[^"]*"/)) site = substr(m, RSTART + 16, RLENGTH - 17)
            sub(/_(SS?|C)CP_.*$/, "", site)                                            # canonical subscription name (drop the _SCP_ / _SSCP_ / _CCP_ tail)
            host = "(unknown)"; if (match(m, /remote host: .+$/)) host = substr(m, RSTART + 13)
            if (acct == "") acct = "(blank)"
            dk = param SUBSEP acct SUBSEP site SUBSEP host
            dc[dk]++; dep++
            addline("D" SUBSEP dk, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
            if (d != "") {
                dcd[dk SUBSEP d]++
                if (!(dk in dfst) || d < dfst[dk]) dfst[dk] = d
                if (!(dk in dlst) || d > dlst[dk]) dlst[dk] = d
            }
            next
        }

        # ALGORITHM NEGOTIATION FAILURES (E, TM) — a three-line family per
        # incident: the header line, one line per un-negotiable direction
        # (MAC_CS/MAC_SC ... from remote algorithms ...) and the remote
        # software banner. The lines carry no join key, so each distinct
        # shape is its own row; the header line counts the incidents.
        if ($3 == "E" && (m ~ /^The following algorithms could not be negotiated/ || m ~ /^[A-Z_]+ could not be negotiated from remote algorithms / || m ~ /^The remote host identified itself as /)) {
            if (m ~ /^The following algorithms could not be negotiated/) {
                ninc++
                if (d != "") { if (anfi == "" || d < anfi) anfi = d; if (d > anla) anla = d }
                next
            }
            lbl = substr(m, 1, 160); sub(/[. ]+$/, "", lbl)
            anc[lbl]++
            if (m ~ /^The remote host identified itself as /) {
                sw = m; sub(/^The remote host identified itself as /, "", sw); sub(/[. ]*$/, "", sw)
                if (!(sw in sws)) { sws[sw] = 1; nsw++ }
                swc[sw]++
            }
            if (d != "") { andd[lbl SUBSEP d]++
                if (anf[lbl] == "" || d < anf[lbl]) anf[lbl] = d
                if (d > anl[lbl]) anl[lbl] = d }
            addline("AN" SUBSEP lbl, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
            next
        }

        # PeSIT TLS ADOPTION (I, PESITD) — "Establishing PeSIT SSL connection
        # with host <ip>, using cipher suite: <suite> and TLS/SSL protocol:
        # <ver>." (usually "[Pesit Default] "-prefixed). The dated milestone
        # that the ST<->CFT link went encrypted.
        if ($3 == "I" && $4 == "P" && m ~ /Establishing PeSIT SSL connection with host /) {
            su = ""; if (match(m, /cipher suite: [^ ,]+/)) su = substr(m, RSTART + 14, RLENGTH - 14)
            ver = ""; if (match(m, /protocol: [^ ]+/)) { ver = substr(m, RSTART + 10, RLENGTH - 10); sub(/\.+$/, "", ver) }
            if (su == "") su = "(unlogged)"
            if (ver == "") ver = "(unlogged)"
            pk2 = su SUBSEP ver
            ptc[pk2]++; ptT++
            if (d != "") { ptdd[pk2 SUBSEP d]++
                if (ptf[pk2] == "" || d < ptf[pk2]) ptf[pk2] = d
                if (d > ptl[pk2]) ptl[pk2] = d
                if (ptg == "" || d < ptg) ptg = d
                split(d, dp2, "-"); j2 = jdn(dp2[1]+0, dp2[2]+0, dp2[3]+0)
                j2 = j2 - ((j2 + 1) % 7 + 6) % 7          # this week Monday
                ptw[pk2 SUBSEP j2]++
                if (wmin == 0 || j2 < wmin) wmin = j2
                if (j2 > wmax) wmax = j2
            }
            addline("PT" SUBSEP pk2, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
            next
        }

        # the hygiene signals (disjoint message families from the two above)
        if      (m ~ /ASCII transfers are not supported/)              bump("ASCII", $3)
        else if (m ~ /Trying to establish an FTPS connection.*failed/) bump("FTPS", $3)
        else if (m ~ /Error reading CONFIG_PASSWD/)                    bump("CONFIG_PASSWD", $3)
        else if (m ~ /Error during disconnect operation/)              bump("DISCONNECT", $3)
        else if (m ~ /Error in certificate chain/) {
            bump("CERTCHAIN", $3)
            subj = "(none)"; if (match(m, /CN=[^,]*/)) subj = substr(m, RSTART+3, RLENGTH-3)
            sub_cnt[subj]++
            if (d != "") {
                sub_d[subj SUBSEP d]++
                if (!((subj SUBSEP d) in sds)) { sds[subj SUBSEP d]=1; sdl[subj] = sdl[subj] (sdl[subj]?",":"") d }
                if (!(subj in sf) || d < sf[subj]) sf[subj]=d
                if (!(subj in sl) || d > sl[subj]) sl[subj]=d
            }
            addline("C" SUBSEP subj, $1 " " $2, lvlname($3) " " compname($4) "  " substr($5, 1, 200))
        }
    }
    END {
        for (x in cd)  { n = split(x, a, SUBSEP); kk = a[1] SUBSEP a[2]; bk[kk] = bk[kk] (bk[kk] ? "," : "") a[3] ":" cd[x] }
        for (x in pcd) { split(x, a, SUBSEP); pbk[a[1]] = pbk[a[1]] (pbk[a[1]] ? "," : "") a[2] ":" pcd[x] }
        for (x in dcd) { split(x, a, SUBSEP); kk = a[1] SUBSEP a[2] SUBSEP a[3] SUBSEP a[4]; dbk[kk] = dbk[kk] (dbk[kk] ? "," : "") a[5] ":" dcd[x] }

        # per-category totals FIRST: the Share column and each table total need
        # them, and having them here saves an awk fork per row and per table
        for (k in cnt) { split(k, a, SUBSEP); wkc[k] = weak(a[1], a[2])
            ctot[a[1]] += cnt[k]; if (wkc[k]) cwk[a[1]] += cnt[k] }
        for (c in ctot) printf "CT\t%s\t%d\t%d\n", c, ctot[c], cwk[c]+0
        for (p in pc)  printf "P\t%s\t%d\t%.1f\t%s\n", p, pc[p], (neg ? pc[p]*100/neg : 0), pbk[p]
        for (k in cnt) { split(k, a, SUBSEP)
            printf "%s\t%s\t%d\t%.1f\t%d\t%s\t%s\t%s\t%s\n", a[1], a[2], cnt[k], (ctot[a[1]] ? cnt[k]*100/ctot[a[1]] : 0), wkc[k], bk[k], fst[k], lst[k], lastlines(k) }
        for (k in dc)  { split(k, a, SUBSEP)
            printf "D\t%d\t%s\t%s%s\t%s%s\t%s%s\t%s\t%s\t%s\t%s\n", dc[k], a[1], acctlink(a[2]), a[2], sitelink(a[3]), sitecanon(a[3]), hostlink(a[4]), a[4], dbk[k], dfst[k], dlst[k], lastlines("D" SUBSEP k) }
        ncats = 0
        for (c in cat_cnt) { ncats++
            no = split(cdl[c], dz, ","); hbk = ""
            for (i = 1; i <= no; i++) { dd = dz[i]; hbk = hbk (hbk ? "," : "") dd ":" cat_d[c SUBSEP dd] }
            printf "S\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n", c, cat_cnt[c], cat_lv[c], hbk, cf[c], cl[c], lastlines("S" SUBSEP c)
        }
        nsub = 0
        for (s in sub_cnt) { nsub++
            no = split(sdl[s], dz, ","); hbk = ""
            for (i = 1; i <= no; i++) { dd = dz[i]; hbk = hbk (hbk ? "," : "") dd ":" sub_d[s SUBSEP dd] }
            printf "C\t%s\t%d\t%s\t%s\t%s\t%s\n", s, sub_cnt[s], hbk, sf[s], sl[s], lastlines("C" SUBSEP s)
        }
        printf "HT\t%d\t%d\t%d\n", htot+0, ncats+0, nsub+0
        # ---- algorithm negotiation failures ----
        for (x in andd) { split(x, a, SUBSEP); anbk[a[1]] = anbk[a[1]] (anbk[a[1]] ? "," : "") a[2] ":" andd[x] }
        nan = 0
        for (k in anc) { nan++
            printf "AN\t%s\t%d\t%s\t%s\t%s\t%s\n", k, anc[k], anf[k], anl[k], anbk[k], lastlines("AN" SUBSEP k) }
        tsw = ""; tswn = -1                              # top remote software; ties break on the name
        for (k in swc) if (swc[k] > tswn || (swc[k] == tswn && k < tsw)) { tswn = swc[k]; tsw = k }
        printf "ANT\t%d\t%d\t%d\t%s\t%d\t%s\t%s\n", ninc+0, nan+0, nsw+0, tsw, (tswn < 0 ? 0 : tswn), anfi, anla
        # ---- PeSIT TLS adoption ----
        for (x in ptdd) { split(x, a, SUBSEP); kk = a[1] SUBSEP a[2]; ptbk[kk] = ptbk[kk] (ptbk[kk] ? "," : "") a[3] ":" ptdd[x] }
        npt = 0
        for (k in ptc) { npt++; split(k, a, SUBSEP)
            wl = ""                                     # weeks walked in calendar order, never hash order
            if (wmin) for (j2 = wmin; j2 <= wmax; j2 += 7)
                if ((k SUBSEP j2) in ptw) wl = wl (wl ? _US : "") "wk " fromjdn(j2) ": " ptw[k SUBSEP j2]
            printf "PT\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n", a[1], a[2], ptc[k], ptf[k], ptl[k], wl, ptbk[k], lastlines("PT" SUBSEP k) }
        printf "PTT\t%d\t%d\t%s\n", ptT+0, npt+0, ptg
        printf "TOT\t%d\t%d\n", neg+0, dep+0
    }
' <(known_names KA "$TACCT"; known_names KS "$TSITE"; known_names KH "$THOST") "$PARSED")

IFS=$'\t' read -r _ neg dep <<< "$(printf '%s\n' "$agg" | grep $'^TOT\t')"
if [ "${neg:-0}" -eq 0 ]; then
    echo "No negotiated-parameter (crypto) records found." >&2
    rm -f "$OUT"   # no data for this ENV — page not published (an env-split legitimate state)
    exit 0
fi

# The per-category totals and weak sums, read ONCE from the agg's CT records
# into flat variables (bash 3.2 has no associative arrays) — they used to be an
# awk fork per lookup, eleven in all.
tot_H=0; tot_K=0; tot_M=0; tot_U=0; wk_H=0; wk_K=0; wk_M=0; wk_U=0
while IFS=$'\t' read -r _ c t w; do
    case $c in
        H) tot_H=$t; wk_H=$w ;;
        K) tot_K=$t; wk_K=$w ;;
        M) tot_M=$t; wk_M=$w ;;
        U) tot_U=$t; wk_U=$w ;;
    esac
done <<< "$(printf '%s\n' "$agg" | grep $'^CT\t')"
cat_stats() {   # $1 = type letter -> cat_tot / cat_wk
    case $1 in
        H) cat_tot=$tot_H; cat_wk=$wk_H ;;
        K) cat_tot=$tot_K; cat_wk=$wk_K ;;
        M) cat_tot=$tot_M; cat_wk=$wk_M ;;
        U) cat_tot=$tot_U; cat_wk=$wk_U ;;
        *) cat_tot=0; cat_wk=0 ;;
    esac
}

# Build the ROWs for one algorithm category (H/K/M/U): sorted by count desc,
# share of that category's total (computed in the agg awk), and a Weak/OK
# assessment cell. Every row writer here prints STRAIGHT to stdout — a
# `rows+=$(printf …)` per row forks a subshell per row for nothing.
algo_rows() {   # $1 = type letter
    local t=$1 _t algo count share wk bk fst lst lines assess
    while IFS=$'\t' read -r _t algo count share wk bk fst lst lines; do
        [ -z "$algo" ] && continue
        if [ "$wk" = "1" ]; then assess='@{class=failed}Weak'; else assess='OK'; fi
        printf 'ROW\t%s\t%s\t%s%%\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$algo" "$count" "$share" "$assess" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep "^$t"$'\t' | sort -t"$(printf '\t')" -k3,3nr)"
}

emit_algo_table() {   # $1=type  $2=heading  $3=col-1 header  $4=noun
    local t=$1 head=$2 col1=$3 noun=$4
    cat_stats "$t"
    printf 'TABLE\t%s\n' "$head"
    printf 'HEAD\t%s\tNegotiations\tShare\tAssessment\tFirst\tLast\n' "$col1"
    printf 'KIND\tmono\tnum\tnum\ttext\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t%%0\t-\t-\t-\n'
    algo_rows "$t"
    printf 'TOTAL\tTotal (%s weak)\t@{class=num}%s\t@{class=num}100.0%%\t\t\t\n' "$cat_wk" "$cat_tot"
}

# Protocol overview table.
proto_rows() {
    while IFS=$'\t' read -r _ proto count share bk; do
        [ -z "$proto" ] && continue
        printf 'ROW\t%s\t%s\t%s%%\t@data:buckets=%s\n' "$proto" "$count" "$share" "$bk"
    done <<< "$(printf '%s\n' "$agg" | grep $'^P\t' | sort -t"$(printf '\t')" -k3,3nr)"
}
n_proto=$(printf '%s\n' "$agg" | grep -c $'^P\t' || true)

# Deprecated-parameter warnings table.
dep_rows() {
    while IFS=$'\t' read -r _ count param acct site host bk fst lst lines; do
        [ -z "$param" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$param" "$acct" "$site" "$host" "$count" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^D\t' | sort -t"$(printf '\t')" -k2,2nr)"
}
n_dep_rows=$(printf '%s\n' "$agg" | grep -c $'^D\t' || true)

# The hygiene tables (folded in from the retired Protocol Hygiene report).
# Both row writers print STRAIGHT to stdout; the category label / level cell
# come from inline case statements — as $(…) helpers they cost four subshells
# per row.
IFS=$'\t' read -r _ tot_sig n_cats n_subj <<< "$(printf '%s\n' "$agg" | grep $'^HT\t')"
cert_tot=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="C"{s+=$3} END{print s+0}')

sig_rows() {
    while IFS=$'\t' read -r _ cat count lvl bk fst lst lines; do
        [ -z "$cat" ] && continue
        case $cat in
            ASCII)         label="ASCII transfer fallback (binary used)" ;;
            FTPS)          label="FTPS connection establishment failed" ;;
            CONFIG_PASSWD) label="CONFIG_PASSWD read error" ;;
            CERTCHAIN)     label="Certificate chain error" ;;
            DISCONNECT)    label="Disconnect error" ;;
            *)             label="$cat" ;;
        esac
        case $lvl in
            E) lcell='@{class=failed}Error' ;;
            W) lcell='@{class=warn}Warning' ;;
            *) lcell='Info' ;;
        esac
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' \
            "$label" "$count" "$lcell" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^S\t' | sort -t"$(printf '\t')" -k3,3nr)"
}

subj_rows() {
    while IFS=$'\t' read -r _ subj count bk fst lst lines; do
        [ -z "$subj" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' \
            "$subj" "$count" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^C\t' | sort -t"$(printf '\t')" -k3,3nr)"
}

weak_ciph=$wk_H; weak_pk=$wk_U
itemized=$tot_K   # SSH/SFTP connections that break out KEX/MAC/pubkey (TLS logs a suite only)

# ---- the two 2026-08 tables: algorithm-negotiation failures + PeSIT TLS ----
# Emitted UNCONDITIONALLY (placeholder row when the family is absent) so the
# merged ssh-security report keeps a constant TABLE count across the envs.
IFS=$'\t' read -r _ an_inc an_rows_n an_nsw an_topsw an_topswn an_first an_last <<< "$(printf '%s\n' "$agg" | grep $'^ANT\t' || printf 'ANT\t0\t0\t0\t\t0\t\t\n')"
IFS=$'\t' read -r _ pt_tot pt_combos pt_first <<< "$(printf '%s\n' "$agg" | grep $'^PTT\t' || printf 'PTT\t0\t0\t\n')"
an_lines_tot=$(printf '%s\n' "$agg" | awk -F'\t' '$1=="AN"{s+=$3} END{print s+0}')

an_rows() {
    while IFS=$'\t' read -r _ lbl count fst lst bk lines; do
        [ -z "$lbl" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$lbl" "$count" "$fst" "$lst" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^AN\t' | sort -t"$(printf '\t')" -k3,3nr -k2,2)"
}

pt_rows() {
    while IFS=$'\t' read -r _ suite ver count fst lst weeks bk lines; do
        [ -z "$suite" ] && continue
        printf 'ROW\t%s\t%s\t%s\t%s\t%s\t%s\t@data:buckets=%s\t@data:loglines=%s\n' "$suite" "$ver" "$count" "$fst" "$lst" "$weeks" "$bk" "$lines"
    done <<< "$(printf '%s\n' "$agg" | grep $'^PT\t' | sort -t"$(printf '\t')" -k4,4nr -k2,2 -k3,3)"
}

{
    printf 'TITLE\tSSH & TLS Crypto\n'
    printf 'DESC\tNegotiated cipher / key exchange / MAC / public-key algorithms in live use, with weak ones flagged, plus deprecated-parameter warnings and the protocol/credential hygiene signals (ASCII fallback, FTPS establishment failures, CONFIG_PASSWD read errors, certificate-chain and disconnect errors).\n'
    printf 'INTRO\t**%s** authenticated connections logged their negotiated cryptography. Weak algorithms still in use: **%s** connection(s) on a CBC/legacy cipher and **%s** on an `ssh-rsa`/`ssh-dss` (SHA-1) host key. The server separately flagged **%s** connection(s) using a deprecated parameter, and **%s** protocol/credential **hygiene** signal(s) — connection-level problems distinct from algorithm posture — are collected in the two tables at the bottom. "Weak" marks known-deprecated algorithms (CBC/3DES/RC4 ciphers, SHA-1 key exchange or MAC, ssh-rsa/ssh-dss keys). This posture is invisible in the transfer logs.\n' \
        "$neg" "$weak_ciph" "$weak_pk" "$dep" "${tot_sig:-0}"
    printf 'KEYWORDS\tprotocol hygiene, ASCII fallback, FTPS, CONFIG_PASSWD, certificate chain, disconnect, algorithm negotiation, PeSIT TLS, encryption milestone\n'

    printf 'TABLE\tNegotiations by protocol\n'
    printf 'HEAD\tProtocol\tNegotiations\tShare\n'
    printf 'KIND\ttext\tnum\tnum\n'
    printf 'RECALC\t-\ts0\t%%0\n'
    proto_rows; printf '\n'   # the blank line this table has always carried
    printf 'TOTAL\tTotal (%s protocol(s))\t@{class=num}%s\t@{class=num}100.0%%\n' "$n_proto" "$neg"

    emit_algo_table H "Cipher suites"          "Cipher suite"      cipher
    emit_algo_table K "Key exchange"           "Key exchange"      kex
    emit_algo_table M "MAC algorithms"         "MAC"              mac
    emit_algo_table U "Public-key algorithms"  "Public key"       pubkey

    printf 'TABLE\tDeprecated-parameter warnings\twide\n'
    printf 'HEAD\tParameter\tAccount\tSubscription\tRemote host\tWarnings\tFirst\tLast\n'
    printf 'KIND\tmono\tmono\tmono\tmono\tnumwarn\ttext\ttext\n'
    printf 'RECALC\t-\t-\t-\t-\ts0\t-\t-\n'
    dep_rows; printf '\n'     # idem
    printf 'TOTAL\t@{colspan=4}Total (%s combination(s))\t@{class=num warn}%s\t\t\n' "$n_dep_rows" "$dep"

    printf 'NOTE\tAn SSH/SFTP connection breaks out cipher, key exchange, MAC and public key separately; a TLS connection (HTTPS and PeSIT/FTPS over TLS) logs only a cipher suite — key exchange, MAC and signature are folded into the suite. So the Cipher suites table counts all **%s** negotiations, while Key exchange / MAC / Public-key count only the **%s** SSH/SFTP connection(s) that itemize them. Share is within each table. "Weak" flags known-deprecated algorithms; `ssh-rsa` is flagged because it signs with SHA-1. The deprecated-parameter table is the server'"'"'s own warnings, with the account, subscription and remote host that used the parameter (shown as logged; names matching a known transfer-log entity link to its detail page). All tables re-total under the date filter; click a row to expand its 10 most recent log lines.\n' "$neg" "$itemized"

    if [ "${tot_sig:-0}" -gt 0 ]; then
        printf 'TABLE\tHygiene signals\twide\n'
        printf 'HEAD\tSignal\tOccurrences\tLevel\tFirst\tLast\n'
        printf 'KIND\ttext\tnum\ttext\ttext\ttext\n'
        printf 'RECALC\t-\ts0\t-\t-\t-\n'
        sig_rows
        printf 'TOTAL\tTotal (%s signal(s))\t@{class=num}%s\t\t\t\n' "$n_cats" "$tot_sig"
        printf 'NOTE\tConnection- and credential-level problems distinct from cipher/algorithm posture: a failed FTPS handshake, an unreadable stored password, a broken certificate chain or an abrupt disconnect each points at a specific config or trust issue. Each signal is classified from a distinct TM message. Occurrences are additive and re-total under the date filter. The "Insecure or deprecated SSH parameter" warnings are not here — they are in the Deprecated-parameter warnings table above, resolved to account/subscription/host.\n'

        printf 'TABLE\tCertificate chain errors by subject\n'
        printf 'HEAD\tSubject (CN)\tOccurrences\tFirst\tLast\n'
        printf 'KIND\tmono\tnum\ttext\ttext\n'
        printf 'RECALC\t-\ts0\t-\t-\n'
        subj_rows
        printf 'TOTAL\tTotal (%s subject(s))\t@{class=num}%s\t\t\n' "$n_subj" "$cert_tot"
        printf 'NOTE\tThe "Error in certificate chain for Subject DN:CN=…" errors broken down by the certificate subject (the PUBKEY_/PRIVKEY_ key name). Click a subject for its 10 most recent errors.\n'
    fi

    # ---- algorithm negotiation failures (2026-08) ----
    if [ "${an_lines_tot:-0}" -gt 0 ]; then
        printf 'TABLE\tAlgorithm negotiation failures\twide\n'
    else
        printf 'TABLE\tAlgorithm negotiation failures\tnofilter\tnosort\n'
    fi
    printf 'HEAD\tSignal\tLog lines\tFirst\tLast\n'
    printf 'KIND\tmono\tnumfailed\ttext\ttext\n'
    printf 'RECALC\t-\ts0\t-\t-\n'
    if [ "${an_lines_tot:-0}" -gt 0 ]; then
        an_rows
    else
        printf 'ROW\t@{colspan=4}No algorithm-negotiation failures in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s signal shape(s))\t@{class=num failed}%s\t\t\n' "${an_rows_n:-0}" "${an_lines_tot:-0}"
    if [ "${an_inc:-0}" -gt 0 ]; then
        printf 'NOTE\tOutbound SSH connections that failed BEFORE any authentication because no common algorithm exists: **%s** incident(s) between %s and %s (each logs a "could not be negotiated" header, one line per un-negotiable direction, and the remote software banner — the rows above). Every incident in this window identifies the peer as **%s** (**%s** banner line(s)%s) — the remote endpoint offers only algorithms this server does not accept, so the fix is a policy change on one of the two sides. These connections never reach the negotiated-crypto tables above. Click a row for its 10 most recent lines.\n' \
            "$an_inc" "${an_first:--}" "${an_last:--}" "${an_topsw:-?}" "${an_topswn:-0}" "$( [ "${an_nsw:-0}" -gt 1 ] && printf '; %s distinct software strings in all' "$an_nsw" )"
    else
        printf 'NOTE\tOutbound SSH connections that failed before any authentication because no common algorithm exists — none in this data window.\n'
    fi

    # ---- PeSIT TLS adoption (2026-08) ----
    if [ "${pt_tot:-0}" -gt 0 ]; then
        printf 'TABLE\tPeSIT TLS adoption\twide\n'
    else
        printf 'TABLE\tPeSIT TLS adoption\tnofilter\tnosort\n'
    fi
    printf 'HEAD\tCipher suite\tTLS version\tConnections\tFirst\tLast\tPer week\n'
    printf 'KIND\tmono\tmono\tnum\ttext\ttext\tclines\n'
    printf 'RECALC\t-\t-\ts0\t-\t-\t-\n'
    if [ "${pt_tot:-0}" -gt 0 ]; then
        pt_rows
    else
        printf 'ROW\t@{colspan=6}No PeSIT SSL/TLS connections in this data window.\n'
    fi
    printf 'TOTAL\tTotal (%s combination(s))\t\t@{class=num}%s\t\t\t\n' "${pt_combos:-0}" "${pt_tot:-0}"
    if [ "${pt_tot:-0}" -gt 0 ]; then
        printf 'NOTE\tThe "Establishing PeSIT SSL connection with host …, using cipher suite: …" lines from the PESITD component: the internal ST ↔ CFT PeSIT link running over TLS. The first such line is dated **%s** — the milestone that PeSIT went ENCRYPTED; before that date the link ran in the clear (no PeSIT SSL line appears). The Per-week column shows the adoption ramp, one line per calendar week (dated by its Monday). Click a row for its 10 most recent connections.\n' "${pt_first:--}"
    else
        printf 'NOTE\tThe PESITD "Establishing PeSIT SSL connection" lines — the internal ST ↔ CFT PeSIT link running over TLS. None in this data window: the link ran in the clear throughout.\n'
    fi

    printf 'SUMMARY\tNegotiations: %s  |  Weak ciphers: %s  |  ssh-rsa/ssh-dss keys: %s  |  Deprecated-parameter warnings: %s  |  Hygiene signals: %s  |  Negotiation failures: %s  |  PeSIT TLS connections: %s\n' "$neg" "$weak_ciph" "$weak_pk" "$dep" "${tot_sig:-0}" "${an_inc:-0}" "${pt_tot:-0}"
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($neg negotiation(s), $dep deprecated warning(s))." >&2
