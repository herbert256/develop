#!/usr/bin/env bash
#
# details_lib.sh — the stream PRODUCERS of the per-entity detail pages,
# extracted from bin/transfer/reports/details.sh (2026-07). SOURCED, not run.
# The four producers here (direction_rows, compute_extras, whitelist_rows,
# aggregate_files) plus insert_config_rows emit the sorted section stream;
# details.sh keeps the orchestration (guards, shared prep, the sort, the
# annotation pass) and the WRITER is bin/transfer/details_writer.awk — one
# awk per entity type over the per-type slices (see the note at the bottom).
# See details.sh for the stream protocol and section numbering.
# ===== partner / application UNION attribution ===============================
# A File counts for EVERY partner of its subscription (col 12 joined on
# xref/_subscriptions-partners.tsv) UNIONED with the parse-time attribution
# (col 20) — mirrors pda-entities.sh: a UC5 relay / both-partner file belongs
# to BOTH organisations, and the both-partner case carries an EMPTY col 20
# (the account maps to two groups, so the parse abstains). Likewise a File
# counts for every application of its SUBSCRIPTION (col 12 joined on
# xref/_subscriptions-apps.tsv — the FlowID spine, 1:1) unioned with col 18.
# NOT the account any more (2026-08-31): a hybrid production account serves
# many flows, so the account union credited every File of it to every
# application the account touches.
# And a File counts for EVERY logical flow group of its profile (col 13
# resolved through xref/_profiles-logicals.tsv — the FlowID map) UNIONED with
# its subscription'\''s logicals (col 12 on xref/_subscriptions-logicals.tsv).
# And a File counts for every BL tag of its SUBSCRIPTION (col 12 on
# xref/_subscriptions-bl.tsv — no direct column of its own).
# sp_union()/ap_union()/lg_union()/bl_union() return the \037-joined set;
# callers split and loop. Inject as
#   awk -F'\t' -v SPMAP="$SP_MAP" -v APMAP="$AP_MAP" -v PLMAP="$PL_MAP" -v SLGMAP="$SLG_MAP" -v BLMAP="$BL_MAP" "$SP_AWK"'...'
SP_MAP="$CONFIG_XREF/_subscriptions-partners.tsv"
[ -f "$SP_MAP" ] || SP_MAP=""
AP_MAP="$CONFIG_XREF/_subscriptions-apps.tsv"
[ -f "$AP_MAP" ] || AP_MAP=""
PL_MAP="$CONFIG_XREF/_profiles-logicals.tsv"
[ -f "$PL_MAP" ] || PL_MAP=""
SLG_MAP="$CONFIG_XREF/_subscriptions-logicals.tsv"
[ -f "$SLG_MAP" ] || SLG_MAP=""
BL_MAP="$CONFIG_XREF/_subscriptions-bl.tsv"
[ -f "$BL_MAP" ] || BL_MAP=""
SP_AWK='
    function uni_load(f6, M6,   l6, z6, n6) { if (f6 == "") return
        while ((getline l6 < f6) > 0) { n6 = split(l6, z6, "\t")
            if (n6 >= 2 && z6[1] != "" && z6[2] != "")
                M6[toupper(z6[1])] = M6[toupper(z6[1])] (M6[toupper(z6[1])] == "" ? "" : "\037") z6[2] }
        close(f6) }
    function uni_join(v6, k6, M6,   n6, i6, r6) {
        r6 = v6
        if (k6 != "" && (toupper(k6) in M6)) { n6 = split(M6[toupper(k6)], SPZ6, "\037")
            for (i6 = 1; i6 <= n6; i6++)
                if (index("\037" r6 "\037", "\037" SPZ6[i6] "\037") == 0)
                    r6 = r6 (r6 == "" ? "" : "\037") SPZ6[i6] }
        return r6 }
    function sp_union(p6, s6) { return uni_join(p6, s6, SPX) }
    function ap_union(a6, ac6) { return uni_join(a6, ac6, APX) }
    function lg_union(p6, s6,   b6) { b6 = ""
        if (p6 != "" && (toupper(p6) in PLX)) b6 = PLX[toupper(p6)]
        return uni_join(b6, s6, SLGX) }
    function bl_union(s6) { return uni_join("", s6, BLX) }
    BEGIN { uni_load(SPMAP, SPX); uni_load(APMAP, APX); uni_load(PLMAP, PLX); uni_load(SLGMAP, SLGX); uni_load(BLMAP, BLX) }
'
# ===== direction lines (section -1) ==========================================
# One line per entity carrying its configured DIRECTION (in/both/out; unknown
# when unclassified) — one for every name in data/flow-manager/base/ (all
# lists except _white.tsv). A config name matching a logged spelling
# case-insensitively folds onto the LOGGED spelling (one page); a configured
# subscription name also passes its direction to every logged site value it
# prefixes (in+out merge to both). These sort before every section (sec -1),
# so the writer knows direction + configured-ness when it creates the page —
# and a configured-but-never-logged name materializes its page from this line
# alone. Logged entities with no config line default to unknown in the writer.
direction_rows() {
    local args=("$FILES" "$PARSED") b
    for b in _accounts _subscriptions _logins _hosts _logicals _partners _apps _domains _bl; do
        [ -f "$CONFIG_BASE/$b.tsv" ] && args+=("$CONFIG_BASE/$b.tsv")
    done
    awk -F'\t' '
        function upd(t, e, d,   k, o) {   # merge: a real direction beats unknown, in+out -> both
            if (d == "") d = "unknown"
            k = t SUBSEP e; o = DIR[k]
            if (o == "" || o == "unknown") DIR[k] = d
            else if (d != "unknown" && d != o && o != "both") DIR[k] = "both"
        }
        function conf(t, n, d,   k, sp, i) {
            k = t SUBSEP toupper(n); sp = (k in U) ? U[k] : n
            upd(t, sp, d)
            if (t == "SITE") for (i = 1; i <= nsl; i++)
                if (index(toupper(SL[i]), toupper(n)) == 1) upd("SITE", SL[i], d)
        }
        FILENAME ~ /_files\.tsv$/ {
            if ($3  != "") U["ACC"  SUBSEP toupper($3)]  = $3
            if ($20 != "") U["PTN"  SUBSEP toupper($20)] = $20
            if ($18 != "") U["APP"  SUBSEP toupper($18)] = $18
            if ($19 != "") U["DOM"  SUBSEP toupper($19)] = $19
            cn[$1] = $16   # connection side, for the HOST gate below ($FILES precedes $PARSED in args)
            next }
        FILENAME ~ /_transfers\.tsv$/ {
            if ($5  != "") U["LOGIN" SUBSEP toupper($5)]  = $5
            if ($6  != "" && !(("SITE" SUBSEP toupper($6)) in U)) { U["SITE" SUBSEP toupper($6)] = $6; SL[++nsl] = $6 }
            # only OUTBOUND endpoints are HOST entities (no pages for the
            # source IPs of incoming connections)
            if ($16 != "" && cn[$1] == "out") U["HOST" SUBSEP toupper($16)] = $16
            next }
        FILENAME ~ /_accounts\.tsv$/      { conf("ACC",   $1, $2); next }
        FILENAME ~ /_subscriptions\.tsv$/ { conf("SITE",  $1, $2); next }
        FILENAME ~ /_logins\.tsv$/        { conf("LOGIN", $1, $2); next }
        FILENAME ~ /_hosts\.tsv$/         { conf("HOST",  $1, $2); next }
        FILENAME ~ /_logicals\.tsv$/      { conf("LGC",   $1, $2); next }
        FILENAME ~ /_partners\.tsv$/      { conf("PTN",   $1, $2); next }
        FILENAME ~ /_apps\.tsv$/          { conf("APP",   $1, $2); next }
        FILENAME ~ /_domains\.tsv$/       { conf("DOM",   $1, $2); next }
        FILENAME ~ /_bl\.tsv$/            { conf("BL",    $1, $2); next }
        END { for (k in DIR) { split(k, a, SUBSEP); printf "%s\t%s\t-1\t0\t%s\n", a[1], a[2], DIR[k] } }
    ' "${args[@]}"
}

