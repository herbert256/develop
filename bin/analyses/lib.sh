#!/usr/bin/env bash
#
# bin/analyses/lib.sh — shared paths + compute helpers for the ANALYSES tool
# set: the configured-vs-seen analyses derived from the transfer area's
# outputs (showseen.sh's coverage TSVs, the detail-page slugmaps) and the
# data/flow-manager config caches. Sourced by the report scripts; the publish script
# sources bin/publish_lib.sh instead (it needs the html machinery). Paths
# derive from this file's own location and the lib cd's to the repo root, so
# the data/… relative paths used throughout resolve from any working dir.
#
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$LIB_DIR/../.." && pwd)"
cd "$ROOT"
source "$ROOT/bin/env.sh"        # resolve $AXWAY_ENV (acceptance|production, default acceptance)
IP_DIR="$ROOT/input/$AXWAY_ENV/ip"                 # PER ENV (the two estates share no endpoints)
source "$ROOT/bin/ip.sh"         # IP_HOSTS_FILE (input/<env>/ip/ip-hosts.tsv) + ip_put
DATA="data/$AXWAY_ENV"           # the env's data root (this lib cd's to the repo root)
REPORTS_DIR="$DATA/analyses/reports"        # home.rpt (the status tables' SEEN counts) + first-seen*.rpt
FSRPT_DIR="$DATA/first-seen"                # one .rpt per First-seen cell page
COVRPT_DIR="$DATA/coverage"                  # one .rpt per coverage cell page (the 3 PDA Configured cells)
COVSRC="$DATA/transfer/reports/coverage"    # showseen.sh's coverage TSVs (+ the 3 derived ones below)
mkdir -p "$REPORTS_DIR" "$COVRPT_DIR" "$FSRPT_DIR"

meta_val() { grep -m1 "^META"$'\t'"$2"$'\t' "$1" 2>/dev/null | cut -f3- || true; }   # META key $2 in file $1

# cov_put FILE — read stdin and replace FILE only when the CONTENT differs, so
# an unchanged re-derive KEEPS ITS MTIME. ensure_pda_tsvs is called by three
# report scripts and rewrote these TSVs on every call; every mtime-based
# freshness check downstream (and every publish stamp) then saw a newer input
# and rebuilt for nothing. Same idiom as bin/expire-files.sh.
# Valid HERE and not for a .rpt: these TSVs are pure data, while a .rpt carries
# the run time in its FOOT line and so never compares equal.
cov_put() {
    local out=$1 tmp
    tmp=$(mktemp "${out}.XXXXXX") || return 1
    cat > "$tmp"
    if [ -f "$out" ] && cmp -s "$tmp" "$out"; then rm -f "$tmp"; else mv -f "$tmp" "$out"; fi
}

# skip_if_fresh OUT SCRIPT [DEP...] — the analyses counterpart of the transfer
# and server libs' helper: exit the calling report early (status 0) when its
# data file OUT exists and is newer than the report SCRIPT, this lib and every
# extra DEP file. The analyses tool set parses nothing of its own, so there is
# no parse cache to watch — each report names the transfer/config outputs it
# actually reads instead.
# A MULTI-OUTPUT report must check its other outputs EXIST before calling this
# (skip_if_fresh exits on the first fresh one, so it cannot see the rest).
skip_if_fresh() {
    local out=$1 script=$2; shift 2
    [ -f "$out" ] || return 0                                  # missing -> build
    if [ "$script" -nt "$out" ] || [ "$LIB_DIR/lib.sh" -nt "$out" ]; then
        return 0                                               # stale -> build
    fi
    local dep
    for dep in "$@"; do
        if [ -d "$dep" ]; then                                 # a whole TREE as one dep
            if [ -n "$(find "$dep" -type f -newer "$out" -print -quit 2>/dev/null)" ]; then
                return 0
            fi
        elif [ -f "$dep" ] && [ "$dep" -nt "$out" ]; then
            return 0                                           # newer input -> build
        fi
    done
    echo "  $(basename "$out") is up to date; skipping." >&2
    exit 0
}

