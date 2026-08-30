#!/usr/bin/env bash
#
# seen-in-server-log.sh — "Seen in server log": the audit page of the BLUE
# build step (bin/build/seen-in-server-log.sh). It opens with the two analyses result-status
# rollups (Flow manager Entities, Partners/Domains/Applications) annotated with
# the change each figure owes to the blue marking (+n / -n), then lists one row
# per server-log-only tuple — WHAT was added (the entity attributions the xref
# enrichment produced, each cell linked to its detail page) with the seed's
# latest server-log message as a click-to-expand drill. No date filter.
#
# Sources — no log parsing of its own:
#   data/seen-in-server-log.tsv                 the injected rows (_files.tsv layout;
#                                       col 11 file = "BLUE: <seed type>")
#   data/unknown/{accounts,logins,sites,hosts}.tsv
#                                       the seed lists: name <TAB> latest
#                                       TM-mention date time <TAB> session_id
#                                       <TAB> message
#   data/flow-manager/base/_*.tsv       the result column (with fakes) for the
#                                       WITH side of the status tables
#   data/transfer/cache/_files.tsv +    result.sh's algorithm re-run fake-free
#     data/flow-manager/xref/_*-subscriptions.tsv   for the WITHOUT side
# The seed is joined back by its type's entity column; a subscription seed
# whose token was CANONICALIZED (truncated server spelling -> the configured
# name it uniquely prefixes) is re-matched by that same prefix rule, so the
# "Server log name" column shows the spelling the server actually logged.
#
# Usage:
#   ./seen-in-server-log.sh    # reads data/seen-in-server-log.tsv + data/unknown/*.tsv
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TRANSFER lib, not the analyses one: these are transfer-DATA reports (they
# read the transfer caches and write into data/<env>/transfer/reports/, and
# bin/transfer/publish.sh renders their pages) — they live HERE because their
# pages sit in the ANALYSES menu. The lib resolves every path from its own
# location, so sourcing it across areas is safe by design.
source "$SCRIPT_DIR/../../transfer/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/seen-in-server-log.rpt"

UNK="$UNKNOWN_DIR"   # from lib.sh (env-scoped)
# the per-entity blue evidence lines (type, name, stamp, message) — the claim
# evidence for blues no TM tuple reaches (the Step-F0 SSH-logon discoveries)
BLUE_EVID="$DATA/blue/_evidence.tsv"

shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
sidecar_deps=()
for sc in accounts logins sites hosts white; do
    [ -f "$UNK/$sc.tsv" ] && sidecar_deps+=("$UNK/$sc.tsv")
done
# the status tables read the base caches (bin/build/result.sh — status rollup), the
# classic coverage TSVs (showseen — Seen counts) and the analyses pda.rpt (PDA
# Seen); a rerun of any of them must refresh this page too.
extra_deps=()
for bf in _subscriptions _accounts _hosts _logins _partners _domains _apps; do
    [ -f "$CONFIG_BASE/$bf.tsv" ] && extra_deps+=("$CONFIG_BASE/$bf.tsv")
done
for cv in subscriptions accounts hosts logins; do
    [ -f "$REPORTS_DIR/coverage/$cv.tsv" ] && extra_deps+=("$REPORTS_DIR/coverage/$cv.tsv")
done
[ -f "$ANALYSES_REPORTS/home.rpt" ] && extra_deps+=("$ANALYSES_REPORTS/home.rpt")
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$BLUE_TSV" "$BLUE_EVID" \
    ${sidecar_deps[@]+"${sidecar_deps[@]}"} ${extra_deps[@]+"${extra_deps[@]}"}
[ -f "$BLUE_EVID" ] || BLUE_EVID=/dev/null   # first build: the blue step not run yet
echo "Building the seen-in-server-log audit report..." >&2

# One pass: load the four sidecars (keyed by type + name), then walk the fake
# rows (already deterministically ordered by bin/build/seen-in-server-log.sh) and join each
# back to its seed. Emitted per input row — no hash-order iteration.
rows=""
if [ -f "$BLUE_TSV" ]; then
rows=$(awk -F'\t' -v OFS='\t' '
    FILENAME ~ /accounts\.tsv$/ { ty = "account" }
    FILENAME ~ /logins\.tsv$/   { ty = "login" }
    FILENAME ~ /sites\.tsv$/    { ty = "subscription" }
    FILENAME ~ /hosts\.tsv$/    { ty = "host" }
    FILENAME ~ /white\.tsv$/    { ty = "whitelisted IP" }
    FILENAME ~ /(accounts|logins|sites|hosts|white)\.tsv$/ {
        if ($1 == "") next
        k = ty SUBSEP toupper($1)
        msg[k] = $3   # the sidecars are name / date time / message (no Session ID since 2026-07)
        if (ty == "subscription") { ns++; stok[ns] = $1 }   # tokens, for the prefix re-match
        next
    }
    {   # data/seen-in-server-log.tsv: 1 coreid 2 outcome 3 account 4 date 5 time
        # 6 sortkey 7 jdn 8 size 9 dur 10 rows 11 file 12 site 13 profile
        # 14 login 15 host (16-19 PDA)
        t = substr($11, 7)                       # "BLUE: <type>" -> the seed type
        if      (t == "account")      seed = $3
        else if (t == "login")        seed = $14
        else if (t == "host")         seed = $15
        else if (t == "subscription") seed = $12
        else if (t == "whitelisted IP") seed = $15
        else next
        k = t SUBSEP toupper(seed)
        if (!(k in msg) && t == "subscription") {
            # canonicalized site: find the unique sidecar token prefixing the
            # configured name the fake row carries (its message key)
            hits = 0
            for (i = 1; i <= ns; i++) if (index(seed, stok[i]) == 1) { hits++; cand = stok[i] }
            if (hits == 1) k = t SUBSEP toupper(cand)
        }
        print t, $3, $14, $12, $15, $13, $4, $5, ((k in msg) ? msg[k] : "")
    }
' ${sidecar_deps[@]+"${sidecar_deps[@]}"} "$BLUE_TSV" | LC_ALL=C sort)
else
    echo "No $BLUE_TSV (bin/build/seen-in-server-log.sh has not run) — writing an empty report." >&2
fi

n=0; n_acct=0; n_login=0; n_site=0; n_host=0; n_white=0
if [ -n "$rows" ]; then
    # all six counts from ONE awk (was a grep + five forks over the same rows)
    read -r n n_acct n_login n_site n_host n_white <<<"$(printf '%s\n' "$rows" | awk -F'\t' '
        $0 != "" {n++}
        $1=="account"{a++} $1=="login"{l++} $1=="subscription"{s++} $1=="host"{h++} $1=="whitelisted IP"{w++}
        END{printf "%d %d %d %d %d %d",n+0,a+0,l+0,s+0,h+0,w+0}')"
fi

# ---- message shapes (the "what happened" top view + per-shape grouping) ------
# Normalize each seed server-log message into a shape — quoted values, IPs,
# UUIDs and numbers removed, plus a few message-specific tails collapsed so
# like events cluster (the same idea as the server top-messages report). Every
# fake row is TAGGED with its shape (field 10) and shape INDEX (field 11), so
# the "Injected fake transfers" section can show ONE table per shape, linked
# from the "What happened" overview.
rows_shaped=""; rows_indexed=""; shapes_ranked=""; n_shapes=0
if [ -n "$rows" ]; then
    rows_shaped=$(printf '%s\n' "$rows" | awk -F'\t' -v OFS='\t' '
        function shape(m) {
            if (m == "") return "(no server-log message)"
            gsub(/"[^"]*"/, "\"…\"", m)                            # double-quoted values
            gsub(/\047[^\047]*\047/, "\047…\047", m)               # single-quoted values
            gsub(/UC[0-9]+[_A-Za-z0-9-]*/, "<site>", m)            # UC subscription / site tokens (unquoted)
            gsub(/remote host:? [^ ,]+/, "remote host <host>", m)  # the endpoint hostname[:port]
            gsub(/ as user [^ :,]+/, " as user <user>", m)         # the remote-side login
            # collapse the varying reason tail of the SSH AUTH-FAILURE line so its
            # three variants (publickey / password / password+keyboard) are ONE
            # shape — scoped to this exact prefix so the "Connection failure while
            # …" lines (genuinely different reasons) stay distinct
            if (m ~ /^Authentication failure connecting to remote host <host> as user <user>:/)
                m = "Authentication failure connecting to remote host <host> as user <user>: …"
            gsub(/defined in account [^ .,]+/, "defined in account <account>", m)
            sub(/No such file.*/, "No such file …", m)             # collapse the varying path tail of the listing error
            sub(/Connection security parameters:.*/, "Connection security parameters: …", m)   # collapse the cipher/KEX/MAC tail
            gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, "IP", m)        # IPs
            gsub(/[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-[0-9a-f-]*[0-9a-f]/, "UUID", m)
            gsub(/[0-9]+/, "N", m)                                 # any remaining numbers
            return substr(m, 1, 220)
        }
        NF { print $0, shape($9) }
    ')
    # distinct shapes ranked most-frequent-first (then text) with a 1-based index
    shapes_ranked=$(printf '%s\n' "$rows_shaped" | awk -F'\t' 'NF{c[$NF]++} END{for(k in c) printf "%d\t%s\n", c[k], k}' \
        | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2 | awk -F'\t' '{printf "%d\t%d\t%s\n", NR, $1, $2}')
    n_shapes=$(printf '%s\n' "$shapes_ranked" | grep -c . || true)
    # append the shape INDEX to each fake row (field 11), joined by the shape
    # string — the per-shape tables then filter on that number (no awk -v of a
    # message string, which could carry backslashes)
    rows_indexed=$(awk -F'\t' 'FNR==NR{ix[$3]=$1;next}{print $0 "\t" ix[$NF]}' \
        <(printf '%s\n' "$shapes_ranked") <(printf '%s\n' "$rows_shaped"))
fi

# ---- status delta tables ----------------------------------------------------
# The two analyses result-status rollups (Flow manager Entities, Partners /
# Domains / Applications) with the change each figure owes to these fake
# transfers. WITH-fakes counts are the LIVE base caches (bin/build/result.sh runs
# after the fake step, so they already include the fakes); WITHOUT-fakes counts
# re-run result.sh's EXACT algorithm on a fake-free _files.tsv — stage 1 the
# subscriptions (last-transfer outcome per dest site, green/red/orange), stage 2
# every other entity rolled up via its _<item>-subscriptions.tsv pair cache
# (all green -> green, any red -> red, else orange). So the delta is precisely
# the fake action's effect. Validated: the same algorithm run WITH the fakes
# reproduces every committed base-cache count.
BASE_DIR="$CONFIG_BASE"
XREF_DIR="$CONFIG_XREF"
subres_wo="$REPORTS_DIR/.fake-subres.$$"
fseen="$REPORTS_DIR/.fseen.$$"
: > "$subres_wo"
# CLAIMS is defined further down (the seenlog cell-page pass); ${…:-} keeps
# the trap safe before then under set -u
trap 'rm -f "$subres_wo" "$fseen" "${CLAIMS:-}"' EXIT

# ONE pass over the 117k-row _files.tsv (the bin/build/seen-in-server-log.sh
# $tmp.fseen pattern) — the former per-consumer re-scans (subres_wo, the five
# seen_cell calls, the whitelist recount: seven full reads) read THIS small
# extract instead:
#   V<col>  the distinct UPPER-CASED values per entity column (3 account,
#           12 site, 14 login, 15 host) — seen_cell's membership test
#   O12     the last-transfer outcome per site — subres_wo's stage 1
#   O15     the last-transfer outcome per RAW host value — the whitelist
#           recount joins on the spelling _white.tsv carries, no case fold
# The O lines are printed on every UPDATE (never from an END for-in loop, so
# no hash-iteration order leaks); the LAST line per key is the winner and the
# readers overwrite sequentially.
awk -F'\t' '
    { if ($3  != "" && !s3[toupper($3)]++)   print "V3\t"  toupper($3)
      if ($12 != "" && !s12[toupper($12)]++) print "V12\t" toupper($12)
      if ($14 != "" && !s14[toupper($14)]++) print "V14\t" toupper($14)
      if ($15 != "" && !s15[toupper($15)]++) print "V15\t" toupper($15)
      s = toupper($12)
      if (s   != "" && $6 != "" && $6 >= sk[s])    { sk[s]    = $6; print "O12\t" s "\t" $2 }
      if ($15 != "" && $6 != "" && $6 >= sk2[$15]) { sk2[$15] = $6; print "O15\t" $15 "\t" $2 } }
' "$FILES" > "$fseen"

if [ -f "$BASE_DIR/_subscriptions.tsv" ]; then
    awk -F'\t' '
        FILENAME == ARGV[1] { if ($1 == "O12") oc[$2] = $3; next }             # the _files extract: last outcome per site
        { k=toupper($1); r="orange"; if (k in oc) r=(oc[k]=="Failed"||oc[k]=="Expired")?"red":"green"; print k "\t" r }
    ' "$fseen" "$BASE_DIR/_subscriptions.tsv" > "$subres_wo"
fi

dcell() {   # $1 with-fakes count  $2 without-fakes count -> "N" or "N (+D)" / "N (-D)"
    local d=$(( $1 - $2 ))
    if   [ "$d" -gt 0 ]; then printf '%d (+%d)' "$1" "$d"
    elif [ "$d" -lt 0 ]; then printf '%d (%d)' "$1" "$d"
    else printf '%d' "$1"; fi
}

COVDIR="$REPORTS_DIR/coverage"   # showseen's per-member coverage TSVs (name<TAB>dir<TAB>seen…)

# The Seen cell = configured entities with at least one transfer, the same
# figure the analyses Status column shows.
#   CLASSIC entities (a direct _files column, seencol set): the seen-with count
#   is showseen's coverage TSV (distinct names, = the analyses s1 — showseen
#   runs in the prior phase, so it is fresh WITH the blue marks), and the (+n)
#   delta is that minus the same count over the real _files.tsv, i.e. the
#   configured names seen ONLY through the server log.
#   PDA members (no direct column): the seen-with count is the analyses seen
#   total (home.rpt's SEEN line — the both-ways-MERGED organisation count, blue
#   members included — showseen marks a blue base entity seen). Its (+n) delta
#   re-runs the SAME pda_split_figures merge over the member's coverage TSV
#   (pda_seen_delta), clearing a row's seen flag when its name is marked BLUE
#   in the member's base cache — the organisations seen ONLY because of the
#   server-log marking (a blue entity has no real transfer by definition). The
#   merge folds a both-linked Out endpoint onto its already-seen In partner,
#   so a member's delta can sit below its raw blue count. home.rpt is an
#   ANALYSES output (bin/analyses/reports/home.sh), so this report runs AFTER
#   it in bin/analyses/reports.sh — otherwise a from-scratch build has no
#   home.rpt and PDA Seen shows 0.
HOMERPT="$ANALYSES_REPORTS/home.rpt"

# pda_seen_delta COVNAME PTYPE BASEFILE... -> the (with - blue-free) merged
# seen delta for a PDA member. PTYPE 1 = partners (an Out row links to an In
# partner via coverage col 8); PTYPE 0 = domains/applications (a name in both
# directions folds to Both). Mirrors pda_split_figures exactly, then re-runs
# it with each row's seen flag cleared iff its name is blue in ANY of the
# given base caches — partners pass _partners AND _hosts, because the
# coverage's Out rows are named by ENDPOINT spelling and take their seen flag
# from the hosts coverage, where a blue host counts as seen.
pda_seen_delta() {
    local cov=$1 ptype=$2; shift 2
    [ -f "$COVDIR/$cov.tsv" ] || { printf 0; return; }
    local b bfs=()
    for b in "$@"; do [ -f "$BASE_DIR/$b.tsv" ] && bfs+=("$BASE_DIR/$b.tsv"); done
    awk -F'\t' -v ptype="$ptype" -v cov="$COVDIR/$cov.tsv" '
        FILENAME != cov { if($3=="blue") blue[toupper($1)]=1; next }
        { R[++nr]=$1 "\t" $2 "\t" $3 "\t" $8 }
        END{ print merge(0)-merge(1) }
        function merge(free,  i,a,name,dir,c3,inl,idx,dr,sn,n,s,il,j,sf){
            delete idx; delete dr; delete sn; n=0; s=0;
            for(i=1;i<=nr;i++){
                split(R[i],a,"\t"); name=toupper(a[1]); dir=a[2]; c3=(a[3]==1); inl=a[4]; sf=c3;
                if(free && c3 && (name in blue)) sf=0;
                if(ptype){
                    if(dir=="I"){ idx[name]=++n; dr[n]="I"; sn[n]=sf }
                    else { il=toupper(inl);
                        if(inl!="" && (il in idx)){ j=idx[il]; dr[j]="B"; if(sf)sn[j]=1 }
                        else { ++n; dr[n]="O"; sn[n]=sf } }
                } else {
                    if(name in idx){ j=idx[name]; if(dr[j]!=dir)dr[j]="B"; if(sf)sn[j]=1 }
                    else { idx[name]=++n; dr[n]=dir; sn[n]=sf }
                }
            }
            for(i=1;i<=n;i++) if(sn[i]) s++;
            return s;
        }
    ' ${bfs[@]+"${bfs[@]}"} "$COVDIR/$cov.tsv"
}

seen_cell() {   # $1 base file  $2 coverage/member name  $3 _files seen column ("" = PDA)
    if [ -n "$3" ]; then
        local sw=0 fw swo
        [ -f "$COVDIR/$2.tsv" ] && sw=$(awk -F'\t' '$3==1{s[toupper($1)]=1} END{n=0;for(k in s)n++;print n}' "$COVDIR/$2.tsv")
        read -r fw swo <<<"$(awk -F'\t' -v col="$3" '
            FILENAME==ARGV[1]{cfg[toupper($1)]=1;next}
            $1 == ("V" col) && ($2 in cfg) {n++}   # the _files extract: already distinct + UPPER-CASED
            END{printf "%d %d",n+0,n+0}' "$BASE_DIR/$1.tsv" "$fseen")"
        # coverage missing (no showseen TSV for this member — e.g. Whitelist,
        # or a fresh clone): fall back to the _files count PLUS the blue rows
        # (Seen = transfer-seen OR server-log-seen, like the coverage path)
        [ -f "$COVDIR/$2.tsv" ] || sw=$(( fw + $(awk -F'\t' '$3=="blue"{n++} END{print n+0}' "$BASE_DIR/$1.tsv") ))
        dcell "$sw" "$swo"
    else
        local st=0 dlt=0
        [ -f "$HOMERPT" ] && st=$(awk -F'\t' -v m="$2" '$1=="SEEN" && $2==m {print $3; exit}' "$HOMERPT")
        st=${st:-0}
        case "$2" in
            partners)     dlt=$(pda_seen_delta partners 1 _partners _hosts) ;;
            applications) dlt=$(pda_seen_delta applications 0 _apps) ;;
            domains)      dlt=$(pda_seen_delta domains 0 _domains) ;;
        esac
        dcell "$st" "$(( st - ${dlt:-0} ))"
    fi
}