# ===== header extras, unit-independent (perf / IP)
# (the distinct-SESSION count went with the session_id cache column in 2026-07;
# its x_sess value had had no renderer since the Sessions row was dropped.
# The 0/5 server-mention count went the same way in 2026-07: its x_srv value
# had had no renderer since the Metrics table was removed, so the ACCTSRV side
# input and this pass's second file are gone too.)
# Merged into the files stream. Perf is processed ROWS (as the "Processed
# transfers" KPI reads).
compute_extras() {
  awk -F'\t' -v SPMAP="$SP_MAP" -v APMAP="$AP_MAP" -v PLMAP="$PL_MAP" -v SLGMAP="$SLG_MAP" -v BLMAP="$BL_MAP" "$SP_AWK"'
    function human(b,   u,i,v){ split("B KB MB GB TB PB",u," "); i=1; v=b+0; while(v>=1024&&i<6){v/=1024;i++} return (i==1)?sprintf("%d %s",v,u[i]):sprintf("%.2f %s",v,u[i]) }
    function humandur(ms){ if(ms<1000) return sprintf("%d ms",ms); if(ms<60000) return sprintf("%.2f s",ms/1000); if(ms<3600000) return sprintf("%.1f min",ms/60000); return sprintf("%.2f h",ms/3600000) }
    function thr(bytes,ms){ return ms>0 ? human(bytes*1000/ms) "/s" : "-" }
    function qsort(A, lo, hi,   i, j, p2, t) {
        while (lo < hi) {
            i = lo; j = hi; p2 = A[int((lo + hi) / 2)]
            while (i <= j) { while (A[i] < p2) i++; while (A[j] > p2) j--; if (i <= j) { t = A[i]; A[i] = A[j]; A[j] = t; i++; j-- } }
            if (j - lo < hi - i) { if (lo < j) qsort(A, lo, j); lo = i } else { if (i < hi) qsort(A, i, hi); hi = j }
        }
    }
    function perf(ty,ent,   k){ if(ent=="")return; k=ty SUBSEP ent; pn[k]++; PV[k,pn[k]]=dur; ps2[k]+=dur; pby[k]+=size; if(dur>pmx[k])pmx[k]=dur; if(pn[k]==1||dur<pmn[k])pmn[k]=dur
      # the same three perf figures PER DAY (section 0/7 below): the Ranking
      # report re-aggregates Duration and Throughput over a From/To range, and
      # both are averages over the TIMED population only — the day table (which
      # counts every File) cannot stand in for it. Note the `in` test: a bare
      # read would create the key.
      if(dt!=""){ if(!((k SUBSEP dt) in pdn)) pdk[k]=pdk[k] (pdk[k]==""?"":" ") dt
                  pdn[k,dt]++; pdms[k,dt]+=dur; pdby[k,dt]+=size } }
    FNR == 1 { fno++ }
    fno == 1 { if($1 != "#") rip[$1] = rip[$1] (rip[$1]==""?"":" ") $2; next }   # hostname -> raw IP(s)
    fno == 2 { pu6 = sp_union($20, $12)                                          # partner / application / logical / BL = the UNION sets, \037-joined
               au6 = ap_union($18, $12)
               lu6 = lg_union($13, $12)
               bu6 = bl_union($12)
               if(pu6 != "") fptn[$1] = pu6; if(au6 != "") fapp[$1] = au6; if($19 != "") fdom[$1] = $19
               if(lu6 != "") flgc[$1] = lu6
               if(bu6 != "") fbl[$1] = bu6
               cn[$1] = $16; next }                                              # connection side (the HOST gate)
    {
      st=$3; sub(/ Subtransmission$/,"",st); pr2=(st=="Processed")
      # HOST entities are outbound endpoints only — see aggregate_files
      acct=$4; site=$6; login=$5; host=(cn[$1]=="out" ? $16 : ""); size=$9; dur=$15+0; dt=$11
      npt2=split(fptn[$1], PT2, "\037"); nap2=split(fapp[$1], AP2, "\037"); dm2=fdom[$1]
      nlg2=split(flgc[$1], LG2, "\037"); nbl2=split(fbl[$1], BL2, "\037")
      if(pr2 && dur>=0){ perf("ACC",acct); perf("SITE",site); perf("LOGIN",login); perf("HOST",host)
                         for(ip2=1;ip2<=nlg2;ip2++) perf("LGC",LG2[ip2])
                         for(ip2=1;ip2<=npt2;ip2++) perf("PTN",PT2[ip2]); for(ip2=1;ip2<=nap2;ip2++) perf("APP",AP2[ip2]); perf("DOM",dm2)
                         for(ip2=1;ip2<=nbl2;ip2++) perf("BL",BL2[ip2]) }
      if(host!="") hseen[host]=1
    }
    END {
      for(k in pn){ n=pn[k]; for(i=1;i<=n;i++)T[i]=PV[k,i]; qsort(T,1,n)
        p50=T[int((n-1)*50/100+0.5)+1]; p95=T[int((n-1)*95/100+0.5)+1]; p99=T[int((n-1)*99/100+0.5)+1]; split(k,a,SUBSEP)
        printf "%s\t%s\t0\t1\t%d|%s|%s|%s|%s|%s|%s|%s\n", a[1],a[2],n,humandur(pmn[k]+0),humandur(ps2[k]/n),humandur(p50),humandur(p95),humandur(p99),humandur(pmx[k]+0),thr(pby[k],ps2[k]) }
      # 0/7 = the per-day timed triple "date:files:ms:bytes|…" (see perf()).
      # Line ORDER is hash order here as it is above — the stream is sorted
      # before the writer reads it, so the output stays deterministic.
      for(k in pn){ split(k,a,SUBSEP); np9=split(pdk[k],K9," "); s9=""
        for(i9=1;i9<=np9;i9++){ d9=K9[i9]; s9=s9 (s9==""?"":"|") d9 ":" pdn[k,d9] ":" pdms[k,d9] ":" pdby[k,d9] }
        if(s9!="") printf "%s\t%s\t0\t7\t%s\n", a[1],a[2],s9 }
      # Duration / Throughput RANKS within the entity type (the detail Ranking
      # table + matching the Ranking report): avg duration ASC (fastest = #1),
      # throughput DESC (highest = #1) over the entities WITH measurable perf
      for(k in pn){ split(k,a,SUBSEP)
        av5 = ps2[k]/pn[k]; th5 = (ps2[k] > 0 ? pby[k]*1000/ps2[k] : 0)
        dr5 = 1; tr5 = 1
        for(k2 in pn){ if(k2 == k) continue; split(k2,b5,SUBSEP); if(b5[1] != a[1]) continue
          if(ps2[k2]/pn[k2] < av5) dr5++
          if((ps2[k2] > 0 ? pby[k2]*1000/ps2[k2] : 0) > th5) tr5++ }
        printf "%s\t%s\t0\t6\t%d|%d\n", a[1], a[2], dr5, tr5 }
      for(h in rip) if(h in hseen) printf "HOST\t%s\t0\t3\t%s\n", h, rip[h]
    }
  ' "$IPMAP" "$FILES" "$PARSED"
}

