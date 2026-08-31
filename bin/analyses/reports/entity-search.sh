#!/usr/bin/env bash
#
# entity-search.sh — a single searchable index of EVERY entity. One row
# per entity, the name linked to its detail page where one exists; report.js's
# Search box (with * and ? wildcards and and/or) filters across every type at once
# and the table STARTS EMPTY (rows appear only once a search term is entered).
#
# Columns: Name, Direction, Type, Error, OK, Last seen. The Error/OK counts
# come from the per-entity summaries (account.rpt etc.) reused verbatim, so
# the numbers match the entity pages. "Last seen" is the newest _files.tsv
# entry attributed to the entity (ccyy-mm-dd hh:mm:ss — see seen_lookup). No
# drill payloads are emitted (keeps the pages light).
#
# Two kinds of rows (as before):
#   1. Entities that HAVE a detail page — accounts, subscriptions (transfer
#      sites), logins, remote hosts — read from the per-entity
#      descriptors details.sh writes to data/details/<sub>/<slug>.rpt.
#   2. CONFIGURED accounts, subscriptions, logins and hosts
#      that never appear in the logs — read from the
#      bin/flow-manager.sh caches (data/flow-manager/_*.tsv, built from the partners.json /
#      subscriptions.json exports); shown with 0 counts. Plus an IP alias row
#      per cached remote host.
#   3. WHITELISTED IPs (type "Whitelist", data/flow-manager/xref/_accounts-white.tsv):
#      one row per (allowing account, IP), linked to that ACCOUNT's detail
#      page — a whitelisted IP never gets a page of its own.
#
# A TRANSFER-data report housed with the ANALYSES scripts (like
# cross-reference.sh / seen-in-server-log.sh): it sources the transfer lib and
# writes a transfer rpt, but must run in the ANALYSES stage — its PDA seen
# flags read coverage/{partners,applications,domains}.tsv, which only
# ensure_pda_tsvs (bin/analyses/lib.sh, called by the pda/coverage reports)
# materializes. Run from the transfer stage, a from-scratch build had no PDA
# TSVs yet and every no-count application/domain/partner rendered not-seen.
# The transfer outputs it reads (entity summary .rpts, the detail .rpts,
# details/*/_slugmap.tsv, showseen's coverage TSVs) are all ready by then.
#
# Usage:
#   ./entity-search.sh    # -> data/entity-search.rpt
#
set -euo pipefail

# entity-search.sh mostly reads the .rpt other reports wrote and does not
# tokenize; the ONE parse cache it reads is $FILES (the Last-seen column), so
# it calls ensure_parsed like every other $FILES consumer. lib.sh also
# provides the shared paths (REPORTS_DIR, SERVER_CACHE, IP_DIR, CONFIG_DIR).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../transfer/lib.sh"
DETAILS_DIR="$REPORTS_DIR/details"

# Configured account/subscription lists: the bin/flow-manager.sh caches (data/flow-manager/,
# built from the partners.json / subscriptions.json exports). ensure_config
# refreshes them; a missing cache file is skipped (empty configured list).
ensure_config
ensure_parsed

# Inputs, all of them whole trees: the per-entity detail .rpt + slugmaps
# (details.sh), the config base/xref caches, showseen's coverage TSVs and the
# reverse-DNS cache. It reads no parse cache of its own — skip_if_fresh still
# watches those, which is harmless (a reparse invalidates the details anyway).
# The DNS dep is the map file itself, never the whole input/<env>/ip/ dir.
skip_if_fresh "$REPORTS_DIR/entity-search.rpt" "${BASH_SOURCE[0]}" \
    "$DETAILS_DIR" "$CONFIG_BASE" "$CONFIG_XREF" "$REPORTS_DIR/coverage" "$IP_HOSTS_FILE" "$FILES" \
    "$UNKNOWN_DIR"   # unk_lookup reads the unknown/ sidecars directly — an undeclared dep would leave stale search rows when only a sidecar changed

# slugify(), ported to awk from bin/publish_lib.sh (lowercase, non-alnum runs -> a
# single '-', trim leading/trailing '-'), so slugs here match the detail filenames.
SLUG_AWK='function slug(x){ x=tolower(x); gsub(/[^a-z0-9]+/,"-",x); sub(/^-+/,"",x); sub(/-+$/,"",x); return x }'

# A configured-entity list from the bin/flow-manager.sh caches — same source Show
# Seen uses. Tolerates a missing cache file (emits nothing).
config_list() { [ -f "$CONFIG_BASE/$1" ] || return 0; cat "$CONFIG_BASE/$1"; }