# Logical-flow figures for the root index's one-row "Logical" table — the
# applications.tsv shape and machinery, with the SUBSCRIPTION path as the
# primary (and only) member source: every Logical derives from the configured
# subscriptions' FlowIDs (xref/_subscriptions-logicals.tsv), so a logical's
# members ARE its subscriptions. One row per (logical, direction) into
# $COVSRC/logicals.tsv — side from the subscription's coverage row, seen when
# any member subscription is, Result = the latest transaction; server-log-only
# (blue) logicals count as SEEN like every PDA member.
logicals_tsv() {
    local scov="$COVSRC/subscriptions.tsv" sl="$DATA/flow-manager/xref/_subscriptions-logicals.tsv"
    local lmap="$DATA/transfer/reports/details/logicals/_slugmap.tsv"
    local lbase="$DATA/flow-manager/base/_logicals.tsv"
    [ -f "$scov" ] && [ -f "$sl" ] || return 0
    [ -f "$lmap" ] || lmap=/dev/null
    [ -f "$lbase" ] || lbase=/dev/null
    awk -F'\t' -v bluef="$lbase" '
        BEGIN { US = sprintf("%c", 31)
            # server-log-only (blue) logicals count as SEEN (see internal_apps_tsv)
            while ((getline l < bluef) > 0) { nb=split(l,ba,"\t"); if (nb>=3 && ba[3]=="blue") blue[toupper(ba[1])]=1 } close(bluef) }
        FILENAME ~ /_slugmap\.tsv$/ { lslug[$1]=$2; next }   # logical name -> detail-page slug
        FILENAME ~ /_subscriptions-logicals\.tsv$/ { if($1!="" && $2!="") slg[$1]=((slg[$1]!="")?slg[$1] US:"") $2; next }
        {   # coverage/subscriptions.tsv: name dir seen link ts outcome
            d2=$2; if (d2!="I" && d2!="O" && d2!="B") next
            if (!($1 in slg)) next
            # B (a both-ways subscription) counts once per SIDE, like a both-ways partner
            ns2=0; if(d2=="I" || d2=="B") S2[++ns2]="I"; if(d2=="O" || d2=="B") S2[++ns2]="O"
            na=split(slg[$1], av, US)
            for(ai=1; ai<=na; ai++) for(si=1; si<=ns2; si++){
                k=av[ai] SUBSEP S2[si]
                n[k]++; mem[k]=mem[k] US $1 "|" $4
                if($3==1){ seen[k]=1
                    if($5!="" && $5>lts[k]){ lts[k]=$5; loc[k]=$6 } }
            }
        }
        END{
            for(k in n){ split(k,x,SUBSEP)
                if(toupper(x[1]) in blue) seen[k]=1
                printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t\n", x[1], x[2], seen[k]+0, ((x[1] in lslug) ? "logicals/" lslug[x[1]] : ""), lts[k], loc[k], substr(mem[k],2) }
        }' "$lmap" "$sl" "$scov" | LC_ALL=C sort -t$'\t' -k1,1 -k2,2 | cov_put "$COVSRC/logicals.tsv"
}

# BL figures — the logicals_tsv shape with the same SUBSCRIPTION member
# source: a BL entity is a subscriptions.json tags entry starting with BL, so
# its members ARE the subscriptions carrying the tag
# (xref/_subscriptions-bl.tsv). One row per (bl, direction) into
# $COVSRC/bl.tsv; server-log-only (blue) BL tags count as SEEN likewise.
bl_tsv() {
    local scov="$COVSRC/subscriptions.tsv" sl="$DATA/flow-manager/xref/_subscriptions-bl.tsv"
    local lmap="$DATA/transfer/reports/details/bl/_slugmap.tsv"
    local lbase="$DATA/flow-manager/base/_bl.tsv"
    [ -f "$scov" ] && [ -f "$sl" ] || return 0
    [ -f "$lmap" ] || lmap=/dev/null
    [ -f "$lbase" ] || lbase=/dev/null
    awk -F'\t' -v bluef="$lbase" '
        BEGIN { US = sprintf("%c", 31)
            while ((getline l < bluef) > 0) { nb=split(l,ba,"\t"); if (nb>=3 && ba[3]=="blue") blue[toupper(ba[1])]=1 } close(bluef) }
        FILENAME ~ /_slugmap\.tsv$/ { lslug[$1]=$2; next }   # BL name -> detail-page slug
        FILENAME ~ /_subscriptions-bl\.tsv$/ { if($1!="" && $2!="") slg[$1]=((slg[$1]!="")?slg[$1] US:"") $2; next }
        {   # coverage/subscriptions.tsv: name dir seen link ts outcome
            d2=$2; if (d2!="I" && d2!="O" && d2!="B") next
            if (!($1 in slg)) next
            ns2=0; if(d2=="I" || d2=="B") S2[++ns2]="I"; if(d2=="O" || d2=="B") S2[++ns2]="O"
            na=split(slg[$1], av, US)
            for(ai=1; ai<=na; ai++) for(si=1; si<=ns2; si++){
                k=av[ai] SUBSEP S2[si]
                n[k]++; mem[k]=mem[k] US $1 "|" $4
                if($3==1){ seen[k]=1
                    if($5!="" && $5>lts[k]){ lts[k]=$5; loc[k]=$6 } }
            }
        }
        END{
            for(k in n){ split(k,x,SUBSEP)
                if(toupper(x[1]) in blue) seen[k]=1
                printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t\n", x[1], x[2], seen[k]+0, ((x[1] in lslug) ? "bl/" lslug[x[1]] : ""), lts[k], loc[k], substr(mem[k],2) }
        }' "$lmap" "$sl" "$scov" | LC_ALL=C sort -t$'\t' -k1,1 -k2,2 | cov_put "$COVSRC/bl.tsv"
}

# External-partner figures for the root index's one-row "External Partners"
# table. The partner ORGANISATIONS (In clusters, Out endpoints, both-ways
# linked pairs) are derived by bin/flow-manager.sh — data/flow-manager/base/_partners.tsv
# and the _accounts-partners/_hosts-partners/_partners-white xref caches are
# the single source; this only joins showseen.sh's coverage TSVs onto them
# for the Seen/Result enrichment. Materializes ONE partner per line into
# $COVSRC/partners.tsv — the same shape as showseen's coverage TSVs
# (name, dir, seen, detail link, last ts, last outcome F/P) plus a 7th
# column: the In partner's member accounts as \x1f-joined "name|covlink"
# pairs, and col 8 = the In partner's whitelist IPs / a linked Out row's In
# partner. In partners first (label-sorted), then the Out hosts verbatim
# from hosts.tsv. write_coverage_pages renders a page per nonzero cell from
# it, and the External Partners row reads its figures + links the pages.
# Emits nothing (and writes no TSV) when the inputs are missing.
external_partners_tsv() {
    local pbase="$DATA/flow-manager/base/_partners.tsv"
    local ap="$DATA/flow-manager/xref/_accounts-partners.tsv" hp="$DATA/flow-manager/xref/_hosts-partners.tsv"
    local pacc2="$DATA/flow-manager/xref/_partners-accounts.tsv"   # org -> accounts (the endpoint-less Out rows' members)
    local aw="$DATA/flow-manager/xref/_accounts-white.tsv" pw="$DATA/flow-manager/xref/_partners-white.tsv"
    local ahf="$DATA/flow-manager/xref/_accounts-hosts.tsv"
    local cov="$COVSRC/accounts.tsv" hosts="$COVSRC/hosts.tsv"
    local pmap="$DATA/transfer/reports/details/partners/_slugmap.tsv"
    local pfake="$pbase"   # server-log-only (blue) partners are result==blue in the base cache
    [ -f "$pbase" ] && [ -f "$ap" ] && [ -f "$cov" ] || return 0
    [ -f "$aw" ] || aw=/dev/null
    [ -f "$pw" ] || pw=/dev/null
    [ -f "$ahf" ] || ahf=/dev/null
    [ -f "$pacc2" ] || pacc2=/dev/null
    [ -f "$pmap" ] || pmap=/dev/null
    [ -f "$pfake" ] || pfake=/dev/null
    {
        # In rows: one per in/both organisation. Members = the accounts the
        # config maps to the org, MINUS its endpoint-mapped Out accounts (a
        # member is In-configured or whitelisted — which keeps the rare
        # Out-configured account inside a whitelist cluster, the PLURALSIGHT
        # pair). Seen/Result aggregate the IN-direction members only, so an
        # outbound transfer can never set an In partner's status.
        awk -F'\t' -v pfake="$pfake" '
            BEGIN { US = sprintf("%c", 31)
                # Fake/server-only partners (bin/build/seen-in-server-log.sh, data/fakes/partners.tsv)
                # count as SEEN — the Server bucket already counts them, so Seen
                # must too, or Transfer = Seen - Server under-counts. An account-
                # seeded fake names an OUT partner but leaves its endpoint blank,
                # so the endpoint-keyed seen below would miss it.
                while ((getline l < pfake) > 0) { np=split(l,pa,"\t"); if (np>=3 && pa[3]=="blue") fake[toupper(pa[1])]=1 } }
            FILENAME ~ /_slugmap\.tsv$/        { pslug[$1]=$2; next }   # partner name -> detail-page slug
            FILENAME ~ /_partners\.tsv$/       { if($2=="in" || $2=="both") indir[$1]=1; next }
            FILENAME ~ /_accounts-white\.tsv$/ { white[$1]=1; next }
            FILENAME ~ /_partners-white\.tsv$/ { if(!(($1 SUBSEP $2) in ipseen)){ ipseen[$1 SUBSEP $2]=1; cip[$1]=cip[$1] US $2 }; next }
            FILENAME ~ /accounts\.tsv$/ { cov_dir[$1]=$2; cov_seen[$1]=$3; cov_link[$1]=$4; cov_ts[$1]=$5; cov_oc[$1]=$6; next }
            {   # _accounts-partners.tsv (account-sorted -> deterministic member order)
                a=$1; c=$2
                if(!(c in indir)) next
                # B = the account is configured both ways (login AND host) —
                # its In side makes it an In member like a plain I account
                if(cov_dir[a]!="I" && cov_dir[a]!="B" && !(a in white)) next
                mem[c]=mem[c] US a "|" cov_link[a]
                if((cov_dir[a]=="I" || cov_dir[a]=="B") && cov_seen[a]==1){ seen[c]=1
                    if(cov_ts[a]!="" && cov_ts[a]>lts[c]){ lts[c]=cov_ts[a]; loc[c]=cov_oc[a] } }
            }
            END { for(c in indir) {
                if (toupper(c) in fake) seen[c] = 1
                printf "%s\tI\t%d\t%s\t%s\t%s\t%s\t%s\n", c, seen[c]+0, ((c in pslug) ? "partners/" pslug[c] : ""), lts[c], loc[c], substr(mem[c],2), substr(cip[c],2) } }
        ' "$pmap" "$pbase" "$aw" "$pw" "$cov" "$ap" | LC_ALL=C sort -t$'\t' -k1,1
        # Out rows from coverage hosts.tsv + _hosts-partners.tsv. An endpoint
        # whose org is an In partner (a both-ways link) stays one row PER
        # ENDPOINT, named by the endpoint, col 8 = the In partner — the Total
        # column and the Total coverage pages fold the pair ONCE and its
        # members join the In partner's list. Every other endpoint folds into
        # its account-derived Out PARTNER (org): one row per org, seen = any
        # endpoint, Result = the latest transaction. (Endpoints are
        # canonically lowercase since the config extraction; the tolower
        # folding here is defensive only.) Every Out row's MEMBERS (col 7)
        # are `account|covlink|endpoint` TRIPLES (the renderer's Accounts /
        # Endpoints column pair); an endpoint with no configured account
        # lists itself, linked to its host page.
        if [ -f "$hosts" ] && [ -f "$hp" ]; then
            awk -F'\t' -v pfake="$pfake" '
                BEGIN { US = sprintf("%c", 31)
                    # fake/server-only partners count as SEEN (see the In block)
                    while ((getline l < pfake) > 0) { np=split(l,pa,"\t"); if (np>=3 && pa[3]=="blue") fake[toupper(pa[1])]=1 } }
                FILENAME ~ /_slugmap\.tsv$/        { pslug[$1]=$2; next }   # partner name -> detail-page slug
                FILENAME ~ /_partners\.tsv$/       { if($2=="in" || $2=="both") inp[$1]=1
                                                     else if($2=="out" && $1 != "" && !($1 in outp)) { outp[$1]=1; outn[++no]=$1 }
                                                     next }   # out roster in FILE order (name-sorted) — the endpoint-less emit below must not depend on hash order
                FILENAME ~ /_hosts-partners\.tsv$/ { org[$1] = org[$1] US $2; next }   # ONE endpoint may serve SEVERAL partner groups — keep them all (a plain org[$1]=$2 dropped every group but the last: AZRNL/ORDINA/PWD/SAPSF/FISCLOUD/P2P/P2P1 vanished)
                FILENAME ~ /_accounts-hosts\.tsv$/ { ha[tolower($2)] = ha[tolower($2)] US $1; next }
                FILENAME ~ /_partners-accounts\.tsv$/ { pacc[$1] = pacc[$1] US $2; next }   # org -> its accounts (MUST precede the accounts\.tsv$ rule — this name matches both)
                FILENAME ~ /accounts\.tsv$/        { alk[$1]=$4; next }
                { nog = split(substr(org[$1], 2), OGS, US)
                  if (nog == 0) { nog = 1; OGS[1] = "" }
                  # one pass per (endpoint, group) pair: each group the
                  # endpoint serves gets that endpoint as seen/ts/member
                  for (gg = 1; gg <= nog; gg++) {
                  o = OGS[gg]; k = (o != "" && !(o in inp)) ? "P" o : "E" tolower($1)
                  if (k in idx) { i = idx[k]
                      if ($3 == 1) seen[i] = 1
                      if ($5 != "" && $5 > ts[i]) { ts[i] = $5; oc[i] = $6 } }
                  else { i = idx[k] = ++n; seen[n] = $3; ts[n] = $5; oc[n] = $6; ln[n] = ""; mem[n] = ""
                      if (substr(k,1,1) == "P") { nm[n] = o; lk[n] = ((o in pslug) ? "partners/" pslug[o] : "") }
                      else { nm[n] = $1; lk[n] = $4; if (o != "") ln[n] = o } }
                  el = tolower($1)
                  na = split(substr(ha[el], 2), A, US)
                  if (na == 0) {
                      if (!((k SUBSEP el) in mseen)) { mseen[k SUBSEP el] = 1; mem[i] = mem[i] US $1 "|" $4 "|" $1 }
                  } else for (j = 1; j <= na; j++) {
                      mk = k SUBSEP A[j] SUBSEP el
                      if (mk in mseen) continue
                      mseen[mk] = 1
                      mem[i] = mem[i] US A[j] "|" alk[A[j]] "|" $1
                  } } }
                END { for (i = 1; i <= n; i++) {
                    if (toupper(nm[i]) in fake) seen[i] = 1
                    printf "%s\tO\t%d\t%s\t%s\t%s\t%s\t%s\n", nm[i], seen[i]+0, lk[i], ts[i], oc[i], substr(mem[i],2), ln[i] }
                    # ENDPOINT-LESS Out orgs (2026-08-29): the rows above are
                    # keyed by ENDPOINT, so an out org no configured host maps
                    # to — the SECOND org of a both-partner account (the
                    # 2-parts-both->5-chars split: SUCCESS_FACTORS ->
                    # SUCCESS + FACTORS, but _hosts-partners.tsv maps the
                    # endpoint to ONE group) — never got a coverage row at
                    # all. The Entities publish then saw a base name in
                    # neither list and ghost-tagged it data-seen=1: on a
                    # config-only estate that rendered a phantom "1 partner
                    # seen in the transfer log". Emit those as ordinary
                    # configured-never-seen rows instead — members are the
                    # org'\''s accounts (endpoint column empty), seen only by
                    # the blue rule like every other row.
                    for (z = 1; z <= no; z++) { o = outn[z]
                        if ((o in inp) || (("P" o) in idx)) continue
                        m = ""; nax = split(substr(pacc[o], 2), PA2, US)
                        for (j = 1; j <= nax; j++) m = m US PA2[j] "|" alk[PA2[j]] "|"
                        printf "%s\tO\t%d\t%s\t\t\t%s\t\n", o, ((toupper(o) in fake) ? 1 : 0), ((o in pslug) ? "partners/" pslug[o] : ""), substr(m, 2) } }
            ' "$pmap" "$pbase" "$hp" "$ahf" "$pacc2" "$cov" "$hosts"
        fi
    } | cov_put "$COVSRC/partners.tsv"
}

# Internal-application figures for the root index's one-row "Internal
# Applications" table — the same shape and machinery as External Partners.
# The application names come from bin/flow-manager.sh's _accounts-apps.tsv cache
# (the MIDDLE part of the three-part logical flow names, joined via the account);
# this only joins the coverage TSV onto it. One row per (application,
# direction) into $COVSRC/applications.tsv — the partner coverage shape with
# an empty whitelist column — aggregating that direction's accounts: seen
# when any is, Result = the latest transaction. An application active in
# both directions counts once per side, exactly like a both-ways partner.
internal_apps_tsv() {
    local cov="$COVSRC/accounts.tsv" aa="$DATA/flow-manager/xref/_accounts-apps.tsv"
    local amap="$DATA/transfer/reports/details/applications/_slugmap.tsv"
    local abase="$DATA/flow-manager/base/_apps.tsv"
    # the SUBSCRIPTION-derived names (the flow-manager fallback, 2026-08-29):
    # an application no account maps to still needs a coverage row, or the
    # base name is absent from this TSV and the ghost rules (home
    # pda_seen_total, the Entities publish) call it SEEN — production showed
    # 132 "seen" applications with zero logs. Seen for those rows comes from
    # their SUBSCRIPTIONS' coverage; members are the owning account(s).
    local sa="$DATA/flow-manager/xref/_subscriptions-apps.tsv"
    local sacc="$DATA/flow-manager/xref/_subscriptions-accounts.tsv"
    local scov="$COVSRC/subscriptions.tsv"
    [ -f "$cov" ] && [ -f "$aa" ] || return 0
    [ -f "$amap" ] || amap=/dev/null
    [ -f "$abase" ] || abase=/dev/null
    [ -f "$sa" ] || sa=/dev/null
    [ -f "$sacc" ] || sacc=/dev/null
    [ -f "$scov" ] || scov=/dev/null
    awk -F'\t' -v bluef="$abase" '
        BEGIN { US = sprintf("%c", 31)
            # server-log-only (blue) applications count as SEEN — the Server
            # bucket counts them, so Seen must too (their accounts are blue, i.e.
            # never seen in the transfer logs, so the coverage join below misses them).
            while ((getline l < bluef) > 0) { nb=split(l,ba,"\t"); if (nb>=3 && ba[3]=="blue") blue[toupper(ba[1])]=1 } close(bluef) }
        FILENAME ~ /_slugmap\.tsv$/ { aslug[$1]=$2; next }   # application name -> detail-page slug
        FILENAME ~ /_accounts-apps\.tsv$/ { app[$1]=((app[$1] != "") ? app[$1] US : "") $2
                                            na=split(app[$1], av, US); for(ai=1; ai<=na; ai++) fromacct[av[ai]]=1; next }   # an account can map to MORE than one application (UC8 relays); test emptiness not membership (mawk assignment trap)
        FILENAME ~ /_subscriptions-apps\.tsv$/     { if($1!="" && $2!="") sapp[$1]=((sapp[$1]!="")?sapp[$1] US:"") $2; next }
        FILENAME ~ /_subscriptions-accounts\.tsv$/ { if($1!="" && $2!="") sacct[$1]=((sacct[$1]!="")?sacct[$1] US:"") $2; next }
        FILENAME ~ /coverage\/subscriptions\.tsv$/ { sdir[$1]=$2; sseen[$1]=$3; sts5[$1]=$5; soc6[$1]=$6; next }
        ($2=="I" || $2=="O" || $2=="B") { acov[$1]=$4 }   # every account row: name -> covlink (the fallback rows link members through it)
        ($2=="I" || $2=="O" || $2=="B") && ($1 in app) {
            # B (a both-ways account) counts once per SIDE, like a both-ways partner
            ns2=0; if($2=="I" || $2=="B") S2[++ns2]="I"; if($2=="O" || $2=="B") S2[++ns2]="O"
            na=split(app[$1], av, US)
            for(ai=1; ai<=na; ai++) for(si=1; si<=ns2; si++){
                k=av[ai] SUBSEP S2[si]
                n[k]++; mem[k]=mem[k] US $1 "|" $4
                if($3==1){ seen[k]=1
                    if($5!="" && $5>lts[k]){ lts[k]=$5; loc[k]=$6 } }
            }
        }
        END{
            # rows for the subscription-derived names the account path never
            # emits: side from the subscription, seen from ITS coverage row
            for (s in sapp) {
                d2 = sdir[s]; if (d2 != "I" && d2 != "O" && d2 != "B") continue
                ns2=0; if(d2=="I"||d2=="B") S2[++ns2]="I"; if(d2=="O"||d2=="B") S2[++ns2]="O"
                na=split(sapp[s], av, US)
                for(ai=1; ai<=na; ai++){ a2=av[ai]
                    if (a2 in fromacct) continue
                    for(si=1; si<=ns2; si++){ k=a2 SUBSEP S2[si]
                        n[k]++
                        nax=split(sacct[s], AC2, US)
                        for(x2=1; x2<=nax; x2++){ mk2=k SUBSEP AC2[x2]
                            if(!(mk2 in m2seen)){ m2seen[mk2]=1
                                mem[k]=mem[k] US AC2[x2] "|" ((AC2[x2] in acov)?acov[AC2[x2]]:"") } }
                        if (sseen[s]==1){ seen[k]=1
                            if (sts5[s]!="" && sts5[s]>lts[k]){ lts[k]=sts5[s]; loc[k]=soc6[s] } }
                    } } }
            for(k in n){ split(k,x,SUBSEP)
                if(toupper(x[1]) in blue) seen[k]=1
                printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t\n", x[1], x[2], seen[k]+0, ((x[1] in aslug) ? "applications/" aslug[x[1]] : ""), lts[k], loc[k], substr(mem[k],2) }
        }' "$amap" "$aa" "$sa" "$sacc" "$scov" "$cov" | LC_ALL=C sort -t$'\t' -k1,1 -k2,2 | cov_put "$COVSRC/applications.tsv"
}

# Internal-domain figures for the root index's one-row "Internal Domains"
# table — External Partners' shape again, one level up:
# the domain (the FIRST part of the three-part logical flow name) comes from
# bin/flow-manager.sh's _accounts-domains.tsv cache. One row per (domain,
# direction) into $COVSRC/domains.tsv, the applications.tsv shape exactly.
internal_domains_tsv() {
    local cov="$COVSRC/accounts.tsv" ad="$DATA/flow-manager/xref/_accounts-domains.tsv"
    local dmap="$DATA/transfer/reports/details/domains/_slugmap.tsv"
    local dbase="$DATA/flow-manager/base/_domains.tsv"
    # subscription-derived names — see internal_apps_tsv (the same ghost fix)
    local sd="$DATA/flow-manager/xref/_subscriptions-domains.tsv"
    local sacc="$DATA/flow-manager/xref/_subscriptions-accounts.tsv"
    local scov="$COVSRC/subscriptions.tsv"
    [ -f "$cov" ] && [ -f "$ad" ] || return 0
    [ -f "$dmap" ] || dmap=/dev/null
    [ -f "$dbase" ] || dbase=/dev/null
    [ -f "$sd" ] || sd=/dev/null
    [ -f "$sacc" ] || sacc=/dev/null
    [ -f "$scov" ] || scov=/dev/null
    awk -F'\t' -v bluef="$dbase" '
        BEGIN { US = sprintf("%c", 31)
            # server-log-only (blue) domains count as SEEN (see internal_apps_tsv)
            while ((getline l < bluef) > 0) { nb=split(l,ba,"\t"); if (nb>=3 && ba[3]=="blue") blue[toupper(ba[1])]=1 } close(bluef) }
        FILENAME ~ /_slugmap\.tsv$/ { dslug[$1]=$2; next }   # domain name -> detail-page slug
        FILENAME ~ /_accounts-domains\.tsv$/ { dm[$1]=$2; fromacct[$2]=1; next }
        FILENAME ~ /_subscriptions-domains\.tsv$/  { if($1!="" && $2!="") sdom[$1]=((sdom[$1]!="")?sdom[$1] US:"") $2; next }
        FILENAME ~ /_subscriptions-accounts\.tsv$/ { if($1!="" && $2!="") sacct[$1]=((sacct[$1]!="")?sacct[$1] US:"") $2; next }
        FILENAME ~ /coverage\/subscriptions\.tsv$/ { sdir[$1]=$2; sseen[$1]=$3; sts5[$1]=$5; soc6[$1]=$6; next }
        ($2=="I" || $2=="O" || $2=="B") { acov[$1]=$4 }   # every account row: name -> covlink (the fallback rows link members through it)
        ($2=="I" || $2=="O" || $2=="B") && ($1 in dm) {
            # B (a both-ways account) counts once per SIDE, like a both-ways partner
            ns2=0; if($2=="I" || $2=="B") S2[++ns2]="I"; if($2=="O" || $2=="B") S2[++ns2]="O"
            for(si=1; si<=ns2; si++){
                k=dm[$1] SUBSEP S2[si]
                n[k]++; mem[k]=mem[k] US $1 "|" $4
                if($3==1){ seen[k]=1
                    if($5!="" && $5>lts[k]){ lts[k]=$5; loc[k]=$6 } }
            }
        }
        END{
            # rows for the subscription-derived names — see internal_apps_tsv
            for (s in sdom) {
                d2 = sdir[s]; if (d2 != "I" && d2 != "O" && d2 != "B") continue
                ns2=0; if(d2=="I"||d2=="B") S2[++ns2]="I"; if(d2=="O"||d2=="B") S2[++ns2]="O"
                na=split(sdom[s], av, US)
                for(ai=1; ai<=na; ai++){ a2=av[ai]
                    if (a2 in fromacct) continue
                    for(si=1; si<=ns2; si++){ k=a2 SUBSEP S2[si]
                        n[k]++
                        nax=split(sacct[s], AC2, US)
                        for(x2=1; x2<=nax; x2++){ mk2=k SUBSEP AC2[x2]
                            if(!(mk2 in m2seen)){ m2seen[mk2]=1
                                mem[k]=mem[k] US AC2[x2] "|" ((AC2[x2] in acov)?acov[AC2[x2]]:"") } }
                        if (sseen[s]==1){ seen[k]=1
                            if (sts5[s]!="" && sts5[s]>lts[k]){ lts[k]=sts5[s]; loc[k]=soc6[s] } }
                    } } }
            for(k in n){ split(k,x,SUBSEP)
                if(toupper(x[1]) in blue) seen[k]=1
                printf "%s\t%s\t%d\t%s\t%s\t%s\t%s\t\n", x[1], x[2], seen[k]+0, ((x[1] in dslug) ? "domains/" dslug[x[1]] : ""), lts[k], loc[k], substr(mem[k],2) }
        }' "$dmap" "$ad" "$sd" "$sacc" "$scov" "$cov" | LC_ALL=C sort -t$'\t' -k1,1 -k2,2 | cov_put "$COVSRC/domains.tsv"
}

cov_label() {   # $1 cell key -> human title part
    case $1 in
        configured)           echo "Configured" ;;
        configured-in)        echo "Configured — In" ;;
        configured-out)       echo "Configured — Out" ;;
        notseen)              echo "Not Seen" ;;
        notseen-in)           echo "Not Seen — In" ;;
        notseen-out)          echo "Not Seen — Out" ;;
        seen)                 echo "Seen" ;;
        seen-in)              echo "Seen — In" ;;
        seen-out)             echo "Seen — Out" ;;
        notseen-transfer)     echo "Not seen in the transfer log" ;;
        status-warning-server) echo "Warning or server-log only" ;;
        status-transfer)      echo "Seen in the transfer log" ;;
        status-transfer-in)   echo "Seen in the transfer log — In" ;;
        status-transfer-out)  echo "Seen in the transfer log — Out" ;;
        status-transfer-failed)     echo "Transfer, last transfer Error" ;;
        status-transfer-failed-in)  echo "Transfer In, last transfer Error" ;;
        status-transfer-failed-out) echo "Transfer Out, last transfer Error" ;;
        status-transfer-inonly)     echo "Seen in the transfer log — In only" ;;
        status-transfer-both)       echo "Seen in the transfer log — In and Out" ;;
        status-transfer-outonly)    echo "Seen in the transfer log — Out only" ;;
        status-transfer-failed-inonly)  echo "Transfer In only, last transfer Error" ;;
        status-transfer-failed-both)    echo "Transfer In and Out, last transfer Error" ;;
        status-transfer-failed-outonly) echo "Transfer Out only, last transfer Error" ;;
        status-server)        echo "Server (server-log only)" ;;
        status-server-in)     echo "Server (server-log only) — In" ;;
        status-server-out)    echo "Server (server-log only) — Out" ;;
        status-server-inonly)  echo "Server (server-log only) — In only" ;;
        status-server-both)    echo "Server (server-log only) — In and Out" ;;
        status-server-outonly) echo "Server (server-log only) — Out only" ;;
        status-error)         echo "Status Error (result red)" ;;
        status-warning)       echo "Status Warning (result orange)" ;;
        status-ok)            echo "Status Ok (result green)" ;;
        result-failed)        echo "Result — last transfer Error" ;;
        result-processed)     echo "Result — last transfer OK" ;;
        result-in-failed)     echo "Result In — last transfer Error" ;;
        result-in-processed)  echo "Result In — last transfer OK" ;;
        result-out-failed)    echo "Result Out — last transfer Error" ;;
        result-out-processed) echo "Result Out — last transfer OK" ;;
        # the direction-split view (PDA-page table): In only / Both / Out only
        # partition the merged Total universe
        configured-inonly)         echo "Configured — In only" ;;
        configured-both)           echo "Configured — In and Out" ;;
        configured-outonly)        echo "Configured — Out only" ;;
        notseen-inonly)            echo "Not Seen — In only" ;;
        notseen-both)              echo "Not Seen — In and Out" ;;
        notseen-outonly)           echo "Not Seen — Out only" ;;
        seen-inonly)               echo "Seen — In only" ;;
        seen-both)                 echo "Seen — In and Out" ;;
        seen-outonly)              echo "Seen — Out only" ;;
        result-inonly-failed)      echo "Result In only — last transfer Error" ;;
        result-inonly-processed)   echo "Result In only — last transfer OK" ;;
        result-both-failed)        echo "Result In and Out — last transfer Error" ;;
        result-both-processed)     echo "Result In and Out — last transfer OK" ;;
        result-outonly-failed)     echo "Result Out only — last transfer Error" ;;
        result-outonly-processed)  echo "Result Out only — last transfer OK" ;;
    esac
}

# Materialize the three DERIVED coverage TSVs (partners / applications /
# domains) next to showseen.sh's entity TSVs — idempotent and cheap; every
# report script that reads them calls this first.
ensure_pda_tsvs() {
    logicals_tsv            # $COVSRC/logicals.tsv (skipped when its inputs are missing)
    external_partners_tsv   # $COVSRC/partners.tsv (skipped likewise)
    internal_apps_tsv       # $COVSRC/applications.tsv (skipped likewise)
    internal_domains_tsv    # $COVSRC/domains.tsv (skipped likewise)
    bl_tsv                  # $COVSRC/bl.tsv (skipped likewise)
}