# ===== Incoming / Outgoing connections (sections 2.6 / 2.7) ==================
# Two tables right after the Features summary, one per CONNECTION side, same layout
# (IP-or-Host · In · Out · Name):
#   2.6 Incoming connections — the UNION of the entity's configured whitelist
#       (the *-white caches) and the source addresses OBSERVED on its
#       incoming-connection Files (_files col 16 == "in"; raw IPs since the
#       side-aware parse). Colored against the GLOBAL expanded whitelist
#       (base/_white.tsv).
#   2.7 Outgoing connections — the UNION of the entity's configured endpoints
#       (the _<item>-hosts caches; a HOST page is its own endpoint) and the
#       hosts OBSERVED on its outgoing-connection Files (col 16 == "out").
#       Colored against the GLOBAL configured endpoint list (base/_hosts.tsv).
# Each row carries the file-movement split (In = a file entered us, Out = one
# left us; _files col 17) and a result color:
#   green  = configured/whitelisted + traffic     red = traffic, unconfigured
#   orange = configured/whitelisted, no traffic
# Name = the configured endpoint an IP maps to (blank when it maps to none).
# The sortkey zero-pads IP octets so addresses list in address order; named
# hosts sort by name.
# NOTE the whitelist is NOT reverse-resolved (dropped 2026-07). Every whitelisted
# address used to get a PTR lookup purely to fill the Name column below; measured
# before removing it, two thirds of them had no PTR at all, and of the names that
# came back most encoded the address itself (095-097-053-146.static.chello.nl) or
# named the partner's ISP rather than the endpoint, on rows folded out of sight by
# default. A whitelisted address now shows a Name only when it is also a
# configured endpoint's address, which is the case worth showing.
whitelist_rows() {
    local f
    for f in accounts subscriptions logins hosts logicals partners apps domains bl; do
        [ -f "$CONFIG_XREF/_$f-white.tsv" ] || return 0
    done
    # ip -> endpoint, for the Incoming-connections Name column. One read of
    # ip-hosts.tsv; an address with no configured endpoint simply has no row and
    # its Name cell stays blank.
    local ipmap; ipmap=$(mktemp "${TMPDIR:-/tmp}/wlrev.XXXXXX")
    : > "$ipmap"
    [ -f "$IP_HOSTS_FILE" ] && awk -F'\t' '$1 != "" && $2 != "" && !($1 in s) { s[$1] = 1; print $1 "\t" tolower($2) }' "$IP_HOSTS_FILE" > "$ipmap"
    # endpoint -> its address(es): fills the Outgoing connections IP column for
    # endpoints configured by NAME (ip-hosts.tsv, columns swapped)
    local fwdmap; fwdmap=$(mktemp "${TMPDIR:-/tmp}/wlfwd.XXXXXX")
    : > "$fwdmap"
    [ -f "$IP_HOSTS_FILE" ] && awk -F'\t' '$1 != "" && $2 != "" { print tolower($2) "\t" $1 }' "$IP_HOSTS_FILE" > "$fwdmap"
    local gwf="$CONFIG_BASE/_white.tsv"; [ -f "$gwf" ] || gwf=/dev/null
    local ghf="$CONFIG_BASE/_hosts.tsv"; [ -f "$ghf" ] || ghf=/dev/null
    local hcaches=() hc
    for hc in _accounts-hosts _subscriptions-hosts _logins-hosts \
              _logicals-hosts _partners-hosts _apps-hosts _domains-hosts _bl-hosts; do
        [ -f "$CONFIG_XREF/$hc.tsv" ] && hcaches+=("$CONFIG_XREF/$hc.tsv")
    done
    awk -F'\t' -v IPMAP="$ipmap" -v FWDMAP="$fwdmap" -v GWF="$gwf" -v GHF="$ghf" -v SPMAP="$SP_MAP" -v APMAP="$AP_MAP" -v PLMAP="$PL_MAP" -v SLGMAP="$SLG_MAP" -v BLMAP="$BL_MAP" "$SP_AWK"'
        function isip(v){ return v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ }
        function pad(ip,   o){ split(ip, o, "."); return sprintf("%03d%03d%03d%03d", o[1], o[2], o[3], o[4]) }
        # SORT KEY ONLY (field 4; the displayed cells are ipc/nmc). A hostname
        # key folds _ onto - so the two separator spellings of one name sort as
        # neighbours, matching the client-side sort in report.js. Case is left
        # alone: this merges the -/_ distinction and changes nothing else.
        function skey(v,   k){ if (isip(v)) return pad(v); k=v; gsub(/_/,"-",k); return k }
        function wlx(t,   k){ k = t SUBSEP toupper($1); W[k] = W[k] "\t" $2; if (!(k in CN)) CN[k] = $1 }
        function hx(t,    k){ k = t SUBSEP toupper($1); WH[k] = WH[k] "\t" $2; if (!(k in CN)) CN[k] = $1 }
        # one File: bump the (type, entity, address) movement counters for its
        # connection side (I = a file entered us, O = one left us)
        function obs(t, e,   k){ if (e == "") return
            k = t SUBSEP toupper(e) SUBSEP ip
            if (!(k in TT)) { TT[k] = 0; OK[t SUBSEP toupper(e)] = e }
            TT[k]++
            if (mv == "in") CI[k]++; else if (mv == "out") CO[k]++ }
        function obso(t, e,   k){ if (e == "") return
            k = t SUBSEP toupper(e) SUBSEP ip
            if (!(k in TT2)) { TT2[k] = 0; OK[t SUBSEP toupper(e)] = e }
            TT2[k]++
            if (mv == "in") CI2[k]++; else if (mv == "out") CO2[k]++ }
        # a row: empty In/Out/Name use the "-" sentinel (the writer reads TABs
        # with `read -a`, which collapses empty fields). Column 1 is always the
        # IP, the last column the NAME: an IP value shows its configured endpoint,
        # a NAMED endpoint (2.7) shows its forward-resolved A record(s) as the
        # IP and itself as the Name.
        function emitrow(sec, t, nm, hv, i2, o2, tt, cfg,   res, ipc, nmc){
            if (cfg) res = (tt > 0) ? "green" : "orange"
            else     res = "red"                       # observed-only: always has traffic
            # a whitelisted IP sighted ONLY in the server log keeps the site-
            # wide blue tint (base _white.tsv result; a blue IP has no traffic
            # by definition, so it never displaces a green) — and blue rows do
            # not fold behind the orange no-traffic summary row
            if (sec == "2.6" && res == "orange" && (hv in GB)) res = "blue"
            if (isip(hv)) { ipc = hv; nmc = (hv in rev ? rev[hv] : "-") }
            else          { ipc = (tolower(hv) in fwd ? fwd[tolower(hv)] : "-"); nmc = hv }
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", t, nm, sec, skey(hv), ipc, \
                   (i2 > 0 ? i2 : "-"), (o2 > 0 ? o2 : "-"), nmc, res }
        FILENAME == IPMAP                       { rev[$1] = $2; next }
        # NOTE mawk mis-parses the ternary-in-concat form here (a leading ", "
        # appeared on the first A record); the explicit if/else is unambiguous.
        FILENAME == FWDMAP                      { if ($1 in fwd) fwd[$1] = fwd[$1] ", " $2; else fwd[$1] = $2; next }
        FILENAME == GWF                         { if ($1 != "") { GW[$1] = 1; if ($3 == "blue") GB[$1] = 1 }; next }   # the GLOBAL expanded whitelist (+ the server-log-only blues)
        FILENAME == GHF                         { if ($1 != "") { GH[tolower($1)] = 1
                                                    # a configured endpoint is its own HOST page outgoing entry
                                                    k = "4" SUBSEP toupper($1); WH[k] = WH[k] "\t" $1; if (!(k in CN)) CN[k] = $1 }
                                                  next }
        FILENAME ~ /_accounts-white\.tsv$/      { wlx("1"); next }
        FILENAME ~ /_subscriptions-white\.tsv$/ { wlx("2"); next }
        FILENAME ~ /_logins-white\.tsv$/        { wlx("3"); next }
        FILENAME ~ /_hosts-white\.tsv$/         { wlx("4"); next }
        FILENAME ~ /_partners-white\.tsv$/      { wlx("6"); next }
        FILENAME ~ /_apps-white\.tsv$/          { wlx("7"); next }
        FILENAME ~ /_domains-white\.tsv$/       { wlx("8"); next }
        FILENAME ~ /_logicals-white\.tsv$/      { wlx("9"); next }
        FILENAME ~ /_bl-white\.tsv$/            { wlx("10"); next }
        FILENAME ~ /_accounts-hosts\.tsv$/      { hx("1"); next }
        FILENAME ~ /_subscriptions-hosts\.tsv$/ { hx("2"); next }
        FILENAME ~ /_logins-hosts\.tsv$/        { hx("3"); next }
        FILENAME ~ /_partners-hosts\.tsv$/      { hx("6"); next }
        FILENAME ~ /_apps-hosts\.tsv$/          { hx("7"); next }
        FILENAME ~ /_domains-hosts\.tsv$/       { hx("8"); next }
        FILENAME ~ /_logicals-hosts\.tsv$/      { hx("9"); next }
        FILENAME ~ /_bl-hosts\.tsv$/            { hx("10"); next }
        FILENAME ~ /_files\.tsv$/ {   # $FILES: the logged PDA + Logical attributions ...
            nu6 = split(sp_union($20, $12), PU6, "\037")   # partner / application / logical = the UNION sets
            for (iu6 = 1; iu6 <= nu6; iu6++) seen["6" SUBSEP toupper(PU6[iu6])] = PU6[iu6]
            na6 = split(ap_union($18, $12), AU6, "\037")
            for (iu6 = 1; iu6 <= na6; iu6++) seen["7" SUBSEP toupper(AU6[iu6])] = AU6[iu6]
            nl6 = split(lg_union($13, $12), LU6, "\037")
            for (iu6 = 1; iu6 <= nl6; iu6++) seen["9" SUBSEP toupper(LU6[iu6])] = LU6[iu6]
            nb6 = split(bl_union($12), BU6, "\037")
            for (iu6 = 1; iu6 <= nb6; iu6++) seen["10" SUBSEP toupper(BU6[iu6])] = BU6[iu6]
            if ($19 != "") seen["8" SUBSEP toupper($19)] = $19
            # ... and the OBSERVED addresses per entity and connection side
            # (col 16), split by movement (col 17)
            if ($15 != "") {
                ip = $15; mv = $17
                if ($16 == "in") {
                    # NO obs("4", $15) here: on an incoming file col 15 is the
                    # SOURCE address, and attributing it to a HOST entity named
                    # by itself materialized a phantom never-seen host page per
                    # inbound IP — HOST entities are OUTBOUND endpoints only
                    # (the partners.json host fields + the endpoints we dial)
                    obs("1", $3); obs("2", $12); obs("3", $14)
                    for (iu6 = 1; iu6 <= nu6; iu6++) obs("6", PU6[iu6])
                    for (iu6 = 1; iu6 <= na6; iu6++) obs("7", AU6[iu6]); obs("8", $19)
                    for (iu6 = 1; iu6 <= nl6; iu6++) obs("9", LU6[iu6])
                    for (iu6 = 1; iu6 <= nb6; iu6++) obs("10", BU6[iu6])
                } else if ($16 == "out") {
                    obso("1", $3); obso("2", $12); obso("3", $14); obso("4", $15)
                    for (iu6 = 1; iu6 <= nu6; iu6++) obso("6", PU6[iu6])
                    for (iu6 = 1; iu6 <= na6; iu6++) obso("7", AU6[iu6]); obso("8", $19)
                    for (iu6 = 1; iu6 <= nl6; iu6++) obso("9", LU6[iu6])
                    for (iu6 = 1; iu6 <= nb6; iu6++) obso("10", BU6[iu6])
                }
            }
            next
        }
        {   # $PARSED: remember each logged entity value under its type
            if ($4  != "") seen["1" SUBSEP toupper($4)]  = $4
            if ($6  != "") seen["2" SUBSEP toupper($6)]  = $6
            if ($5  != "") seen["3" SUBSEP toupper($5)]  = $5
            if ($16 != "") seen["4" SUBSEP toupper($16)] = $16
        }
        END {
            # EVERY configured entity with whitelist/endpoint entries emits
            # rows — the logged spelling when seen, the config spelling
            # otherwise — then every OBSERVED (entity, address) pair not
            # already covered (red: traffic outside the configuration).
            # Emission order is hash order, but the caller sorts the stream on
            # (type, entity, section, sortkey), so the output is deterministic.
            T[1]="ACC"; T[2]="SITE"; T[3]="LOGIN"; T[4]="HOST"; T[6]="PTN"; T[7]="APP"; T[8]="DOM"; T[9]="LGC"; T[10]="BL"
            for (k in W) {          # 2.6 Incoming: the configured whitelist ...
                nm = (k in seen) ? seen[k] : CN[k]
                split(k, a, SUBSEP)
                n = split(substr(W[k], 2), ips, "\t")
                for (i = 1; i <= n; i++) {
                    ck = k SUBSEP ips[i]; done[ck] = 1
                    emitrow("2.6", T[a[1]+0], nm, ips[i], CI[ck]+0, CO[ck]+0, TT[ck]+0, (ips[i] in GW))
                }
            }
            for (ck in TT) {        # ... plus the observed incoming sources
                if (ck in done) continue
                split(ck, a, SUBSEP)
                ek = a[1] SUBSEP a[2]
                nm = (ek in seen) ? seen[ek] : OK[ek]
                emitrow("2.6", T[a[1]+0], nm, a[3], CI[ck]+0, CO[ck]+0, TT[ck]+0, (a[3] in GW))
            }
            for (k in WH) {         # 2.7 Outgoing: the configured endpoints ...
                nm = (k in seen) ? seen[k] : CN[k]
                split(k, a, SUBSEP)
                n = split(substr(WH[k], 2), hs, "\t")
                for (i = 1; i <= n; i++) {
                    ck = k SUBSEP hs[i]
                    if (ck in done2) continue
                    done2[ck] = 1
                    emitrow("2.7", T[a[1]+0], nm, hs[i], CI2[ck]+0, CO2[ck]+0, TT2[ck]+0, (tolower(hs[i]) in GH))
                }
            }
            for (ck in TT2) {       # ... plus the observed outgoing hosts
                if (ck in done2) continue
                split(ck, a, SUBSEP)
                ek = a[1] SUBSEP a[2]
                nm = (ek in seen) ? seen[ek] : OK[ek]
                emitrow("2.7", T[a[1]+0], nm, a[3], CI2[ck]+0, CO2[ck]+0, TT2[ck]+0, (tolower(a[3]) in GH))
            }
        }
    ' "$ipmap" "$fwdmap" "$gwf" "$ghf" "$CONFIG_XREF/_accounts-white.tsv" "$CONFIG_XREF/_subscriptions-white.tsv" \
      "$CONFIG_XREF/_logins-white.tsv" "$CONFIG_XREF/_hosts-white.tsv" \
      "$CONFIG_XREF/_logicals-white.tsv" "$CONFIG_XREF/_partners-white.tsv" \
      "$CONFIG_XREF/_apps-white.tsv" "$CONFIG_XREF/_domains-white.tsv" \
      "$CONFIG_XREF/_bl-white.tsv" \
      "${hcaches[@]}" "$FILES" "$PARSED"
    rm -f "$ipmap" "$fwdmap"
}

# ===== configured cross-reference rows (sections 2 / 2.8 / 2.81 / 2.82) ==========
# The entity-dimension tables cross-reference the FlowManager configuration:
# after the logged rows of an entity section, one extra row is inserted for
# every partner CONFIGURED for the page's entity (bin/flow-manager.sh's
# _<item>-<item>.tsv pair caches) that never appears in the logs with it. The
# writer tags every section 2-6 row @data:seen (1 = logged data, 0 = config
# only) and the table `seenrows`, so style.css tints rows green/red by
# data-presence and report.js re-tints them for a narrowed date range.
# Config-only rows render unlinked (no detail page exists for a never-logged
# name). Matching mirrors showseen.sh: exact name match, case aside, except a
# configured subscription name matches any logged site value it prefixes. A
# missing pair cache just skips that pair; with no caches this is a plain cat.
# Runs on the sorted agg stream.
insert_config_rows() {
    local caches=() f
    for f in _accounts-subscriptions _accounts-logins _accounts-hosts \
             _subscriptions-logins _subscriptions-hosts \
             _logins-hosts \
             _partners-accounts _partners-subscriptions _partners-logins _partners-hosts \
             _partners-domains _partners-apps _apps-domains _apps-partners _domains-apps _domains-partners \
             _apps-accounts _apps-subscriptions _apps-logins _apps-hosts \
             _domains-accounts _domains-subscriptions _domains-logins _domains-hosts \
             _logicals-accounts _logicals-subscriptions _logicals-logins _logicals-hosts \
             _logicals-domains _logicals-apps _logicals-partners \
             _partners-logicals _apps-logicals _domains-logicals \
             _bl-accounts _bl-subscriptions _bl-logins _bl-hosts \
             _bl-domains _bl-apps _bl-logicals _bl-partners \
             _partners-bl _apps-bl _domains-bl _logicals-bl \
             _accounts-domains _accounts-apps _accounts-logicals _accounts-partners _accounts-bl; do
        [ -f "$CONFIG_XREF/$f.tsv" ] && caches+=("$CONFIG_XREF/$f.tsv")
    done
    if [ ${#caches[@]} -eq 0 ]; then cat; return 0; fi
    awk -F'\t' -v SUBRES="$CONFIG_BASE/_subscriptions.tsv" -v ACCRES="$CONFIG_BASE/_accounts.tsv" -v FLOWDF="$CONFIG_XREF/_subscriptions-flowdir.tsv" \
        -v DOMB="$CONFIG_BASE/_domains.tsv" -v APPB="$CONFIG_BASE/_apps.tsv" -v PTNB="$CONFIG_BASE/_partners.tsv" -v LGB="$CONFIG_BASE/_logicals.tsv" -v BLB="$CONFIG_BASE/_bl.tsv" '
        BEGIN { US = sprintf("%c", 31); od["ACC"]=2.8; od["SITE"]=2; od["LOGIN"]=3; od["HOST"]=4; od["BL"]=2.85
                # section 4 (Remote Host dim) is GONE — the Outgoing connections
                # table (2.7, whitelist_rows) covers the configured endpoints
                # 2.81-2.84 = the Logical+PDA quad pages'"'"' Domain /
                # Application / Logical / Partner tables (only LGC/PTN/APP/DOM
                # entities register CP pairs for those sections, so the flush
                # is a no-op on every other page type)
                # 3 and 4 (Logins / Hosts) flush on the LOGICAL+PDA pages ONLY
                # (2026-08-29, the flushsec gate): the classic pages carry
                # their logins/hosts in Features (ACC) or the connection
                # tables, and the section-4 removal note above still holds
                # for them — the quad pages had NO login/host view at all.
                nsec = split("2 2.8 2.81 2.82 2.83 2.84 2.85 3 4", SECS, " "); for (i = 1; i <= nsec; i++) ISSEC[SECS[i]+0] = 1
                # subscription -> RESULT color (base cache col 3) for the
                # section-2 color ordering, + its CONNECTION side (col 2) for
                # the Direction column
                while ((getline l5 < SUBRES) > 0) { n5 = split(l5, a5, "\t"); if (n5 >= 3) { RES[toupper(a5[1])] = a5[3]; SDIR[toupper(a5[1])] = a5[2]; RESN[++nres] = toupper(a5[1]) } } close(SUBRES)
                # account -> RESULT color (same treatment for the Account dim)
                while ((getline l5 < ACCRES) > 0) { n5 = split(l5, a5, "\t"); if (n5 >= 3) ARES[toupper(a5[1])] = a5[3] } close(ACCRES)
                # domain / application / logical / partner -> RESULT color: the
                # quad pages Domain (2.81) / Application (2.82) / Logical (2.83)
                # / Partner (2.84) tables tint the WHOLE row by it
                while ((getline l5 < DOMB) > 0) { n5 = split(l5, a5, "\t"); if (n5 >= 3) DRES[toupper(a5[1])] = a5[3] } close(DOMB)
                while ((getline l5 < APPB) > 0) { n5 = split(l5, a5, "\t"); if (n5 >= 3) PRES[toupper(a5[1])] = a5[3] } close(APPB)
                while ((getline l5 < PTNB) > 0) { n5 = split(l5, a5, "\t"); if (n5 >= 3) TRES[toupper(a5[1])] = a5[3] } close(PTNB)
                while ((getline l5 < LGB)  > 0) { n5 = split(l5, a5, "\t"); if (n5 >= 3) LRES[toupper(a5[1])] = a5[3] } close(LGB)
                while ((getline l5 < BLB)  > 0) { n5 = split(l5, a5, "\t"); if (n5 >= 3) BRES[toupper(a5[1])] = a5[3] } close(BLB)
                # subscription -> FILE-MOVEMENT direction (out|in|relay)
                while ((getline l5 < FLOWDF) > 0) { if (split(l5, a5, "\t") >= 2) FLOWD[toupper(a5[1])] = a5[2] } close(FLOWDF)
                OFS = "\t" }   # section-2/2.8 lines get their $4 rewritten below
        # The Subscription Direction cell — "IN/OUT" etc., the page-title
        # XXX/YYY convention: connection side / file movement, both|relay ->
        # BOTH, unknown -> "?". Resolved via the config name (exact, else the
        # showseen prefix rule), cached per value.
        function dlab(v) { return v=="in" ? "IN" : v=="out" ? "OUT" : (v=="both" || v=="relay") ? "BOTH" : "?" }
        # THE PREFIX RULE, bounded (2026-08-31 audit): a configured name c
        # stands for a logged value u only when u continues past c at a
        # NAME-PART BOUNDARY (a non-alphanumeric character — a tail the parse
        # did not strip), never mid-name: UC1_FIN_BILLING_GLOBEX is NOT a
        # match for UC1_FIN_BILLING_GLOBEXX, nor UC4_ODV_ARE_APERTURE for
        # …APERTURE2 — those are different flows, and the unbounded rule
        # stamped the shorter flow'\''s accounts, logins, hosts and partners
        # onto the longer flow'\''s page as configured rows.
        function pfxok(u, c) { return (index(u, c) == 1 && substr(u, length(c) + 1, 1) !~ /[A-Za-z0-9]/) }
        function subpfx(nm,   u, i, c) {
            u = toupper(nm)
            if (u in PFC) return PFC[u]
            c = ""
            if (u in SDIR) c = u
            else for (i = 1; i <= nres; i++) if (pfxok(u, RESN[i])) { c = RESN[i]; break }
            PFC[u] = (c == "") ? "?/?" : dlab(SDIR[c]) "/" dlab(FLOWD[c])
            return PFC[u]
        }
        # The Account dim (section 2.8) sortkey payload — "A|<res>|<logins>|<hosts>":
        # the account result color plus its configured login(s) and host(s)
        # (the _accounts-logins/_accounts-hosts pair maps, already loaded as
        # CP), for the writer Login / Host columns. Multi-values join ", "
        # (a multi-value cell simply renders unlinked — no slugmap match).
        function accf4(nm,   u, lg, hs, r5) {
            u = toupper(nm)
            lg = CP["ACC" SUBSEP u SUBSEP 3]; gsub(US, ", ", lg)
            hs = CP["ACC" SUBSEP u SUBSEP 4]; gsub(US, ", ", hs)
            r5 = (u in ARES) ? ARES[u] : ""
            return "A|" r5 "|" lg "|" hs
        }
        # The Domain (2.81) / Application (2.82) / Logical (2.83) / Partner
        # (2.84) payload on the quad pages: the item base-cache RESULT color,
        # bare — the writer turns it into the whole-row @data:res tint (with
        # the restint table modifier). An unknown item keeps the decorative
        # "z"+name payload (no tint).
        function pdares(s, nm,   u, r) {
            u = toupper(nm); r = (s == 2.81) ? DRES[u] : (s == 2.82) ? PRES[u] : (s == 2.83) ? LRES[u] : (s == 2.85) ? BRES[u] : TRES[u]
            return (r == "") ? "z" nm : r
        }
        # The subscription RESULT color, resolved via the config name (exact,
        # else the showseen prefix rule), cached per value. "" when unknown.
        # Rides the "S|<direction>|<res>" payload into the writer, which turns
        # it into the whole-row @data:res tint (the restint table modifier).
        function subres(nm,   u, i, r) {
            u = toupper(nm)
            if (u in SRC) return SRC[u]
            r = ""
            if (u in RES) r = RES[u]
            else for (i = 1; i <= nres; i++) if (pfxok(u, RESN[i])) { r = RES[RESN[i]]; break }
            SRC[u] = r; return r
        }
        # The Subscription table (section 2) is ordered by the subscription
        # RESULT color — red, green, blue, orange (unknown last) — logged and
        # config-only rows TOGETHER; within one color the original order holds
        # (logged by count, then the appended config rows by name). All its
        # rows are BUFFERED into per-rank buckets and dumped when the section
        # completes.
        function subrank(nm,   u, r) {
            u = toupper(nm)
            if (u in RKC) return RKC[u]
            r = subres(nm)
            r = (r == "red" ? 0 : r == "green" ? 1 : r == "blue" ? 2 : r == "orange" ? 3 : 4)
            RKC[u] = r; return r
        }
        function bucket2(nm, line,   r) { r = subrank(nm); B2[r, ++B2n[r]] = line }
        function dump2(   r, i) { for (r = 0; r <= 4; r++) { for (i = 1; i <= B2n[r]; i++) print B2[r, i]; B2n[r] = 0 } }
        # CP[type SUBSEP NAME SUBSEP dimsec] = US-joined configured partner names
        function addcp(t, n, s, p,   k) {
            k = t SUBSEP toupper(n) SUBSEP s
            if (++cpseen[k SUBSEP toupper(p)] > 1) return
            CP[k] = (CP[k] == "" ? p : CP[k] US p)
            if (t == "SITE" && !(toupper(n) in subseen)) { subseen[toupper(n)] = 1; SUBS[++nsubs] = toupper(n) }
        }
        function pair(t1, s1, t2, s2) { addcp(t1, $1, s2, $2); addcp(t2, $2, s1, $1) }
        # The configured partners of page entity e (type t) for dim section s.
        # A SITE page also merges every configured sub name that PREFIXES the
        # logged site value at a name-part boundary (pfxok — showseen.sh
        # rule; usually the exact match already hit).
        function partners(t, e, s,   u, res, i, x) {
            u = toupper(e); res = CP[t SUBSEP u SUBSEP s]
            if (t != "SITE") return res
            for (i = 1; i <= nsubs; i++) {
                if (SUBS[i] == u || !pfxok(u, SUBS[i])) continue
                x = CP["SITE" SUBSEP SUBS[i] SUBSEP s]
                if (x != "") res = (res == "" ? x : res US x)
            }
            return res
        }
        # Was configured partner p logged with this page (dim section s)? Dim 2
        # (subscription) uses the bounded prefix rule against the logged site values.
        function isseen(s, p,   u, i, n, arr) {
            u = toupper(p)
            if (s != 2) return (s SUBSEP u) in seen
            n = split(L3, arr, US)
            for (i = 1; i <= n; i++) if (arr[i] == u || pfxok(arr[i], u)) return 1
            return 0
        }
        # Emit the not-seen configured partners of section s, name-sorted. The
        # 5-field line (empty count field) is the writer'\''s config-row marker.
        function flushsec(t, e, s,   plist, n, arr, i, j, u, ku, m, M, MK, MU) {
            if (s == od[t]) return
            if ((s == 3 || s == 4) && t != "PTN" && t != "APP" && t != "DOM" && t != "LGC" && t != "BL" && t != "ACC") return   # Logins/Hosts tables: Logical+PDA+BL+Account pages
            plist = partners(t, e, s); if (plist == "") return
            n = split(plist, arr, US); m = 0
            for (i = 1; i <= n; i++) {
                u = toupper(arr[i])
                # ORDER on the separator-folded name so the two spellings of one
                # name are neighbours (report.js sorts the same way when you
                # click the column); the raw name breaks the tie so the order
                # stays total. DEDUP still keys on the RAW name: separator twins
                # are different entities and both get a row.
                ku = u; gsub(/_/, "-", ku)
                if (u in MU) continue
                MU[u] = 1                                  # dedup (the SITE prefix merge can repeat one)
                if (isseen(s, arr[i])) continue
                for (j = m; j >= 1 && (MK[j] > ku || (MK[j] == ku && toupper(M[j]) > u)); j--) { M[j+1] = M[j]; MK[j+1] = MK[j] }
                M[j+1] = arr[i]; MK[j+1] = ku; m++
            }
            for (i = 1; i <= m; i++) {
                # the sortkey field is decorative here (the stream is already
                # sorted); Account (sec 2.8) rows repurpose it to carry the
                # "A|res|logins|hosts" payload, Subscription (sec 2) rows the
                # "S|<direction>" payload, for the writer
                f4 = "z" M[i]
                if (s == 2.8) f4 = accf4(M[i])
                if (s == 2)  f4 = "S|" subpfx(M[i]) "|" subres(M[i])
                if (s == 2.81 || s == 2.82 || s == 2.83 || s == 2.84 || s == 2.85) f4 = pdares(s, M[i])
                cline = sprintf("%s\t%s\t%s\t%s\t%s", t, e, s, f4, M[i])
                if (s == 2) bucket2(M[i], cline); else print cline
            }
        }
        function endflush(t, e,   i2, s) { if (t == "") return; for (i2 = 1; i2 <= nsec; i2++) { s = SECS[i2]+0; if (!flushed[s]) { flushed[s] = 1; flushsec(t, e, s); if (s == 2) dump2() } } }
        FILENAME ~ /_accounts-subscriptions\.tsv$/ { pair("ACC",2.8,"SITE",2);   next }
        FILENAME ~ /_accounts-logins\.tsv$/        { pair("ACC",2.8,"LOGIN",3);  next }
        FILENAME ~ /_accounts-hosts\.tsv$/         { pair("ACC",2.8,"HOST",4);   next }
        FILENAME ~ /_subscriptions-logins\.tsv$/   { pair("SITE",2,"LOGIN",3);  next }
        FILENAME ~ /_subscriptions-hosts\.tsv$/    { pair("SITE",2,"HOST",4);   next }
        FILENAME ~ /_logins-hosts\.tsv$/           { pair("LOGIN",3,"HOST",4);  next }
        # PDA pages get the same entity config sections (one-way: the classic
        # pages carry no partner/application/domain dimension of their own).
        FILENAME ~ /_partners-accounts\.tsv$/      { addcp("PTN",$1,2.8,$2); next }
        FILENAME ~ /_partners-subscriptions\.tsv$/ { addcp("PTN",$1,2,$2);  next }
        FILENAME ~ /_partners-logins\.tsv$/        { addcp("PTN",$1,3,$2);  next }
        FILENAME ~ /_partners-hosts\.tsv$/         { addcp("PTN",$1,4,$2);  next }
        # the quad pages'\'' Domain (2.81) / Application (2.82) / Logical (2.83)
        # / Partner (2.84) tables list ALL config-connected values (config-only
        # ones as never-logged rows, tinted by the item RESULT)
        FILENAME ~ /_partners-domains\.tsv$/       { addcp("PTN",$1,2.81,$2); next }
        FILENAME ~ /_partners-apps\.tsv$/          { addcp("PTN",$1,2.82,$2); next }
        FILENAME ~ /_partners-logicals\.tsv$/      { addcp("PTN",$1,2.83,$2); next }
        FILENAME ~ /_apps-domains\.tsv$/           { addcp("APP",$1,2.81,$2); next }
        FILENAME ~ /_apps-partners\.tsv$/          { addcp("APP",$1,2.84,$2); next }
        FILENAME ~ /_apps-logicals\.tsv$/          { addcp("APP",$1,2.83,$2); next }
        FILENAME ~ /_domains-apps\.tsv$/           { addcp("DOM",$1,2.82,$2); next }
        FILENAME ~ /_domains-partners\.tsv$/       { addcp("DOM",$1,2.84,$2); next }
        FILENAME ~ /_domains-logicals\.tsv$/       { addcp("DOM",$1,2.83,$2); next }
        FILENAME ~ /_apps-accounts\.tsv$/          { addcp("APP",$1,2.8,$2); next }
        FILENAME ~ /_apps-subscriptions\.tsv$/     { addcp("APP",$1,2,$2);  next }
        FILENAME ~ /_apps-logins\.tsv$/            { addcp("APP",$1,3,$2);  next }
        FILENAME ~ /_apps-hosts\.tsv$/             { addcp("APP",$1,4,$2);  next }
        FILENAME ~ /_domains-accounts\.tsv$/       { addcp("DOM",$1,2.8,$2); next }
        FILENAME ~ /_domains-subscriptions\.tsv$/  { addcp("DOM",$1,2,$2);  next }
        FILENAME ~ /_domains-logins\.tsv$/         { addcp("DOM",$1,3,$2);  next }
        FILENAME ~ /_domains-hosts\.tsv$/          { addcp("DOM",$1,4,$2);  next }
        # the LOGICAL pages'\'' own config sections (one-way, like the PDA rules)
        FILENAME ~ /_logicals-accounts\.tsv$/      { addcp("LGC",$1,2.8,$2); next }
        FILENAME ~ /_logicals-subscriptions\.tsv$/ { addcp("LGC",$1,2,$2);  next }
        FILENAME ~ /_logicals-logins\.tsv$/        { addcp("LGC",$1,3,$2);  next }
        FILENAME ~ /_logicals-hosts\.tsv$/         { addcp("LGC",$1,4,$2);  next }
        FILENAME ~ /_logicals-domains\.tsv$/       { addcp("LGC",$1,2.81,$2); next }
        FILENAME ~ /_logicals-apps\.tsv$/          { addcp("LGC",$1,2.82,$2); next }
        FILENAME ~ /_logicals-partners\.tsv$/      { addcp("LGC",$1,2.84,$2); next }
        # the BL pages'"'"' own config sections + the other quad pages'"'"' BL
        # section (2.85) — the same one-way pattern
        FILENAME ~ /_bl-accounts\.tsv$/            { addcp("BL",$1,2.8,$2); next }
        FILENAME ~ /_bl-subscriptions\.tsv$/       { addcp("BL",$1,2,$2);  next }
        FILENAME ~ /_bl-logins\.tsv$/              { addcp("BL",$1,3,$2);  next }
        FILENAME ~ /_bl-hosts\.tsv$/               { addcp("BL",$1,4,$2);  next }
        FILENAME ~ /_bl-domains\.tsv$/             { addcp("BL",$1,2.81,$2); next }
        FILENAME ~ /_bl-apps\.tsv$/                { addcp("BL",$1,2.82,$2); next }
        FILENAME ~ /_bl-logicals\.tsv$/            { addcp("BL",$1,2.83,$2); next }
        FILENAME ~ /_bl-partners\.tsv$/            { addcp("BL",$1,2.84,$2); next }
        FILENAME ~ /_partners-bl\.tsv$/            { addcp("PTN",$1,2.85,$2); next }
        FILENAME ~ /_apps-bl\.tsv$/                { addcp("APP",$1,2.85,$2); next }
        FILENAME ~ /_domains-bl\.tsv$/             { addcp("DOM",$1,2.85,$2); next }
        FILENAME ~ /_logicals-bl\.tsv$/            { addcp("LGC",$1,2.85,$2); next }
        # the ACCOUNT pages'"'"' own quad sections (2026-08-31, user request:
        # accounts render their dims like the Logical+PDA pages)
        FILENAME ~ /_accounts-domains\.tsv$/       { addcp("ACC",$1,2.81,$2); next }
        FILENAME ~ /_accounts-apps\.tsv$/          { addcp("ACC",$1,2.82,$2); next }
        FILENAME ~ /_accounts-logicals\.tsv$/      { addcp("ACC",$1,2.83,$2); next }
        FILENAME ~ /_accounts-partners\.tsv$/      { addcp("ACC",$1,2.84,$2); next }
        FILENAME ~ /_accounts-bl\.tsv$/            { addcp("ACC",$1,2.85,$2); next }
        {   # the sorted agg stream: insert each section'\''s config rows when the
            # stream moves past it (all its logged rows are collected by then)
            t = $1; e = $2; s3 = $3 + 0
            if (t != curt || e != cure) { endflush(curt, cure); curt = t; cure = e; split("", seen); split("", flushed); L3 = "" }
            for (i2 = 1; i2 <= nsec; i2++) { s = SECS[i2]+0; if (s >= s3) continue; if (!flushed[s]) { flushed[s] = 1; flushsec(t, e, s); if (s == 2) dump2() } }
            if (s3 in ISSEC) { seen[s3 SUBSEP toupper($5)] = 1; if (s3 == 2) L3 = (L3 == "" ? toupper($5) : L3 US toupper($5)) }
            if (s3 == 2.8) $4 = accf4($5)   # logged Account rows get the Login/Host payload too (OFS is TAB)
            if (s3 == 2)  $4 = "S|" subpfx($5) "|" subres($5)   # logged Subscription rows: Direction + row-tint color
            if ((s3 == 2.81 || s3 == 2.82 || s3 == 2.83 || s3 == 2.84 || s3 == 2.85) && (t == "PTN" || t == "APP" || t == "DOM" || t == "LGC" || t == "BL" || t == "ACC")) $4 = pdares(s3, $5)   # logged quad-dim rows on the quad+Account pages: the row-tint color
            if (s3 == 2) bucket2($5, $0); else print
        }
        END { endflush(curt, cure) }
    ' "${caches[@]}" -
}

# ===== files unit: distinct Files from _files.tsv, grouped over rows ===
# One logical transfer (CoreId) counts once per entity it touches. Account
# comes from _files.tsv (its collapsed account); login, site
# and host are the DISTINCT values across the CoreId'\''s rows. Breakdowns count
# distinct Files per (entity, dimension, value): within a CoreId'\''s row group
# each dimension value is taken once. Rows are CoreId-contiguous (the cache is
# CoreId-sorted), so a group is flushed at each CoreId boundary — memory-bounded.
aggregate_files() {
  awk -F'\t' -v SPMAP="$SP_MAP" -v APMAP="$AP_MAP" -v PLMAP="$PL_MAP" -v SLGMAP="$SLG_MAP" -v BLMAP="$BL_MAP" "$SP_AWK$COREIDS_AWK"'
    function human(b,   u,i,v){ split("B KB MB GB TB PB",u," "); i=1; v=b+0; while(v>=1024&&i<6){v/=1024;i++} return (i==1)?sprintf("%d %s",v,u[i]):sprintf("%.2f %s",v,u[i]) }
    function humandur(ms){ if(ms<1000) return sprintf("%d ms",ms); if(ms<60000) return sprintf("%.2f s",ms/1000); if(ms<3600000) return sprintf("%.1f min",ms/60000); return sprintf("%.2f h",ms/3600000) }
    function thr(bytes,ms){ return ms>0 ? human(bytes*1000/ms) "/s" : "-" }
    function inv(c){ return sprintf("%012d", 1000000000 - c) }
    function jdnum(y,m,dd,   a) { a=int((14-m)/12); y=y+4800-a; m=m+12*a-3; return dd+int((153*m+2)/5)+365*y+int(y/4)-int(y/100)+int(y/400)-32045 }
    # epoch-second helpers for the store-and-forward dwell (dwell-time.sh twins)
    function secs5(t,  p5){ if (split(t, p5, ":") < 3) return -1; return p5[1]*3600 + p5[2]*60 + p5[3] }
    function ep_iso(di, t,  p5, s5){ if (split(di, p5, "-") < 3) return -1; s5=secs5(t); if (s5<0) return -1; return jdnum(p5[1]+0,p5[2]+0,p5[3]+0)*86400 + s5 }
    function ep_us(x,  a5, dp5, s5){ if (split(x, a5, " ") < 2) return -1; if (split(a5[1], dp5, "/") < 3) return -1; s5=secs5(a5[2]); if (s5<0) return -1; return jdnum(dp5[3]+0,dp5[1]+0,dp5[2]+0)*86400 + s5 }
    function fromjdn(j,   a,b,c,dd,e2,mm,day2,mon,yr) { a=j+32044; b=int((4*a+3)/146097); c=a-int(146097*b/4); dd=int((4*c+3)/1461); e2=c-int(1461*dd/4); mm=int((5*e2+2)/153); day2=e2-int((153*mm+2)/5)+1; mon=mm+3-12*int(mm/10); yr=100*b+dd-4800+int(mm/10); return sprintf("%04d-%02d-%02d", yr, mon, day2) }
    function wkkey(jd,   thu,yy) { thu = jd - (jd % 7) + 3; split(fromjdn(thu), yy, "-"); return sprintf("%04d%02d", yy[1], int((thu - jdnum(yy[1]+0,1,1)) / 7) + 1) }
    function qsort(A, lo, hi,   i, j, p2, t) {
        while (lo < hi) {
            i = lo; j = hi; p2 = A[int((lo + hi) / 2)]
            while (i <= j) { while (A[i] < p2) i++; while (A[j] > p2) j--; if (i <= j) { t = A[i]; A[i] = A[j]; A[j] = t; i++; j-- } }
            if (j - lo < hi - i) { if (lo < j) qsort(A, lo, j); lo = i } else { if (i < hi) qsort(A, i, hi); hi = j }
        }
    }
    function medgap(e,   n,i,j,v,ng,D2,G2) {
      n=split(dstr[e],D2," "); if(n<=1) return "-"
      for(i=2;i<=n;i++){v=D2[i];j=i-1;while(j>=1&&D2[j]>v){D2[j+1]=D2[j];j--}D2[j+1]=v}
      ng=0; for(i=2;i<=n;i++){ng++;G2[ng]=D2[i]-D2[i-1]}
      for(i=2;i<=ng;i++){v=G2[i];j=i-1;while(j>=1&&G2[j]>v){G2[j+1]=G2[j];j--}G2[j+1]=v}
      if(ng%2) return sprintf("%.1f",G2[(ng+1)/2])
      return sprintf("%.1f",(G2[ng/2]+G2[ng/2+1])/2)
    }
    function perday(ty,ent,   k,kd,wk,wkd,hk,dk) { if(ent=="")return; k=ty SUBSEP ent; kd=k SUBSEP day; pdseen[kd]=1
      if(pr2){pdp[kd]++;ptp[k]++; if(gHADF)pdr[kd]++}else{pdf[kd]++;ptf[k]++}   # pdr = RECOVERED: an OK File that carried a failed leg
      pdb[kd]+=size; ptb[k]+=size; ptr[k]++; if(size>ptmx[k])ptmx[k]=size
      pddur[kd]+=dur2; ptdur[k]+=dur2   # duration sums -> the day table average Duration column (per day and page total)
      if(dio!=""){ ptD[k SUBSEP dio]++; pdD[kd SUBSEP dio]++ }
      adays[k SUBSEP jd]=1
      # (the Activity per week table — section 12, the wl/wb/wp/wf per-ISO-week
      # arrays — was REMOVED 2026-07; the day table + weekday/hour loads remain)
      # (the per-date *_d bucket twins are GONE — detail pages have no From/To,
      # so no @data:buckets payload is emitted any more, 2026-07)
      if(hh != ""){ hk=k SUBSEP hh; hl[hk]++; hb[hk]+=size; if(pr2)hp[hk]++; else hf[hk]++
                    if(dio!="") hD[hk SUBSEP dio]++ }
      dk=k SUBSEP (jd % 7); dl2[dk]++; db2[dk]+=size; if(pr2)dp3[dk]++; else df3[dk]++
      if(dio!="") dD[dk SUBSEP dio]++
      if(!(k in pmin)||sk<pmink[k]){pmink[k]=sk;pfirst[k]=disp;pmin[k]=1}
      if(!(k in pmax)||sk>pmaxk[k]){pmaxk[k]=sk;plast[k]=disp;pmaxjd[k]=jd;pmax[k]=1} }
    # Read wec[] WITHOUT creating the element: a bare wec[k] reference would
    # add an empty entry, and the "for (k in wec)" loop that builds the
    # section-0.9 table would then emit a phantom "Waiting files 0" row.
    function wecnt(kk){ return (kk in wec) ? wec[kk]+0 : 0 }
    function bump(ty,ent,dim,val,   key){ if(ent==""||val=="")return; key=ty SUBSEP ent SUBSEP dim SUBSEP val; bc[key]++; if(pr2)bp[key]++; else bf[key]++; bv[key]+=size
      addtop(key SUBSEP (pr2?"P":"F"), sk, disp, curcid)   # per (dim,value,outcome) drill: last 10 CoreIds
      # Waiting / Expired counted PER DIMENSION VALUE as well, so the
      # Subscription table (section 2) can show which UC2 subscription the
      # staged files belong to. These are a BREAKDOWN, not a third outcome: a
      # Waiting File is already in OK and an Expired one already in Error
      # (the site-wide outcome policy).
      if(toc[curcid]=="Waiting") bw[key]++
      else if(toc[curcid]=="Expired") be[key]++
      if(dio!="") bD[key SUBSEP dio]++ }
    # addbig: lib.sh addtop with a per-type bound and its own array — the
    # Latest Files list per entity, newest first (sortkey = date+time desc).
    # SITE keeps 500 (the subscription pages page through 25 at a time,
    # 2026-08); every other type keeps 100 — the bound also caps the string
    # re-join cost per insert, so widening it for all seven attributions
    # would multiply the aggregation cost across the board.
    function addbig(p, sk2, disp2, cid2, bnd,   key,n,a2,i,pos,m,out){ key=sk2 SUBSEP disp2 SUBSEP cid2
        if ((p in _bign) && _bign[p] >= bnd && key <= _bigmin[p]) return   # cheap reject, see lib.sh addtop
        n=(p in big)?split(big[p],a2,_US):0; pos=n+1
        for(i=1;i<=n;i++) if(key>a2[i]){pos=i;break}
        if(pos>bnd) return
        for(i=(n<bnd?n:bnd-1);i>=pos;i--) a2[i+1]=a2[i]
        a2[pos]=key; m=(n<bnd)?n+1:bnd; out=a2[1]; for(i=2;i<=m;i++) out=out _US a2[i]; big[p]=out
        _bign[p]=m; _bigmin[p]=a2[m] }
    function ent_apply(ty,ent,   dv,a2,k5,s9){ if(ent=="")return
      # the entity <-> SUBSCRIPTION relation, for the Last error(s) table on
      # every non-subscription page: which flows this entity moves files with.
      # gSITE is the page\047s own notion of that (the same one its Subscription
      # table shows); the errors themselves are keyed on col 12 in flush().
      # A SUBSCRIPTION page relates to itself: its own last error becomes the
      # "Last error" row of its Features table (the other types get the table).
      if(ty=="SITE") REL[ty SUBSEP ent SUBSEP ent]=1
      else           for(s9 in gSITE) REL[ty SUBSEP ent SUBSEP s9]=1
      addtop(ty SUBSEP ent SUBSEP day SUBSEP (pr2?"P":"F"), sk, disp, curcid)
      perday(ty,ent)
      # store-and-forward dwell distribution (section 12.6): count this File
      # into its dwell bucket for the entity (only when the group had a
      # measurable dwell — gdwb set in flush)
      if(gdwb!=""){ k5=ty SUBSEP ent; dwt[k5]++; dwc[k5 SUBSEP gdwb]++ }
      addbig(ty SUBSEP ent, sk, bigdisp, st4, (ty=="SITE")?500:100)
      # Waiting/Expired rollup -> the section-0.9 summary table (per entity):
      # count + first/last STAGED date per state
      if(toc[curcid]=="Waiting" || toc[curcid]=="Expired"){ kwe=ty SUBSEP ent SUBSEP toc[curcid]
        wec[kwe]++; if(wef[kwe]=="" || day<wef[kwe]) wef[kwe]=day; if(day>wel[kwe]) wel[kwe]=day }
      # each page omits its own dim; SITE pages skip the PDA dims entirely
      # (their Features table folds Domain/Application/Partner via _sum_config)
      for(dv in gDIM){ split(dv,a2,SUBSEP); if(a2[1]==od[ty]) continue
        if(ty=="SITE" && a2[1]+0>2.8 && a2[1]+0<3) continue
        if((a2[1]+0==3 || a2[1]+0==4) && ty!="PTN" && ty!="APP" && ty!="DOM" && ty!="LGC" && ty!="BL" && ty!="ACC") continue   # the Login/Host dims feed the Logical+PDA+BL+Account pages
        bump(ty,ent,a2[1],a2[2]) } }
    function flush(   v){
      day=tdt[curcid]; if(day=="") { split("",gLOGIN); split("",gSITE); split("",gHOST); split("",gDIM); gHADF=0; return }
      jd=tjd[curcid]+0; sk=tsk[curcid]; disp=tdt[curcid]" "ttm[curcid]; pr2=(toc[curcid]!="Failed" && toc[curcid]!="Expired"); size=tsz[curcid]+0
      hh=""; if(ttm[curcid] ~ /^[0-9][0-9]:/) hh=substr(ttm[curcid],1,2)
      if(jd>gmax) gmax=jd
      oc2=(pr2?"OK":"Error")
      # the 4-state label for the Latest-100 State column (toc = _files col 2)
      st4="Delivered"
      if(toc[curcid]=="Failed") st4="Errored"
      else if(toc[curcid]=="Waiting") st4="Waiting"
      else if(toc[curcid]=="Expired") st4="Expired"
      # the File own direction (col 16) -> the 4-way In/Out x Error/OK split a
      # direction=both page shows; a File with no direction stays out of it
      dio=""; if(tfd[curcid]=="in") dio=(pr2?"pi":"fi"); else if(tfd[curcid]=="out") dio=(pr2?"po":"fo")
      # store-and-forward dwell bucket (dwell-time.sh'\''s distribution): the
      # gap between the latest Inbound completion and the earliest Outbound
      # start; unmeasurable (one-leg / overlapping) groups set no bucket
      gdwb=""; gdwo=0
      if(g_inend>=0 && g_outst>=0 && g_outst>=g_inend){ dws=g_outst-g_inend
          if     (dws<1)  { gdwo=0; gdwb="< 1 s" }
          else if(dws<5)  { gdwo=1; gdwb="1 \342\200\223 5 s" }
          else if(dws<30) { gdwo=2; gdwb="5 \342\200\223 30 s" }
          else if(dws<60) { gdwo=3; gdwb="30 \342\200\223 60 s" }
          else if(dws<300){ gdwo=4; gdwb="1 \342\200\223 5 min" }
          else            { gdwo=5; gdwb="over 5 min" }
          dwo2[gdwb]=gdwo }
      dur2=tdur[curcid]+0; fl=tfl[curcid]; gsub(/\|/,"/",fl)
      # LAST FAILURE per SUBSCRIPTION (2026-08, section 0.4 below): the newest
      # FAILED File of each subscription. Not Expired — failed.sh stopped
      # listing expiries (a UC2 pickup problem with its own report), and this
      # side must track the SAME set or the links below would point at error
      # pages that no longer exist. Keyed on tsite (_files.tsv col 12), which
      # is EXACTLY what failed.sh keys its coverage floor on, so the
      # CoreId recorded here is guaranteed to have an errors/<coreid>.html page
      # to link to. (gSITE, used for the entity relation in ent_apply, can hold
      # more sites than col 12 — it is the legs\047 view — so it must not be
      # used here.) The `in` guard is the mawk rule: a bare read would create
      # the key.
      if(toc[curcid]=="Failed" && tsite[curcid]!="")
          if(!(tsite[curcid] in LEsk) || sk>LEsk[tsite[curcid]]) {
              LEsk[tsite[curcid]]=sk
              LEpay[tsite[curcid]]=disp "\t" tsite[curcid] "\t" fl "\t" curcid "\t" toc[curcid] }
      # Latest-100 payload; last field = the Direction cell, the CONNECTION /
      # FILE-MOVEMENT pair (out/in) for THIS file: col 16 is which side dialled,
      # col 17 which way the file travels (parse.sh already joined the
      # subscription onto _subscriptions-flowdir there, so re-deriving that map
      # here was duplicate work — verified identical on all 119,306 rows).
      # It used to show the movement alone, which hid the side that differs:
      # the two DIVERGE on 17.8% of files (every pull flow). A missing side
      # renders "?" like the XXX/YYY page title; neither known renders "-".
      fmv=tmv[curcid]; fcn=tfd[curcid]
      fdir=(fcn=="" && fmv=="") ? "-" : ((fcn==""?"?":fcn) "/" (fmv==""?"?":fmv))
      bigdisp=tdt[curcid] " " ttm[curcid] "|" fl "|" curcid "|" human(size) "|" (dur2>=0?humandur(dur2):"-") "|" thr(size, (dur2>=0?dur2:0)) "|" fdir
      # the quad dims (sections 2.81-2.84, right under the Account table): the
      # File'\''s Domain / Application / Logical / Partner attribution — the
      # separate tables that replaced the Groups fact table (SITE pages keep
      # their Features fold instead, see ent_apply)
      if(tdm[curcid]!="") gDIM[2.81 SUBSEP tdm[curcid]]=1
      # partner / application / logical = the UNION sets (\037-joined at preload)
      nau6=split(tap[curcid], AU6, "\037")
      for(iu6=1;iu6<=nau6;iu6++) gDIM[2.82 SUBSEP AU6[iu6]]=1
      nlu6=split(tlg[curcid], LU6, "\037")
      for(iu6=1;iu6<=nlu6;iu6++) gDIM[2.83 SUBSEP LU6[iu6]]=1
      npu6=split(tpt[curcid], PU6, "\037")
      for(iu6=1;iu6<=npu6;iu6++) gDIM[2.84 SUBSEP PU6[iu6]]=1
      nbu6=split(tbl[curcid], BU6, "\037")
      for(iu6=1;iu6<=nbu6;iu6++) gDIM[2.85 SUBSEP BU6[iu6]]=1
      if(tac[curcid]!="") ent_apply("ACC", tac[curcid])
      for(iu6=1;iu6<=nlu6;iu6++) ent_apply("LGC", LU6[iu6])
      for(iu6=1;iu6<=npu6;iu6++) ent_apply("PTN", PU6[iu6])
      for(iu6=1;iu6<=nau6;iu6++) ent_apply("APP", AU6[iu6])
      if(tdm[curcid]!="") ent_apply("DOM", tdm[curcid])
      for(iu6=1;iu6<=nbu6;iu6++) ent_apply("BL", BU6[iu6])
      for(v in gLOGIN) ent_apply("LOGIN", v)
      for(v in gSITE)  ent_apply("SITE",  v)
      for(v in gHOST)  ent_apply("HOST",  v)
      split("",gLOGIN); split("",gSITE); split("",gHOST); split("",gDIM); gHADF=0 }
    BEGIN { od["ACC"]=2.8; od["SITE"]=2; od["LOGIN"]=3; od["HOST"]=4
            od["DOM"]=2.81; od["APP"]=2.82; od["LGC"]=2.83; od["PTN"]=2.84; od["BL"]=2.85   # the quad dims (the former Groups table)
            }
    FNR == 1 { fno++ }
    fno == 1 { toc[$1]=$2; tac[$1]=$3; tdt[$1]=$4; ttm[$1]=$5; tsk[$1]=$6; tjd[$1]=$7; tsz[$1]=$8; tdur[$1]=$9; tfl[$1]=$11; tmv[$1]=$17
               tfd[$1]=$16; tsite[$1]=$12; tpt[$1]=sp_union($20,$12); tap[$1]=ap_union($18,$12); tlg[$1]=lg_union($13,$12); tbl[$1]=bl_union($12); tdm[$1]=$19; next }   # _files.tsv by CoreId (col 16 = connection; col 12 = subscription, for the file-movement lookup; partner/application/logical = UNION sets)
    {   # _transfers.tsv, CoreId-sorted: collect the group'\''s entity & dimension values
      if($1 != curcid){ if(curcid!="") flush(); curcid=$1; g_inend=-1; g_outst=-1 }
      # store-and-forward dwell inputs (mirrors dwell-time.sh): the group'\''s
      # latest Inbound completion ($18 raw end_time, US format) and earliest
      # Outbound start ($11 date_iso + $12 time)
      if($2=="Inbound" && $18!=""){ e5=ep_us($18); if(e5>g_inend) g_inend=e5 }
      if($2=="Outbound" && $12 ~ /^[0-9][0-9]:/){ s5=ep_iso($11,$12); if(s5>=0 && (g_outst<0 || s5<g_outst)) g_outst=s5 }
      if($3!="Processed") gHADF=1   # the group carried a FAILED leg (the Activity per day Recovered column, 2026-08-29)
      if($5!="")  gLOGIN[$5]=1
      if($6!="")  gSITE[$6]=1
      # HOST entities are OUTBOUND endpoints only (the hosts we dial) — an
      # incoming connection'\''s source IP is not a host (it lives in the
      # whitelist/incoming views), so only out-connection Files attribute one
      if($16!="" && tfd[$1]=="out") gHOST[$16]=1
      # the Login (3) / Host (4) DIMENSIONS, for the trio pages'\'' Logins and
      # Hosts tables (2026-08-29) — ent_apply bumps them for PTN/APP/DOM only
      if($5!="")  gDIM[3 SUBSEP $5]=1
      if($16!="" && tfd[$1]=="out") gDIM[4 SUBSEP $16]=1
      # (the Direction (13) and Mode (15) dims are GONE — 13 since the Features
      # era, 15 removed 2026-07; neither is collected any more)
      if($6!="")  gDIM[2 SUBSEP $6]=1
      # (no section-4 Remote Host dimension any more — the Outgoing connections
      # table, section 2.7, replaced it; the Protocol dimension table was
      # REMOVED 2026-07 — the protocol report covers it)
      # (the SECURITY table — section 7, secparams + AV-scan rows — was
      # REMOVED 2026-07; the security-params and av-scan REPORTS cover both)
      if($4!="")  gDIM[2.8 SUBSEP $4]=1
    }
    END {
      if(curcid!="") flush()
      for(k in adays){ split(k,a,SUBSEP); dstr[a[1] SUBSEP a[2]]=dstr[a[1] SUBSEP a[2]] " " a[3]; nact[a[1] SUBSEP a[2]]++ }
      for(k in ptr){ split(k,a,SUBSEP); ttot[a[1]]+=ptr[k]; ttotb[a[1]]+=ptb[k]; tcnt2[a[1]]++ }
      for(k in ptr){ split(k,a,SUBSEP)
        # three same-type ranks in one pass: by Files (ptr), by Size (ptb),
        # by error RATE (ptf/ptr) — #1 is the most files / bytes / errors
        rank=1; srank=1; erank=1; er=(ptr[k]>0?ptf[k]/ptr[k]:0)
        for(k2 in ptr){ split(k2,a2,SUBSEP); if(a2[1]!=a[1]) continue
          if(ptr[k2]>ptr[k]) rank++
          if(ptb[k2]>ptb[k]) srank++
          if((ptr[k2]>0?ptf[k2]/ptr[k2]:0)>er) erank++ }
        # 0% errors = the LAST position (#n of n), matching the Ranking report
        if(er==0) erank=tcnt2[a[1]]
        pct=ptr[k]>0?sprintf("%.1f",ptf[k]*100/ptr[k]):"0.0"
        share=ttot[a[1]]>0?sprintf("%.1f",ptr[k]*100/ttot[a[1]]):"0.0"
        sshare=ttotb[a[1]]>0?sprintf("%.1f",ptb[k]*100/ttotb[a[1]]):"0.0"
        avgsz=(ptr[k]>0?human(ptb[k]/ptr[k]):"-")
        printf "%s\t%s\t0\t0\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%d\t%d\t%s\t%s\t%d\t%d\n", a[1], a[2], ptr[k], ptf[k]+0, ptp[k]+0, human(ptb[k]), pfirst[k], plast[k], pct, share, rank, tcnt2[a[1]], nact[k]+0, medgap(k), gmax-pmaxjd[k], ptD[k SUBSEP "fi"]+0, ptD[k SUBSEP "pi"]+0, ptD[k SUBSEP "fo"]+0, ptD[k SUBSEP "po"]+0, human(ptmx[k]+0), avgsz, srank, erank, (ptr[k]>0?humandur(ptdur[k]/ptr[k]):"-"), sshare, wecnt(k SUBSEP "Waiting"), wecnt(k SUBSEP "Expired") }
      # section 0.4 — the Last error(s) rows: one per connected SUBSCRIPTION
      # that has an error, carrying the newest error of that subscription. The SORTKEY
      # is the File sortkey, so the global sort hands them to the writer
      # oldest-first and it walks them backwards for newest-first. Max one row
      # per subscription by construction (LEpay holds one File per site).
      for(k9 in REL){ split(k9,a9,SUBSEP)
          if(!(a9[3] in LEsk)) continue
          printf "%s\t%s\t0.4\t%s\t%s\n", a9[1], a9[2], LEsk[a9[3]], LEpay[a9[3]] }
      # fields 16/17 are the RAW per-day bytes and duration-ms (the humanized
      # $8/$15 above cannot be re-summed): details_writer.awk folds them into
      # the Ranking sidecar @data:buckets payload so the Ranking report can
      # re-aggregate — and re-rank — for a From/To range.
      for(kd in pdseen){ split(kd,a,SUBSEP); dc=pdf[kd]+pdp[kd]; printf "%s\t%s\t1\t%s\t%s\t%d\t%d\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\n", a[1], a[2], a[3], a[3], pdf[kd]+0, pdp[kd]+0, human(pdb[kd]), orlist(top[a[1] SUBSEP a[2] SUBSEP a[3] SUBSEP "F"]), orlist(top[a[1] SUBSEP a[2] SUBSEP a[3] SUBSEP "P"]), pdD[kd SUBSEP "fi"]+0, pdD[kd SUBSEP "pi"]+0, pdD[kd SUBSEP "fo"]+0, pdD[kd SUBSEP "po"]+0, (dc>0?humandur(pddur[kd]/dc):"-"), pdb[kd]+0, pddur[kd]+0, pdr[kd]+0 }
      # (the @data:buckets payload builders — bkH/bkD/bkB/dwbk over the
      # per-date twins — are GONE, 2026-07: the detail pages have no From/To
      # filter, so the re-aggregation payload had no consumer)
      for(k in hl){ split(k,a,SUBSEP); printf "%s\t%s\t11\t%s\t%s:00\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\n", a[1], a[2], a[3], a[3], hl[k], hf[k]+0, hp[k]+0, human(hb[k]), hD[k SUBSEP "fi"]+0, hD[k SUBSEP "pi"]+0, hD[k SUBSEP "fo"]+0, hD[k SUBSEP "po"]+0 }
      for(k in dl2){ split(k,a,SUBSEP); printf "%s\t%s\t10\t%s\t%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\n", a[1], a[2], a[3], a[3], dl2[k], df3[k]+0, dp3[k]+0, human(db2[k]), dD[k SUBSEP "fi"]+0, dD[k SUBSEP "pi"]+0, dD[k SUBSEP "fo"]+0, dD[k SUBSEP "po"]+0 }
      # section 12.6 — the store-and-forward dwell distribution per entity:
      # bucket label, Files in the bucket, the entity total (for the Share column)
      for(k in dwc){ split(k,a,SUBSEP)
          printf "%s\t%s\t12.6\t%d\t%s\t%d\t%d\n", a[1], a[2], dwo2[a[3]], a[3], dwc[k], dwt[a[1] SUBSEP a[2]] }
      for(key in bc){ split(key,a,SUBSEP)
        printf "%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%s\t%s\t%d\t%d\n", a[1], a[2], a[3], inv(bc[key]), a[4], bc[key], bf[key]+0, bp[key]+0, human(bv[key]+0), bD[key SUBSEP "fi"]+0, bD[key SUBSEP "pi"]+0, bD[key SUBSEP "fo"]+0, bD[key SUBSEP "po"]+0, orlist(top[key SUBSEP "F"]), orlist(top[key SUBSEP "P"]), bw[key]+0, be[key]+0 }
      for(k in wec){ split(k,a,SUBSEP)
        printf "%s\t%s\t0.9\t%d\t%s|%d|%s|%s\n", a[1], a[2], (a[3]=="Waiting"?0:1), a[3], wec[k], wef[k], wel[k] }
      US = sprintf("%c", 31)
      for(k in big){ split(k,a,SUBSEP)
        n=split(big[k],arr,US)
        for(i=1;i<=n;i++){ split(arr[i],f2,SUBSEP)
          printf "%s\t%s\t9\t%03d\t%s|%s\n", a[1], a[2], i, f2[2], f2[3] } }   # section 9 -> the Latest-Files table renders right above the Load by weekday table
    }' "$FILES" "$PARSED"
}
# ===== the WRITER lives in bin/transfer/details_writer.awk (2026-07) =========
# Everything below this line used to be the bash writer — run_detail_writer
# and every emit helper it called (ensure_file, finish_section, emit_intro,
# emit_perf_tables, start_table, page_srv_log, emit_srv_lines_table, blue_box,
# uncollected_files_table, strip_notseen_counts, close_file, the _sum_*
# helpers). It was ported byte-identically to ONE awk program per entity type
# — the bash loop forked $(printf …) per dimension row, ran ~11 cat/sort/awk
# processes per page for the server-log table and reopened the output file
# for every appended line, which put ~44 s of a 59 s run in the kernel.
# details.sh invokes the awk once per type over the same writer pool.