# ---- blue-origin matrix ------------------------------------------------------
# WHY each blue entity is blue: DIRECT — the entity itself was the server-log
# seed — or INDIRECT — a seed of another type enriched to it through the xref
# vote. One awk pass over the base caches (the post-guard blue sets) and
# the fake tuples: rows = every blue-carrying type (the five seedable ones
# plus the derived Partners / Domains / Applications, which are never
# a seed themselves), columns = Total + Direct + one per seed type. Each blue
# entity is claimed ONCE: Direct when its own
# name appears in its type's raw seed list, else by the FIRST tuple that
# reaches it — so the columns partition the row and Total IS the row sum.
# Each claim is also logged to a claims file (entity, origin, seed, the seed's
# latest server-log line) that feeds one cell page per nonzero cell below.
blue_matrix=""
SEENLOG_DIR="$REPORTS_DIR/seenlog"
mkdir -p "$SEENLOG_DIR"
rm -f "$SEENLOG_DIR"/*.rpt "$SEENLOG_DIR"/.claims.*
CLAIMS="$SEENLOG_DIR/.claims.$$"
if [ -f "$BLUE_TSV" ]; then
    blue_matrix=$(awk -F'\t' -v cf="$CLAIMS" '
        function isdirect(rt, nm,   x) {
            if ((rt SUBSEP nm) in dir) return 1
            # a canonicalized subscription also matches the truncated seed
            # token that prefixes it
            if (rt == "subscription")
                for (x = 1; x <= ns2; x++) if (index(nm, stok2[x]) == 1) return 1
            return 0
        }
        function sdkey(t2, nm,   x) {   # the sidecar entry backing a seed name
            if ((t2 SUBSEP nm) in sdmsg) return t2 SUBSEP nm
            if (t2 == "subscription")
                for (x = 1; x <= ns2; x++) if (index(nm, stok2[x]) == 1) return t2 SUBSEP stok2[x]
            return ""
        }
        function reg(rt, val,   k, nm, col, t2, sn, sk, dt, ms, rw9, sraw) {
            if (val == "") return
            nm = toupper(val); k = rt SUBSEP nm
            if (!(k in blue) || (k in claimed)) return
            claimed[k] = 1                       # once marked, later seeds skip it
            # display names stay RAW (2026-08-15 audit D3): the cell pages link
            # entities through the slugmap, which resolves by raw name — an
            # uppercased display name silently loses the link
            rw9 = (rawn[k] != "") ? rawn[k] : nm
            if (isdirect(rt, nm)) { col = "D"; t2 = rt; sn = nm; sraw = rw9 }
            else                  { col = st;  t2 = st; sn = toupper(sv); sraw = sv }
            cnt[rt SUBSEP col]++
            sk = sdkey(t2, sn); dt = ""; ms = ""
            if (sk != "") { dt = sddt[sk]; ms = sdmsg[sk] }
            print rt "\t" col "\t" rw9 "\t" t2 "\t" sraw "\t" dt "\t" ms > cf
        }
        function bl(t) { blue[t SUBSEP toupper($1)] = 1; rawn[t SUBSEP toupper($1)] = $1 }
        function sdload(t,   k) {   # a raw sidecar row: direct-sighting set + its latest log line
            if ($1 == "") return
            k = t SUBSEP toupper($1)
            dir[k] = 1; sddt[k] = $2; sdmsg[k] = $3   # name / date time / message
        }
        FILENAME ~ /blue\/_evidence\.tsv$/ {   # per-entity blue evidence (type, name, stamp, message)
            t9 = ($1 == "whitelisted-ip") ? "whitelisted IP" : $1
            evd[t9 SUBSEP toupper($2)] = $3; evm[t9 SUBSEP toupper($2)] = $4; next
        }
        FILENAME ~ /_accounts\.tsv$/      { if ($3 == "blue") bl("account"); next }
        FILENAME ~ /_logins\.tsv$/        { if ($3 == "blue") bl("login"); next }
        FILENAME ~ /_subscriptions\.tsv$/ { if ($3 == "blue") bl("subscription"); next }
        FILENAME ~ /_hosts\.tsv$/         { if ($3 == "blue") bl("host"); next }
        FILENAME ~ /_white\.tsv$/         { if ($3 == "blue") bl("whitelisted IP"); next }
        FILENAME ~ /_subscriptions-partners\.tsv$/ { if ($1 != "" && $2 != "") SUBP[toupper($1)] = SUBP[toupper($1)] SUBSEP $2; next }
        FILENAME ~ /_accounts-apps\.tsv$/ { if ($1 != "" && $2 != "") ACAP[toupper($1)] = ACAP[toupper($1)] SUBSEP $2; next }
        FILENAME ~ /_partners\.tsv$/      { if ($3 == "blue") bl("partner"); next }
        FILENAME ~ /_domains\.tsv$/       { if ($3 == "blue") bl("domain"); next }
        FILENAME ~ /_apps\.tsv$/          { if ($3 == "blue") bl("application"); next }
        # the RAW seed lists (pre-dedup) decide DIRECT — the deduped tuples
        # would credit a combined login+account sighting to one type only
        FILENAME ~ /unknown\/accounts\.tsv$/ { sdload("account"); next }
        FILENAME ~ /unknown\/logins\.tsv$/   { sdload("login"); next }
        FILENAME ~ /unknown\/hosts\.tsv$/    { sdload("host"); next }
        FILENAME ~ /unknown\/white\.tsv$/    { sdload("whitelisted IP"); next }
        FILENAME ~ /unknown\/sites\.tsv$/    { sdload("subscription"); if ($1 != "") stok2[++ns2] = toupper($1); next }
        {   # a fake tuple: seed type from the file marker; a white tuple
            # carries its IP in the host column, so col 15 routes by type
            st = substr($11, 7)
            if      (st == "account")      sv = $3
            else if (st == "login")        sv = $14
            else if (st == "subscription") sv = $12
            else                           sv = $15
            reg("account", $3); reg("login", $14); reg("subscription", $12)
            if (st == "whitelisted IP") reg("whitelisted IP", $15)
            else reg("host", $15)
            # the derived attributions the tuple carries:
            # 20 partner, 19 domain, 18 application — never a seed themselves
            # (no sidecar), so their Direct column is always empty. Partner =
            # the UNION of col 20 and the subscription'\''s configured
            # partner(s) (a both-partner subscription leaves col 20 empty);
            # application = the UNION of col 18 and the account'\''s
            # configured application(s) (a UC8 relay account carries two,
            # the parse keeps one) — cf. pda-entities.sh
            reg("partner", $20); reg("domain", $19); reg("application", $18)
            if ($12 != "" && (toupper($12) in SUBP)) {
                nps = split(substr(SUBP[toupper($12)], 2), PLZ, SUBSEP)
                for (ips = 1; ips <= nps; ips++) reg("partner", PLZ[ips])
            }
            if ($3 != "" && (toupper($3) in ACAP)) {
                nps = split(substr(ACAP[toupper($3)], 2), PLZ, SUBSEP)
                for (ips = 1; ips <= nps; ips++) reg("application", PLZ[ips])
            }
        }
        END {
            # Any blue entity claimed by NO tuple and NO raw seed — the Step-F0
            # SSH-logon discoveries (result.sh flips them from the logon
            # sidecars, no TM tuple exists) — is claimed DIRECT here with its
            # blue evidence line, so every matrix Total equals the type'\''s
            # actual blue count (2026-08-15 audit finding A3). The claims file
            # is re-sorted downstream, so hash order here never reaches a page.
            for (k in blue) if (!(k in claimed)) {
                claimed[k] = 1
                split(k, KK, SUBSEP); rt9 = KK[1]; nm9 = KK[2]
                cnt[rt9 SUBSEP "D"]++
                rw9 = (rawn[k] != "") ? rawn[k] : nm9
                print rt9 "\tD\t" rw9 "\t" rt9 "\t" rw9 "\t" \
                    ((k in evd) ? evd[k] : "") "\t" ((k in evm) ? evm[k] : "") > cf
            }
            n = split("account|login|subscription|host|whitelisted IP|partner|domain|application", T, "|")
            split("Accounts|Logins|Subscriptions|Hosts|Whitelisted IPs|Partners|Domains|Applications", D, "|")
            nc = split("account|login|subscription|host|whitelisted IP", C, "|")
            for (i = 1; i <= n; i++) {
                dct = cnt[T[i] SUBSEP "D"] + 0
                tot = dct
                for (j = 1; j <= nc; j++) tot += cnt[T[i] SUBSEP C[j]] + 0
                line = D[i] "\t" tot "\t" dct
                for (j = 1; j <= nc; j++) line = line "\t" (cnt[T[i] SUBSEP C[j]] + 0)
                print line
            }
        }
    ' "$BASE_DIR/_accounts.tsv" "$BASE_DIR/_logins.tsv" "$BASE_DIR/_subscriptions.tsv" \
      "$BASE_DIR/_hosts.tsv" "$BASE_DIR/_white.tsv" \
      "$BASE_DIR/_partners.tsv" "$BASE_DIR/_domains.tsv" "$BASE_DIR/_apps.tsv" \
      "$CONFIG_XREF/_subscriptions-partners.tsv" "$CONFIG_XREF/_accounts-apps.tsv" \
      ${sidecar_deps[@]+"${sidecar_deps[@]}"} "$BLUE_EVID" "$BLUE_TSV")
fi

# ---- the matrix cell pages ----------------------------------------------------
# One .rpt per NONZERO matrix cell (data/transfer/reports/seenlog/<row>-<col>.rpt,
# rendered by bin/transfer/publish.sh to docs/transfer/seenlog/): the entities
# that cell counts, each with the server-log line whose sighting claimed it.
# The Total column gets a whole-row page (<row>-all), the footer a whole-column
# page (all-<col>) and the grand total everything (all-all).
TAB=$(printf '\t')
# the ACTUAL blue count, from the matrix row totals (= the base caches' blue
# sets, every one claimed) — the INTRO headline; $n stays the TUPLE count
n_blue=0
[ -n "$blue_matrix" ] && n_blue=$(printf '%s\n' "$blue_matrix" | awk -F'\t' '{s+=$2} END{print s+0}')
if [ -s "$CLAIMS" ]; then
    # ONE sort + ONE awk writes every NONZERO cell page (was 9x7 emit_claim_page
    # calls, each re-filtering + re-sorting $CLAIMS with a date fork per page).
    # The global sort uses the SAME keys the per-cell sort did — a filtered
    # subset of the globally sorted stream equals the sorted filtered subset
    # (the whole-line last-resort comparison makes the order total) — so each
    # page's row order is unchanged. Every claim row lands in four cells:
    # (row type, origin col), the row's Total, the footer's column page and
    # the grand total. Pages are written from END in the fixed row-major loop
    # order, never awk hash order; an empty cell writes no page, as before.
    LC_ALL=C sort -t"$TAB" -k1,1 -k3,3 "$CLAIMS" | awk -F'\t' \
        -v dir="$SEENLOG_DIR" -v ts="$(date '+%Y-%m-%d %H:%M:%S')" '
        BEGIN {
            nr = split("account|login|subscription|host|whitelisted IP|partner|domain|application|", RT, "|")   # RT[9] = "" = all rows
            split("accounts|logins|subscriptions|hosts|white|partners|domains|applications|all", RSL, "|")
            split("Blue Accounts|Blue Logins|Blue Subscriptions|Blue Hosts|Blue Whitelisted IPs|Blue Partners|Blue Domains|Blue Applications|All blue entities", RLB, "|")
            nc = split("|D|account|login|subscription|host|whitelisted IP", CT, "|")                            # CT[1] = "" = all origins
            split("all|direct|account|login|subscription|host|white", CSL, "|")
            split("all origins|direct sighting|account seed|login seed|subscription seed|host seed|whitelisted IP seed", CLB, "|")
            for (i = 1; i <= nr; i++) ri[RT[i]] = i
            for (j = 1; j <= nc; j++) ci[CT[j]] = j
            lbl["account"] = "Account"; lbl["login"] = "Login"
            lbl["subscription"] = "Subscription"; lbl["host"] = "Host"
            lbl["whitelisted IP"] = "Whitelisted IP"
            lbl["partner"] = "Partner"; lbl["domain"] = "Domain"
            lbl["application"] = "Application"
            ds["account"] = "accounts"; ds["login"] = "logins"
            ds["subscription"] = "subscriptions"; ds["host"] = "hosts"
            ds["partner"] = "partners"
            ds["domain"] = "domains"; ds["application"] = "applications"
            ds["whitelisted IP"] = "incoming_connections"   # the sighted-IP detail pages
        }
        {
            el = $3
            if ($1 in ds) el = "@{alink=" ds[$1] "/" $3 "}" $3
            if ($2 == "D") { cb = "Direct"; sd = "" }
            else {
                cb = lbl[$2] " seed"
                sd = $5
                if ($2 in ds) sd = "@{alink=" ds[$2] "/" $5 "}" $5
            }
            row = "ROW\t" lbl[$1] "\t" el "\t" cb "\t" sd "\t" $6 "\t" $7
            i = ri[$1]; j = ci[$2]
            cnt[i, j]++;  body[i, j]  = body[i, j]  row "\n"
            cnt[i, 1]++;  body[i, 1]  = body[i, 1]  row "\n"
            cnt[nr, j]++; body[nr, j] = body[nr, j] row "\n"
            cnt[nr, 1]++; body[nr, 1] = body[nr, 1] row "\n"
        }
        END {
            for (i = 1; i <= nr; i++) for (j = 1; j <= nc; j++) {
                if (!((i, j) in cnt)) continue
                n = cnt[i, j]
                f = dir "/" RSL[i] "-" CSL[j] ".rpt"
                printf "TITLE\t%s — %s\n", RLB[i], CLB[j] > f
                printf "INTRO\tThe **%d** blue entities this cell counts, each with the server-log line whose sighting claimed it. **Direct** = the entity itself was the server-log seed; a seed origin = that seed reached the entity through the FlowManager cross-reference enrichment.\n", n > f
                printf "TABLE\t\twide\n" > f
                printf "HEAD\tEntity type\tEntity\tOrigin\tSeed\tDate & time\tServer-log message\n" > f
                printf "KIND\ttext\ttext\ttext\ttext\ttext\ttext\n" > f
                printf "%s", body[i, j] > f
                printf "TOTAL\tTotal (%d entities)\t\t\t\t\t\n", n > f
                printf "LINK\t../seen-in-server-log.html\tSeen in server log — the audit page this cell comes from\n" > f
                printf "FOOT\tGenerated on %s\n", ts > f
                close(f)
            }
        }'
fi
rm -f "$CLAIMS"

# emit_status_table TITLE  label:basefile:pairitem:covname:seencol ...
#   pairitem empty  -> the subscriptions themselves (result stage 1)
#   seencol empty   -> a PDA member (Seen from coverage, no delta)
emit_status_table() {
    local title=$1; shift
    printf 'TABLE\t%s\tnosearch\tsxs\n' "$title"
    printf 'HEAD\tEntity\tConfigured\tSeen\tError\tWarning\tOk\n'
    printf 'KIND\ttext\tnum\tnum\tnum\tnum\tnum\n'
    local spec label bf item cov seencol base tot rw ow gw rwo owo gwo
    for spec in "$@"; do
        IFS=: read -r label bf item cov seencol <<<"$spec"
        base="$BASE_DIR/$bf.tsv"
        [ -f "$base" ] || continue
        read -r tot rw ow gw <<<"$(awk -F'\t' '{n++;c[$3]++} END{printf "%d %d %d %d",n+0,c["red"]+0,c["orange"]+0,c["green"]+0}' "$base")"
        if [ -z "$item" ]; then
            read -r rwo owo gwo <<<"$(awk -F'\t' '{c[$2]++} END{printf "%d %d %d",c["red"]+0,c["orange"]+0,c["green"]+0}' "$subres_wo")"
        elif [ "$item" = white ]; then
            # the whitelist exception (bin/build/result.sh white_own): an IP is
            # green/red by its OWN last transfer — the blue-free recount uses
            # the same rule (real _files rows carry no fakes, so only the
            # blue -> orange difference remains)
            read -r rwo owo gwo <<<"$(awk -F'\t' '
                FILENAME==ARGV[1]{ if ($1=="O15") oc[$2]=$3; next }            # the _files extract: last outcome per raw host
                { r="orange"; if($1 in oc) r=(oc[$1]=="Failed"||oc[$1]=="Expired")?"red":"green"; c[r]++ }
                END{printf "%d %d %d",c["red"]+0,c["orange"]+0,c["green"]+0}
            ' "$fseen" "$base")"
        else
            read -r rwo owo gwo <<<"$(awk -F'\t' '
                FILENAME==ARGV[1]{sres[$1]=$2;next}
                FILENAME==ARGV[2]{k=toupper($1);s=sres[toupper($2)];if(s=="")next;n[k]++;if(s=="green")g[k]++;else if(s=="red")rd[k]++;next}
                {k=toupper($1);r="orange";if((k in rd)&&rd[k]>0)r="red";else if((k in n)&&n[k]>0&&g[k]==n[k])r="green";c[r]++}
                END{printf "%d %d %d",c["red"]+0,c["orange"]+0,c["green"]+0}
            ' "$subres_wo" "$XREF_DIR/_${item}-subscriptions.tsv" "$base")"
        fi
        printf 'ROW\t%s\t%d\t%s\t@{class=st-err}%s\t@{class=st-warn}%s\t@{class=st-ok}%s\n' \
            "$label" "$tot" "$(seen_cell "$bf" "$cov" "$seencol")" \
            "$(dcell "$rw" "$rwo")" "$(dcell "$ow" "$owo")" "$(dcell "$gw" "$gwo")"
    done
}

{
    printf 'TITLE\tSeen in server log\n'
    printf 'DESC\tThe server-log-only entities marked blue — what was detected, and the server-log line that proved it alive.\n'
    printf 'INTRO\tEntities that appear in **server-log** runtime messages (Transfer Manager lines) but have no record in the **transfer log** are marked **blue** — a 4th result state — in the base result column (build step `bin/build/seen-in-server-log.sh`), so they surface in the entity reports, detail pages and coverage views as *server-log only* (the **Server** bucket) with no fabricated transfer. This page is the audit of that step: **%s** entities are currently marked blue, every one accounted for in the **Why blue** matrix below. The TM-message seeds materialized **%s** injected tuples — **%s** from account seeds, **%s** login, **%s** subscription, **%s** host, **%s** whitelisted IP; an entity discovered only by its **successful SSH logons** (the logon rule — no TM tuple exists) is claimed **Direct** in the matrix with the logon line as its evidence. The two tables below are the result-status rollups from the **Flow manager Entities** and **Partners, Domains & Applications** analyses pages (Seen = configured entities with at least one transfer OR a blue server-log sighting; Error / Warning / Ok = red / orange / green by each seen entity'"'"'s last transaction); a **(+n)** or **(−n)** on a figure is how much the blue marking moved it — the Seen column gains the blue count, and the entities leave Warning (they are no longer *never seen*). In the list, each entry is two rows — the server-log message that proved the entity alive, then its blue attribution: the seed plus everything the FlowManager cross-references could unambiguously fill in (a truncated subscription name is canonicalized to the configured name it uniquely prefixes). A host or whitelisted-IP seed that ties to no account, login, subscription or flow is dropped — as is a whitelisted-IP seed whose partner already has transfer data (an unused alternate address is not a server-log discovery) — and two seeds enriching to the same entity combination collapse into one row.\n' \
        "$n_blue" "$n" "$n_acct" "$n_login" "$n_site" "$n_host" "$n_white"
    emit_status_table 'Flow manager entities' \
        'Subscriptions:_subscriptions::subscriptions:12' \
        'Accounts:_accounts:accounts:accounts:3' 'Hosts:_hosts:hosts:hosts:15' 'Logins:_logins:logins:logins:14' \
        'Whitelist:_white:white:white:15'
    emit_status_table 'Partners, Domains & Applications' \
        'Partners:_partners:partners:partners:' 'Domains:_domains:domains:domains:' 'Applications:_apps:apps:applications:'
    if [ -n "$blue_matrix" ]; then
        printf 'TABLE\tWhy blue — direct sighting or a connected seed\tnosearch\n'
        printf 'HEAD\tEntity type\tTotal\tDirect\tAccount\tLogin\tSubscription\tHost\tWhitelisted IP\n'
        printf 'KIND\ttext\tnum\tnum\tnum\tnum\tnum\tnum\tnum\n'
        mrow=(accounts logins subscriptions hosts white partners domains applications)
        mcol=(all direct account login subscription host white)
        tt=0; t0=0; t1=0; t2=0; t3=0; t4=0; t5=0; nbmr=0
        while IFS=$'\t' read -r lbl tot d c1 c2 c3 c4 c5; do
            [ -n "$lbl" ] || continue
            mrs=${mrow[$nbmr]}
            nbmr=$((nbmr + 1))
            tt=$((tt + tot)); t0=$((t0 + d)); t1=$((t1 + c1)); t2=$((t2 + c2)); t3=$((t3 + c3)); t4=$((t4 + c4)); t5=$((t5 + c5))
            # each nonzero cell links its cell page (the entities it counts +
            # their claiming server-log lines); a zero cell renders blank
            mline="ROW$TAB$lbl"; mvi=0
            for mv in "$tot" "$d" "$c1" "$c2" "$c3" "$c4" "$c5"; do
                if [ "$mv" != 0 ] && [ -f "$SEENLOG_DIR/$mrs-${mcol[$mvi]}.rpt" ]; then
                    mline+="$TAB@{href=seenlog/$mrs-${mcol[$mvi]}.html}$mv"
                elif [ "$mv" = 0 ]; then
                    mline+="$TAB"
                else
                    mline+="$TAB$mv"
                fi
                mvi=$((mvi + 1))
            done
            printf '%s\n' "$mline"
        done <<< "$blue_matrix"
        tot_cell() {   # $1 value  $2 col slug — the footer's whole-column page
            if [ "$1" != 0 ] && [ -f "$SEENLOG_DIR/all-$2.rpt" ]; then
                printf '@{class=num,href=seenlog/all-%s.html}%s' "$2" "$1"
            else
                printf '@{class=num}%s' "$1"
            fi
        }
        printf 'TOTAL\tTotal (%s types)\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$nbmr" \
            "$(tot_cell "$tt" all)" "$(tot_cell "$t0" direct)" "$(tot_cell "$t1" account)" \
            "$(tot_cell "$t2" login)" "$(tot_cell "$t3" subscription)" "$(tot_cell "$t4" host)" "$(tot_cell "$t5" white)"
        printf 'NOTE\tWhy each blue entity is blue — every entity is counted exactly ONCE: under **Direct** when its own name appears in its type'\''s server-log seed list (the raw sightings, before duplicate seeds collapse) OR when only its **successful SSH logons** discovered it (the logon rule — no TM tuple exists; its evidence line is the logon), otherwise under the seed type of the first surviving seed tuple that reached it through the FlowManager cross-reference enrichment (later seeds reaching an already-claimed entity are skipped). Partners, Domains and Applications are derived attributions — never a TM seed themselves, so a Direct entry there is an SSH-logon-era rollup discovery. **Total** = the sum of the other columns = the type'\''s blue entities. Every nonzero cell links a page listing the entities it counts with their claiming server-log lines.\n'
    fi
    if [ -n "$shapes_ranked" ]; then
        printf 'TABLE\tWhat happened — server-log messages grouped\twide\n'
        printf 'HEAD\tCount\tServer-log message shape\n'
        printf 'KIND\tnum\ttext\n'
        # each shape cell links DOWN to its own Injected table (anchor shape-N)
        printf '%s\n' "$shapes_ranked" | awk -F'\t' 'NF { printf "ROW\t%s\t@{href=#shape-%s}%s\n", $2, $1, $3 }'
        printf 'TOTAL\t%s\tTotal (%s distinct shape(s))\n' "$n" "$n_shapes"
        printf 'NOTE\tThe seed'"'"'s latest server-log message, grouped into shapes: quoted values, IPs, UUIDs and numbers are normalized away so like events cluster. **Click a shape** to jump to its own injected-transfers table below. Click a column header to re-sort.\n'
    fi
    # ---- one "Injected fake transfers" table per shape, linked from above -----
    if [ -n "$shapes_ranked" ]; then
        while IFS=$'\t' read -r sidx scnt sshape; do
            [ -n "$sidx" ] || continue
            printf 'TABLE\tServer-log entities — %s\twide\tnosearch\tanchor=shape-%s\n' "$sshape" "$sidx"
            printf 'HEAD\tSeed\tAccount\tLogin\tSubscription\tRemote Host\tDate & time\n'
            printf 'KIND\ttext\tacct\tlogin\tsite\thost\ttext\n'
            # each fake is TWO physical rows: the seed'\''s latest server-log message
            # (full width, truncated to 300 chars), then the injected entry. Date &
            # time are one column so a sort orders chronologically; report.js keeps
            # each message row above its data row through any sort (bindPairs).
            printf '%s\n' "$rows_indexed" | awk -F'\t' -v OFS='\t' -v want="$sidx" '$11 == want {
                msg = ($9 != "") ? substr($9, 1, 300) : "(no server-log message)"
                print "ROW", "@{colspan=6,class=bluemsg}" msg
                print "ROW", $1, $2, $3, $4, $5, $7 " " $8
            }'
            printf 'TOTAL\tTotal (%s entity(ies))\t\t\t\t\t\n' "$scnt"
        done <<< "$shapes_ranked"
    else
        printf 'TABLE\tServer-log-only entities\twide\tnosearch\n'
        printf 'HEAD\tSeed\tAccount\tLogin\tSubscription\tRemote Host\tDate & time\n'
        printf 'KIND\ttext\tacct\tlogin\tsite\thost\ttext\n'
        printf 'TOTAL\tTotal (%s entity(ies))\t\t\t\t\t\n' "$n"
    fi
    printf 'NOTE\tOne table per message shape (most frequent first). Each entry is two rows: the seed'"'"'s most recent server-log line (the one the blue marking is dated to; truncated to 300 characters), then the entity'"'"'s blue attribution. No transfer is fabricated — the entity is simply marked **blue** (result = blue) in the base result column, so the per-row dimension reports (protocol, AV scan, ciphers, …) never see it and only the entity, time and coverage views count it (in the **Server** bucket).\n'
    printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($n fake transfer(s))." >&2