# ---- (1) every entity page (seen AND configured-only) ------------------------
# Emit "name<TAB>TypeLabel<TAB>sub<TAB>slug<TAB>seen" for one row per entity —
# details.sh writes one <slug>.rpt per entity (every configured name has one
# now, direction in the slug). slug = filename; name = the TITLE value minus
# its "<Type>: " prefix; seen = the page's META seen flag (0 = configured but
# never logged).
collect() {   # $1 sub-dir  $2 type label
    local sd=$1 label=$2 f files=()
    shopt -s nullglob
    files=("$DETAILS_DIR/$sd"/*.rpt)
    shopt -u nullglob
    [ ${#files[@]} -gt 0 ] || return 0
    # Field 7 is the page's XXX/YYY connection/movement pair, CAPTURED from the
    # title rather than only stripped: it is the Direction column downstream.
    # (Field 6 stays empty — it is collect_locations' subscription name.)
    awk -F'\t' -v sd="$sd" -v label="$label" '
        FNR==1 { if (nm != "") print nm "\t" label "\t" sd "\t" sl "\t" sn "\t\t" dp
                 sl=FILENAME; sub(/.*\//,"",sl); sub(/\.rpt$/,"",sl); nm=""; sn=1; dp="" }
        $1=="TITLE" { nm=$2; dp=""
                      if (match(nm, /^[A-Z?]+\/[A-Z?]+: /)) dp=substr(nm, 1, RLENGTH-2)
                      sub(/^[A-Z?]+\/[A-Z?]+: /,"",nm)   # "IN/OUT: " — the XXX/YYY connection/movement prefix (IN|OUT|BOTH|?)
                      sub(/^[^:]*: /,"",nm) }            # "<Type>: " — the label; a prefix-less page (neither side known) starts here
        $1=="META" && $2=="seen" { sn=$3 }
        END { if (nm != "") print nm "\t" label "\t" sd "\t" sl "\t" sn "\t\t" dp }
    ' "${files[@]}"
}

# "ip<TAB>endpoint" for every address the config maps to a host. One read of
# input/<env>/ip/ip-hosts.tsv. With reverse DNS gone this is only the configured
# endpoints' addresses, so the alias rows it feeds collapse from one per cached
# address (~4,200) to one per real endpoint address.
hostname_pairs() {
    [ -f "$IP_HOSTS_FILE" ] || return 0
    awk -F'\t' '$1 != "" && $2 != "" { sub(/\r$/, "", $2); print $1 "\t" $2 }' "$IP_HOSTS_FILE"
}

# The pages cover EVERYTHING — every logged entity plus every configured name
# (details.sh writes a page per config name, seen or not), for all ten types.
seen_rows=$( {
    collect accounts          "Account"
    collect subscriptions    "Subscription"
    collect logins            "Login"
    collect hosts             "Remote Host"
    collect logicals          "Logical"
    collect partners          "Partner"
    collect applications      "Application"
    collect domains           "Domain"
    collect bl                "BL"
} )

# ---- (2b) Source / Target: the From / To locations of every subscription -----
# The Subscription detail page's Features table carries a "From" and a "To" row
# (the source and target directory + file mask — _sum_locations in details.sh).
# Emit each as its own searchable row: the NAME is the full path (directory +
# mask reconstructed from the @{mask=…} cell), type "Source"/"Target", LINKED to
# that subscription's detail page (a path has no page of its own). seen = the
# subscription's own seen flag.
collect_locations() {
    local files=()
    shopt -s nullglob
    files=("$DETAILS_DIR/subscriptions"/*.rpt)
    shopt -u nullglob
    [ ${#files[@]} -gt 0 ] || return 0
    # A subscription's REMOTE (partner) location gets " @ <host>" appended so the
    # search shows WHERE that path lives (e.g. "/some/dir @ sftp-test.lifetime.nl").
    # The remote side is the partner endpoint we dial (_subscriptions-hosts.tsv,
    # populated only for out-connection subscriptions); the FILE-MOVEMENT direction
    # (_subscriptions-flowdir.tsv) picks which of From/To is that remote side —
    # From when the file flows IN (a pull), To otherwise — exactly as details.sh's
    # _sum_locations assigns them. No configured host -> nothing appended (the
    # local path stays bare).
    awk -F'\t' -v HF="$CONFIG_XREF/_subscriptions-hosts.tsv" -v FF="$CONFIG_XREF/_subscriptions-flowdir.tsv" '
        BEGIN {
            # explicit if (not a ?: + concat one-liner — mawk and BSD awk parse
            # the ternary/concatenation precedence differently, which spliced a
            # stray ", " before the first host)
            while ((getline ln < HF) > 0) {
                n = split(ln, a, "\t")
                if (n >= 2 && a[2] != "") {
                    k = toupper(a[1])
                    if (k in host) host[k] = host[k] ", " a[2]
                    else           host[k] = a[2]
                }
            }
            while ((getline ln < FF) > 0) { n = split(ln, a, "\t"); if (n >= 2) fdir[toupper(a[1])] = a[2] }
        }
        # "@{mask=<sep+mask>}<dir>" -> "<dir><sep+mask>" (the full path as displayed); else the cell verbatim
        function fullpath(cell,   p, x, y) {
            if (substr(cell, 1, 7) == "@{mask=") { p = index(cell, "}"); x = substr(cell, 8, p - 8); y = substr(cell, p + 1); return y x }
            return cell
        }
        # 6th field = the SUBSCRIPTION name: Source/Target inherit the
        # subscription counts (Files, Error, OK) and result tint downstream.
        function flush(   k, h, fh, th) {
            if (slug == "") return
            k = toupper(nm); h = host[k]; fh = ""; th = ""
            if (h != "") { if (fdir[k] == "in") fh = " @ " h; else th = " @ " h }   # remote side gets the host
            if (frm != "") print frm fh "\tSource\tsubscriptions\t" slug "\t" seen "\t" nm
            if (to  != "") print to  th "\tTarget\tsubscriptions\t" slug "\t" seen "\t" nm
        }
        FNR==1 { flush(); slug=FILENAME; sub(/.*\//,"",slug); sub(/\.rpt$/,"",slug); seen=1; frm=""; to=""; nm=""; infeat=0 }
        $1=="TITLE" { nm=$2; sub(/^[A-Z?]+\/[A-Z?]+: /,"",nm); sub(/^[^:]*: /,"",nm) }   # "XXX/YYY: <Type>: <name>" -> name
        $1=="TABLE" { infeat = ($2 == "Features") }
        $1=="META" && $2=="seen" { seen=$3 }
        # a "-" value is the details.sh placeholder for a side with no configured
        # directory (From/To are always both present there) — skip it, not a path.
        infeat && $1=="ROW" && $2=="From" { frm=($3=="-" ? "" : fullpath($3)) }
        infeat && $1=="ROW" && $2=="To"   { to=($3=="-" ? "" : fullpath($3)) }
        END { flush() }
    ' "${files[@]}"
}
location_rows=$(collect_locations)

# ---- (3) IP rows for every cached remote host -------------------------------
# The hosts slugmap (comprehensive: every page name -> its slug) resolves the
# alias link; a raw IP that is itself a host entity keeps its own page (no
# alias row). A WHITELISTED IP is skipped here — it already has a "Whitelist"
# row (an inbound source address, not an outbound remote-host endpoint), so a
# "Remote Host (IP)" alias for it would be a wrong duplicate.
HOSTS_SLUGMAP="$DETAILS_DIR/hosts/_slugmap.tsv"
host_ip_aliases=""
if [ -f "$HOSTS_SLUGMAP" ]; then
    host_ip_aliases=$(awk -F'\t' -v wlf="$CONFIG_XREF/_accounts-white.tsv" '
        BEGIN { while ((getline ln < wlf) > 0) { n=split(ln, a, "\t"); if (n>=2 && a[2]!="") wl[tolower(a[2])]=1 } }
        FNR==NR { if (NF>=2) ovr[tolower($1)]=$2; next }
        { ip=$1; host=tolower($2)
          if (tolower(ip) in ovr) next            # the IP is itself a host entity -> its own page
          if (tolower(ip) in wl) next             # whitelisted IP -> shown as Whitelist only
          if (host!="" && (host in ovr)) print ip "\tRemote Host (IP)\thosts\t" ovr[host] "\t1"
          else                           print ip "\tRemote Host (IP)\t\t\t0" }
    ' "$HOSTS_SLUGMAP" <(hostname_pairs))
fi

# ---- (4) whitelisted IPs -----------------------------------------------------
# Every (account, allowed IP) pair from bin/flow-manager.sh's _accounts-white.tsv
# (the partner AllowIP whitelist, expanded): searchable by IP, type
# "Whitelist", LINKED to the ALLOWING account's detail page — a whitelisted IP
# has no page of its own. seen=0 (configuration, not log activity), so the
# rows live on the All / Not Seen views; an IP allowed by several accounts
# gets one row per account. The account slug comes from that account's detail
# page (collect() above), so slug collisions resolve exactly like its own row;
# an account with no page leaves the IP row unlinked.
whitelist_ips=$( { printf '%s\n' "$seen_rows" | awk -F'\t' '$2=="Account" { print "S\t" $1 "\t" $4 }'
                   [ ! -f "$CONFIG_XREF/_accounts-white.tsv" ] || awk '{ print "W\t" $0 }' "$CONFIG_XREF/_accounts-white.tsv"
                 } | awk -F'\t' '
    $1=="S" { aslug[toupper($2)]=$3; next }
    { k=toupper($2); s=(k in aslug)?aslug[k]:""
      print $3 "\tWhitelist\t" (s==""?"":"accounts") "\t" s "\t0" }')

# ---- merge, sort by TYPE then name (case-folded) -----------------------------
# Row order: Logical, Partner, Account, Login, Host, IP (Remote Host (IP) +
# Whitelist share one slot, interleaved by address), Subscription, Domain,
# Application, Flow — name-sorted within each type. (The PDA entities come from their
# detail pages via collect(), like the classic five — no separate config-list
# source anymore.)
rows=$(printf '%s\n%s\n%s\n%s\n' "$seen_rows" "$host_ip_aliases" "$whitelist_ips" "$location_rows" \
       | grep -v '^$' | awk -F'\t' '
           BEGIN { r["Logical"]=1; r["Partner"]=2; r["Account"]=3; r["Login"]=4; r["Remote Host"]=5
                   r["Remote Host (IP)"]=6; r["Whitelist"]=6
                   r["Subscription"]=7; r["Domain"]=8; r["Application"]=9; r["BL"]=10
                   r["Source"]=11; r["Target"]=12 }
           { rk=r[$2]; if (rk == "") rk=99; print rk "\t" $0 }' \
       | LC_ALL=C sort -t$'\t' -k1,1n -k2,2 -k7,7 -f | cut -f2-)
# The -k7,7 tiebreak orders Source/Target rows that share a PATH by their
# SUBSCRIPTION name (location_rows field 6 -> field 7 after the rank prefix),
# so the per-path grouping below (and its subrows payload) is deterministic.

# ---- Files counts per entity (from the entity summaries) --------------------
# Type label -> the entity report basename that holds its counts.
typebase() { case $1 in
    Account) echo account ;; Subscription) echo subscription ;; Login) echo login ;;
    "Remote Host") echo remote-host ;; Logical) echo logical ;; BL) echo bl ;;
    Partner) echo partner ;; Application) echo application ;; Domain) echo domain ;; esac; }

# Emit "TYPE<TAB>name<TAB>count<TAB>failed<TAB>processed<TAB>ccf<TAB>ccp"
# from the FIRST (Summary) table of each <base>.rpt. ccf/ccp are the
# @data:coreids-{failed,processed} drill lists, reused verbatim for the drill.
count_lookup() {
    local tl base f
    for tl in "Account" "Subscription" "Login" "Remote Host" "Logical" "Partner" "Application" "Domain" "BL"; do
        base=$(typebase "$tl"); f="$REPORTS_DIR/$base.rpt"; [ -f "$f" ] || continue
        awk -F'\t' -v tl="$tl" '
            /^TABLE\t/ { t++ }
            t==1 && $1=="ROW" {
                ccf=""; ccp=""; bk=""
                for (i=6;i<=NF;i++) {
                    x=$i
                    if      (x ~ /^@data:coreids-failed=/)    { sub(/^@data:coreids-failed=/,"",x);    ccf=x }
                    else if (x ~ /^@data:coreids-processed=/) { sub(/^@data:coreids-processed=/,"",x); ccp=x }
                    else if (x ~ /^@data:buckets=/)           { sub(/^@data:buckets=/,"",x);           bk=x }
                }
                print tl "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\t" ccf "\t" ccp "\t" bk
            }' "$f"
    done
}

# (The former "Server log" yes/no column is GONE: the server-log mentions now
# live in ONE place — the "Last 10 server log lines" table on a not-seen
# entity's DETAIL page, details.sh srv_lines_table.)

# ---- result lookup (row tint) ------------------------------------------------
# Every row is tinted by its entity's RESULT — the base caches' third field
# (bin/build/result.sh): green / orange / red, carried as @data:res. Types map to
# their base cache; a name without an entry (e.g. a raw-IP host alias) gets
# no tint. Emits "TYPE<TAB>name<TAB>result".
res_lookup() {
    local spec t f
    for spec in "Account:_accounts" "Subscription:_subscriptions" "Login:_logins" \
                "Remote Host:_hosts" "Logical:_logicals" "Partner:_partners" \
                "Application:_apps" "Domain:_domains" "BL:_bl" "Whitelist:_white"; do
        t=${spec%:*}; f="$CONFIG_BASE/${spec##*:}.tsv"
        if [ -f "$f" ]; then
            # blue = a server-log-only entity (bin/build/seen-in-server-log.sh), a real 4th result value
            awk -F'\t' -v t="$t" -v OFS='\t' '$3 == "green" || $3 == "orange" || $3 == "red" || $3 == "blue" { print t, $1, $3 }' "$f"
        fi
    done
}

# ---- fake-file seed lookup (forced red) ---------------------------------------
# The data/unknown sidecars list the server-log-only entities bin/build/seen-in-server-log.sh
# fabricates Failed files for. A seed whose base result is not green/red is
# forced RED: its only "transfer" IS the fake Failed row, and an unconfigured
# seed has no base-cache row at all. Emits "TYPE<TAB>name".
unk_lookup() {
    local spec t f
    for spec in "Account:accounts" "Subscription:sites" "Login:logins" "Remote Host:hosts"; do
        t=${spec%:*}; f="$UNKNOWN_DIR/${spec##*:}.tsv"
        if [ -f "$f" ]; then
            awk -F'\t' -v t="$t" -v OFS='\t' '$1 != "" { print t, $1 }' "$f"
        fi
    done
}

# (Server-log-only entities are result==blue in the base cache — res_lookup
# already tints them blue; no separate overlay.)

# ---- emit the .rpt -----------------------------------------------------------
# ONE page, one table: report.js's Search configuration panel (the `esearch`
# TABLE modifier) provides the All/Seen/Not-seen view and the per-entity-type
# checkboxes client-side.
cdrill=""
OUT="$REPORTS_DIR/entity-search.rpt"

# Coverage-TSV seen flags (showseen's healed universe; reports.sh runs this
# script AFTER showseen so hosts.tsv is complete): a name whose Files are all
# credited to a sibling group — a shared endpoint's co-tenant org, one org of
# a two-partner account, a raw-IP endpoint logging under its PTR name — has
# no counts of its own, but the coverage TSVs mark it seen. The Seen/Not seen
# view buttons must agree with the Entities views, which read the same files
# (render_entity_report's ghost rows). A missing TSV degrades to count-only.
cov_lookup() {
    local spec f
    for spec in "Logical:logicals" "Partner:partners" "Application:applications" "Domain:domains" "BL:bl" "Remote Host:hosts"; do
        f="$REPORTS_DIR/coverage/${spec#*:}.tsv"
        [ -f "$f" ] || continue
        LC_ALL=C awk -F'\t' -v t="${spec%%:*}" '
            t == "Partner" && $4 ~ /^hosts\// { next }   # endpoint alias rows, not partner names
            $3 == "1" { print t "\t" $1 }' "$f"
    done
}

# ---- Last-seen lookup (from the logical-transfer cache) ----------------------
# 'Last seen' = the newest _files.tsv entry attributed to the entity, shown
# "ccyy-mm-dd hh:mm:ss" (cols 4+5, milliseconds stripped; newest by the col 6
# sortkey). Attribution matches the site: account col 3, subscription col 12,
# login col 14, host col 15 (the same map serves the Whitelist / IP-alias
# rows — an in-side raw IP sits in that column), domain col 19; PARTNER =
# col 20 ∪ col 12 over _subscriptions-partners and APPLICATION = col 18 ∪
# col 3 over _accounts-apps — the union attribution every partner/application
# consumer applies. Emits "TYPE<TAB>NAME<TAB>stamp", the name uppercased (the
# tuple join keys case-folded).
seen_lookup() {
    [ -f "$FILES" ] || return 0
    awk -F'\t' -v SPMAP="$CONFIG_XREF/_subscriptions-partners.tsv" -v APMAP="$CONFIG_XREF/_accounts-apps.tsv" \
        -v PLMAP="$CONFIG_XREF/_profiles-logicals.tsv" -v SLMAP="$CONFIG_XREF/_subscriptions-logicals.tsv" \
        -v SBMAP="$CONFIG_XREF/_subscriptions-bl.tsv" '
        function uni_load(f, M,   l, z, n, k) {
            while ((getline l < f) > 0) { n = split(l, z, "\t")
                if (n >= 2 && z[1] != "" && z[2] != "") { k = toupper(z[1])
                    M[k] = M[k] (M[k] == "" ? "" : "\037") z[2] } }
            close(f) }
        BEGIN { uni_load(SPMAP, SP); uni_load(APMAP, AP); uni_load(PLMAP, PL); uni_load(SLMAP, SL); uni_load(SBMAP, SB) }
        function upd(t, nm,   k) {
            if (nm == "") return
            k = t "\t" toupper(nm)
            if ($6 > best[k]) { best[k] = $6; ts[k] = $4 " " substr($5, 1, 8) }
        }
        function upds(t, set,   n, i, Z) { n = split(set, Z, "\037"); for (i = 1; i <= n; i++) upd(t, Z[i]) }
        $4 == "" { next }
        {
            upd("Account", $3); upd("Subscription", $12)
            upd("Login", $14); upd("Remote Host", $15); upd("Domain", $19)
            p = $20; if ($12 != "" && (toupper($12) in SP)) p = p (p == "" ? "" : "\037") SP[toupper($12)]
            upds("Partner", p)
            a = $18; if ($3 != "" && (toupper($3) in AP)) a = a (a == "" ? "" : "\037") AP[toupper($3)]
            upds("Application", a)
            lg = ""; if ($13 != "" && (toupper($13) in PL)) lg = PL[toupper($13)]
            if ($12 != "" && (toupper($12) in SL)) lg = lg (lg == "" ? "" : "\037") SL[toupper($12)]
            upds("Logical", lg)
            b = ""; if ($12 != "" && (toupper($12) in SB)) b = SB[toupper($12)]
            upds("BL", b)
        }
        END { for (k in best) print k "\t" ts[k] }
    ' "$FILES"
}

# Tag each lookup stream (C=counts, R=rows), feed them in that order to one
# awk (the count lookup loads before the R rows). Output: one neutral tuple
# per entity, formatted into the view table below — namecell, type, seen,
# count, failed, processed, …, last seen.
tuples=$( {
    res_lookup                    | awk 'NF{print "B\t" $0}'
    printf '%s\n' "$seen_rows"     | awk -F'\t' 'NF>=7 && $7!="" { print "P\t" $3 "\t" $4 "\t" $7 }'
    unk_lookup                    | awk 'NF{print "U\t" $0}'
    count_lookup                  | awk 'NF{print "C\t" $0}'
    cov_lookup                    | awk 'NF{print "V\t" $0}'
    seen_lookup                   | awk 'NF{print "S\t" $0}'
    printf '%s\n' "$rows"         | awk 'NF{print "R\t" $0}'
} | awk -F'\t' '
    $1=="B" { res[$2 SUBSEP toupper($3)] = $4; next }
    $1=="P" { pmap[$2 SUBSEP $3] = $4; next }          # (details sub-dir, slug) -> the XXX/YYY pair of that page
    $1=="U" { useed[$2 SUBSEP toupper($3)] = 1; next }
    $1=="V" { covseen[$2 SUBSEP toupper($3)] = 1; next }
    $1=="S" { lseen[$2 SUBSEP $3] = $4; next }         # (type, NAME uppercased) -> newest _files stamp
    $1=="C" { k=$2 SUBSEP $3; cnt[k]=$4; cf[k]=$5; cp[k]=$6; df[k]=$7; dp[k]=$8; bk[k]=$9; next }
    $1=="R" {
        name=$2; type=$3; sd=$4; slug=$5; seen=$6; subname=$7
        # Source/Target are subscription attributes (a From/To path): they
        # inherit the SUBSCRIPTION counts (Files, Error, OK) and result tint,
        # so the count/result lookups key on Subscription + subname.
        lk=type; ln=name
        if ((type=="Source" || type=="Target") && subname!="") { lk="Subscription"; ln=subname }
        k=lk SUBSEP ln; has=(k in cnt)
        # PDA + Source/Target seen: refresh from the summary counts so the page
        # META and the entity summaries cannot drift. A sibling-credited name
        # (no counts of its own, coverage TSV says seen) stays SEEN.
        if (type=="Partner" || type=="Application" || type=="Domain" || type=="Logical" || type=="BL")
            seen = (has || ((type SUBSEP toupper(name)) in covseen)) ? 1 : 0
        else if (type=="Source" || type=="Target") seen = has ? 1 : 0
        else if (type=="Remote Host" && seen != "1" && ((type SUBSEP toupper(name)) in covseen)) seen = 1
        # no activity (not-seen configured names, IP aliases) -> leave the
        # count/Error/OK cells blank rather than showing 0/0/0.
        c=has?cnt[k]:""; f=has?cf[k]:""; p=has?cp[k]:""
        # data/unknown seeds (server-log-only) with no green/red/blue result -> red
        # The Direction column is the CONNECTION/MOVEMENT pair (out/in) the
        # detail page of the entity is titled with. A row with no page of its own —
        # a Whitelist IP, a Remote Host (IP) alias, a Source/Target path —
        # inherits the pair of the page it LINKS to, exactly as it already
        # inherits the counts and tint of that page too. render_rpt.awk lowercases it.
        dd = $8
        if (dd == "" && sd != "" && slug != "") dd = pmap[sd SUBSEP slug]
        # Last seen: keyed like the counts (Source/Target already inherit the
        # subscription via lk/ln); a Whitelist IP or IP alias is a host-column
        # value, so those look up the Remote Host map under their own name.
        lt = lk
        if (type == "Whitelist" || type == "Remote Host (IP)") lt = "Remote Host"
        lsn = lseen[lt SUBSEP toupper(ln)]
        rr = res[lk SUBSEP toupper(ln)]
        if (rr != "green" && rr != "red" && rr != "blue" && ((lk SUBSEP toupper(ln)) in useed)) rr = "red"
        # a server-log-only entity (result==blue) counts as SEEN with BLANK counts
        # (no real transfer): its detail page is a never-seen page.
        if (rr == "blue") { seen = 1; c = ""; f = ""; p = "" }
        # EVERY row gets a color: a row with no result status (raw-IP hosts, IP
        # aliases, the odd unconfigured account/login) is colored by its Files —
        # filled -> green (it moved files), blank -> orange (none).
        if (rr == "") rr = (c != "") ? "green" : "orange"
        # Source/Target -> a LOC pre-tuple grouped by (type, PATH) downstream:
        # a path used by >1 subscription becomes one aggregate row. Carry the
        # raw path (name), the subscription name + link parts, seen and counts.
        if (type=="Source" || type=="Target") {
            # 12 fields after LOC (type,name,subname,sd,slug,seen,c,f,p,rr,dd,
            # lastseen) — the subscription res (its row colour) is $11
            # downstream, its direction $12 and its last-seen stamp $13
            printf "LOC\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", type, name, subname, sd, slug, seen, c, f, p, rr, dd, lsn
            next
        }
        # rows with a page link to it: seen entities to their own detail
        # page, Whitelist rows to the ALLOWING account page — other not-seen
        # rows carry no sd/slug. The row tint is @data:res, not seen-ness.
        if (sd!="" && slug!="") nc="@{link=" sd "/" slug "}" name
        else                    nc=name
        # FIN = a final tuple (10 fields: namecell, type, seen, files, err, ok,
        # res, subrows, direction, last seen); non-location rows carry an
        # empty subrows field.
        printf "FIN\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t%s\t%s\n", nc, type, seen, c, f, p, rr, dd, lsn
    }' \
  | awk -F'\t' -v SEP="\037" '
    # STAGE 2 — Source/Target PATH grouping. FIN lines pass straight through
    # (already final tuples). LOC lines are grouped by (type, path): the rows[]
    # sort ordered them by type then path then subscription, so a streaming
    # group-by-change is fully deterministic (no awk hash-iteration order).
    # A path used by ONE subscription -> a normal linked row, keeping that
    # SUBSCRIPTION colour (grr). A path used by N>1 -> ONE aggregate row
    # "<path> (N)" whose Error/OK are the SUM across the N subscriptions; its row
    # colour is purely COUNTS-based (green if the path moved anything — any Error
    # or OK — else orange for configured-but-never-seen), NOT a rollup of the
    # member statuses. Plus a @data:subrows drill payload (one
    # "<sub>|<href>|<files>|<err>|<ok>|<res>" entry per subscription, \x1f-joined)
    # that report.js expands into per-subscription rows, each keeping its OWN
    # subscription colour (the res field of the entry).
    function aggcolor() {
        if (gsumf > 0 || gsump > 0) return "green"
        return "orange"
    }
    function flush(  nc, dc, df, dp, hascount) {
        if (gn==0) return
        if (gn==1) {
            nc = (gsd!="" && gslug!="") ? "@{link=" gsd "/" gslug "}" gpath : gpath
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t%s\t%s\n", nc, gtype, gseen, gc, gf, gp, grr, gdd, gls
        } else {
            # show counts only when there ARE real Error/OK counts (a blue-only
            # aggregate is "seen" but has none) — so an orange (no-counts) row is
            # blank, matching aggcolor() and every other never-seen row.
            hascount = (gsumf > 0 || gsump > 0)
            dc = hascount ? gsumc : ""; df = hascount ? gsumf : ""; dp = hascount ? gsump : ""
            # Direction on an AGGREGATE path row only when every subscription
            # using it agrees — a path shared by an in and an out flow has no
            # single direction, so it shows none (gdirmix). Last seen = the
            # NEWEST stamp across the member subscriptions.
            printf "%s (%d)\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", gpath, gn, gtype, ganyseen, dc, df, dp, aggcolor(), gpay, (gdirmix ? "" : gdd), gls
        }
    }
    $1=="FIN" { print substr($0, 5); next }
    $1=="LOC" {
        type=$2; path=$3; subname=$4; sd=$5; slug=$6; seen=$7; c=$8; f=$9; p=$10; rr=$11; dd=$12; ls=$13
        key=type SUBSEP path
        if (key != curkey) {
            flush(); curkey=key; gtype=type; gpath=path; gn=0
            gsumc=0; gsumf=0; gsump=0; ganyseen=0; gpay=""
            gsd=""; gslug=""; gseen=0; gc=""; gf=""; gp=""; grr=""; gdd=""; gdirmix=0; gls=""
        }
        gn++
        if (gn > 1 && dd != gdd) gdirmix=1
        gdd=dd
        gsumc += (c==""?0:c); gsumf += (f==""?0:f); gsump += (p==""?0:p)
        if (seen=="1") ganyseen=1
        if (ls > gls) gls=ls                                         # ISO stamps: string max = newest
        gsd=sd; gslug=slug; gseen=seen; gc=c; gf=f; gp=p; grr=rr     # remembered for the gn==1 case
        href = (slug!="") ? "details/" sd "/" slug ".html" : ""
        entry = subname "|" href "|" c "|" f "|" p "|" rr "|" ls
        gpay = (gpay=="") ? entry : gpay SEP entry
    }
    END { flush() }')

ntot=$(printf '%s\n' "$tuples" | awk 'NF{n++} END{print n+0}')
nseen=$(printf '%s\n' "$tuples" | awk -F'\t' '$3=="1"{n++} END{print n+0}')
nnot=$((ntot - nseen))
# footer sums for the numeric columns (report.js re-totals per search/view)
IFS=$'\t' read -r tsc tsf tsp <<< "$(printf '%s\n' "$tuples" | awk -F'\t' '{c+=$4; f+=$5; p+=$6} END{printf "%d\t%d\t%d", c+0, f+0, p+0}')"

{
    printf 'TITLE\tSearch\n'
    printf 'DESC\tSearch every account, subscription, login, remote host, logical flow, partner, application, domain, BL tag and subscription source/target path by name — with its Error/OK split and when it last moved a file.\n'
    printf 'INTRO\tType in the box below to search **every configured or logged entity by name** — the checkboxes narrow the kinds (none checked = all). Wildcards and operators are explained right under the box; rows tint by each entity'\''s status.\n'
    # ONE page, one table (no All/Seen/Not-Seen tab pages, no intro/notes —
    # the how-to lives on the help page). The `esearch` modifier makes
    # report.js insert the collapsed "Search configuration" panel: the
    # All / Seen / Not seen view plus the ten entity-type checkboxes
    # (defaults: Account and Flow off), all filtered client-side. Rows
    # carry no drill payloads and the page no From/To date filter
    # (render_report clears CUR_DATES); rows are tinted by the entity
    # RESULT (@data:res -> the tr[data-res] rules in style.css).
    # There is no "Seen" column and no Seen / Not seen view buttons: the row
    # COLOUR carries seen-ness at a glance and every row has one (result, else
    # Files-derived), so no per-row seen flag is emitted at all.
    printf 'TABLE\t\twide\tstartempty\tesearch%s\n' "$cdrill"
    # The Files column was removed (2026-07): Files = Error + OK, so the split
    # carries it. The tuple/subrows payload still hold files internally (col $4 /
    # payload field 3) — only the rendered column is dropped, here and in the
    # subrows renderer (report.js setupSubrows) + the notseen/server column-hide.
    # Direction is column 2 (tuple field $9), the same in/out/both the base
    # caches carry and the Entities pages already show, rendered verbatim.
    # Last seen (tuple field $10) is the LAST column: the newest _files.tsv
    # stamp, blank for a name that never moved a file.
    printf 'HEAD\tName\tDirection\tType\tError\tOK\tLast seen\n'
    printf 'KIND\ttext\ttext\ttext\tnumfailed\tnumprocessed\ttext\n'
    printf '%s\n' "$tuples" | awk -F'\t' 'NF{
        r  = ($7 != "") ? "\t@data:res=" $7 : ""
        sr = ($8 != "") ? "\t@data:subrows=" $8 : ""    # multi-use Source/Target: per-subscription drill
        # NO @data:seen: it existed only for the All/Seen/Not seen/Server view
        # buttons, which are gone. Every CSS rule and every report.js reader of
        # data-seen is gated on table[data-seenrows] or table[data-seenmode],
        # and this table carries neither — so it painted and filtered nothing
        # while costing 104 KB in the row payload. The row COLOUR is @data:res.
        printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s%s%s\n", $1, $9, $2, $5, $6, $10, r, sr }'
    printf 'TOTAL\tTotal (%d rows)\t\t\t@{class=num failed}%d\t@{class=num processed}%d\t\n' "$ntot" "$tsf" "$tsp"
    printf 'NOTE\tRow colors: **green** = last transfer OK (or, for a row with no status, one that moved files), **red** = last transfer Error or server-log errors after the last OK transfer, **orange** = configured but never seen (or moved no files), **blue** = surfaced only in the Server logs.\n'
    printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
echo "Data written to $OUT." >&2
