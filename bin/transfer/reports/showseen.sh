#!/usr/bin/env bash
#
# showseen.sh — cross-reference the CONFIGURED entities against what actually
# shows up in the transfer logs. Five source lists, read from the bin/flow-manager.sh
# caches (built from the partners.json / subscriptions.json config exports):
#   data/flow-manager/base/_accounts.tsv      -> the configured accounts   (partner names)
#   data/flow-manager/base/_subscriptions.tsv -> the configured subscriptions
#   data/flow-manager/base/_logins.tsv        -> the configured logins     (comm-profile login names)
#   data/flow-manager/base/_hosts.tsv         -> the configured hosts      (comm-profile hosts[])
# Emits a per-member .rpt with All / Seen / Not Seen tabs:
#   data/showseen-{accounts,subscriptions,logins,hosts}.rpt
# The Files counts/date-buckets/drill are lifted straight from the entity grid
# summaries (<basename>.rpt) so Show Seen and the entity reports agree.
#
# "Seen" match (case-insensitive, but '-' and '_' are DIFFERENT characters):
#   accounts      — name == an account value (_transfers.tsv col 4), EXACTLY
#   subscriptions — name is a PREFIX of a subscription value (col 6): the parser
#                   keeps the site only up to _SCP_, so col 6 is already the clean
#                   subscription name (usually an exact match; prefix still covers
#                   a longer sub-named variant)
#   logins        — name == a login value (col 5), EXACTLY
#   hosts         — name == a remote-host value (col 16), EXACTLY. A logged host
#                   is the reverse-DNS name of the connecting IP, which can
#                   differ from the configured hostname — such a partner shows
#                   as not seen here even though it connects.
# Only configured names are listed (a logged-but-unconfigured value is not);
# the entity grid reports list every logged value.
# Files = how many logical transfers matched (0 when not seen).
#
# Separator folding ('_' -> '-') is a SEARCH affordance only — never an identity
# rule. partners.json and subscriptions.json carry both spellings as SEPARATE
# entities (FRE-SAPCD-FLANDERIJN and FRE_SAPCD_FLANDERIJN are two accounts, on a
# UC4 and a UC1 flow), so folding them here would merge two entities: one row
# would clobber the other's count, a config-only twin would show up as "seen"
# with its sibling's activity, and both would link to the same detail page.
# Match on the raw name; fold only where a human is typing into the search box.
#
# LINKS honour data/<area>/reports/details/<sub>/_slugmap.tsv, which details.sh
# writes whenever two entity names slugify alike (FRE_SAPCD_FLANDERIJN ->
# fre-sapcd-flanderijn-2, because the hyphen twin already took the bare slug).
# Without it the second name would link to the first one's page. That is why
# this report must run AFTER details.sh (see reports.sh).
#
# Usage:
#   ./showseen.sh    # reads data/flow-manager/_*.tsv + the cache, writes data/showseen-*.rpt
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
mkdir -p "$REPORTS_DIR"


shopt -s nullglob
files=("$INPUT_DIR"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "No *.csv in $INPUT_DIR — building from the EMPTY caches (config-only estate)" >&2
fi
ensure_parsed
ensure_config
# one script, MANY outputs — guard on the OLDEST one (any missing output
# builds); deps = the entity summary rpts it lifts rows from, the detail
# slugmaps it resolves links through, and the config caches (base recolors
# flip blue/seen-ness, so base IS a dep — its rewrites are cmp-guarded, a
# no-change recolor keeps the mtime)
_ss_guard=""
for _f in "$REPORTS_DIR"/showseen-{accounts,subscriptions,logins,hosts}.rpt \
          "$REPORTS_DIR"/coverage/{accounts,subscriptions,logins,hosts,whitelist}.tsv; do
    if [ ! -f "$_f" ]; then _ss_guard=""; break; fi
    if [ -z "$_ss_guard" ] || [ "$_ss_guard" -nt "$_f" ]; then _ss_guard="$_f"; fi
done
if [ -n "$_ss_guard" ]; then
    skip_if_fresh "$_ss_guard" "${BASH_SOURCE[0]}" \
        "$REPORTS_DIR"/{account,subscription,login,remote-host}.rpt \
        "$REPORTS_DIR"/details/{accounts,subscriptions,logins,hosts}/_slugmap.tsv \
        "$CONFIG_BASE"/_*.tsv \
        "$CONFIG_XREF/_accounts-logins.tsv" "$CONFIG_XREF/_accounts-hosts.tsv" \
        "$CONFIG_XREF/_subscriptions-logins.tsv" "$CONFIG_XREF/_subscriptions-hosts.tsv"
fi
unset _ss_guard _f
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# (The former per-member "Server log" yes/no column + last-10 drill is GONE:
# the server-log mentions now live in ONE place — the "Last 10 server log
# lines" table on a not-seen entity's DETAIL page, details.sh srv_lines_table.)

# A configured-entity list from the bin/flow-manager.sh caches (ensure_config above
# refreshed them). Tolerates a missing cache file — no config export anywhere —
# by leaving that report's configured list empty, like the old missing-JSON case.
config_list() {
    [ -f "$CONFIG_BASE/$1" ] || { echo "WARNING: data/flow-manager/base/$1 not found — its report will be empty." >&2; return 0; }
    cat "$CONFIG_BASE/$1"
}

# "name<TAB>slug" overrides recorded by details.sh for slug collisions (two entity
# names that slugify alike). Absent on a from-scratch run that has not reached
# details.sh yet — then the plain slugify() fallback applies, as before.
slugmap_lines() {   # $1 = details sub-dir (accounts | subscriptions)
    local f="$REPORTS_DIR/details/$1/_slugmap.tsv"
    [ -f "$f" ] && cat "$f" || true
}

# Turn (name<TAB>seen<TAB>rows<TAB>failed<TAB>processed<TAB>ccf<TAB>ccp<TAB>buckets<TAB>link)
# tuples, sorted by name, into a 3-tab .rpt body (All / Seen / Not Seen).
# $1 = column header for the entity name.
#
# Every table carries EVERY configured entity, each row tagged @data:seen (its
# full-period seen flag) and @data:buckets (raw per-date rows:failed:processed).
# report.js's recalcSeen (keyed by the seenmode= modifier) then makes the date
# filter re-count the numbers AND re-partition seen/not-seen for the chosen
# range: "seen" = >=1 matching row IN RANGE. So a narrowed range hides the
# in-range-inactive rows from the Seen tab and reveals them on the Not-Seen tab.
#
# The link field (col 9) is the seen entity's detail-page path (accounts/<slug> or
# subscriptions/<slug>), empty for a not-seen entity (it has no page). It becomes
# an @{link=…} prefix on the name cell so a seen row links to its detail page —
# see render_cell in bin/publish_lib.sh.
emit_tables() {   # $1 entity-column-header  $2 unit label  $3 drill noun
    awk -F'\t' -v ent="$1" -v ul="$2" -v dn="$3" '
        function namecell(i) { return (lk[i]!="" ? "@{link=" lk[i] "}" : "") nm[i] }
        BEGIN { dm = (dn=="") ? "" : "\tdrill=" dn }                           # unit drill noun (empty => report.js default "File")
        NF { n++; nm[n]=$1; sn[n]=$2; rw[n]=$3; fl[n]=$4; pr[n]=$5; ccf[n]=$6; ccp[n]=$7; bk[n]=$8; lk[n]=$9
             if ($2==1) { nseen++; tr += $3; tf += $4; tp += $5 } }
        END {
            nnot = n - (nseen+0)
            print "TABLE\tAll" dm "\tseenmode=all"
            print "INTRO\tConfigured: " n+0 "  |  Seen: " nseen+0 "  |  Not seen: " nnot   # above the table
            print "HEAD\t" ent "\tSeen\t" ul "\tError\tOK"
            print "KIND\ttext\ttext\tnum\tnumfailed\tnumprocessed"
            # @data:seen tints the whole row (green seen / red not seen); files drill the Error/OK cells.
            for (i=1;i<=n;i++) print "ROW\t" namecell(i) "\t" (sn[i]==1?"yes":"no") "\t" (sn[i]==1?rw[i]:"") "\t" (sn[i]==1?fl[i]:"") "\t" (sn[i]==1?pr[i]:"") "\t@data:coreids-failed=" (sn[i]==1?ccf[i]:"") "\t@data:coreids-processed=" (sn[i]==1?ccp[i]:"") "\t@data:seen=" sn[i] "\t@data:buckets=" bk[i]
            # footer: visible-row count + the numeric column sums (report.js
            # recalcSeen re-totals per view/date range; text cells stay blank)
            print "TOTAL\tTotal (" n+0 " rows)\t\t@{class=num}" tr+0 "\t@{class=num failed}" tf+0 "\t@{class=num processed}" tp+0
            print "TABLE\tSeen" dm "\tseenmode=seen"
            print "INTRO\tSeen in the logs: " nseen+0 " of " n+0 " configured"
            print "HEAD\t" ent "\t" ul "\tError\tOK"
            print "KIND\ttext\tnum\tnumfailed\tnumprocessed"
            for (i=1;i<=n;i++) print "ROW\t" namecell(i) "\t" (sn[i]==1?rw[i]:"") "\t" (sn[i]==1?fl[i]:"") "\t" (sn[i]==1?pr[i]:"") "\t@data:coreids-failed=" (sn[i]==1?ccf[i]:"") "\t@data:coreids-processed=" (sn[i]==1?ccp[i]:"") "\t@data:seen=" sn[i] "\t@data:buckets=" bk[i]
            print "TOTAL\tTotal (" n+0 " rows)\t@{class=num}" tr+0 "\t@{class=num failed}" tf+0 "\t@{class=num processed}" tp+0
            print "TABLE\tNot Seen\tseenmode=notseen"
            print "INTRO\tNot seen in the logs: " nnot " of " n+0 " configured"
            print "HEAD\t" ent
            print "KIND\ttext"
            for (i=1;i<=n;i++) print "ROW\t" namecell(i) "\t@data:seen=" sn[i] "\t@data:buckets=" bk[i]
            print "TOTAL\tTotal (" n+0 " rows)"
        }'
}

foot() { printf 'FOOT\tGenerated on %s from %s file(s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${#files[@]}"; }

# Parse a grid summary .rpt (its FIRST/Summary table) into one line per entity value:
#   value<TAB>count<TAB>failed<TAB>processed<TAB>buckets<TAB>ccf<TAB>ccp
# buckets = @data:buckets ("date:count:failed:processed:bytes,…"); ccf/ccp = the
# @data:coreids-{failed,processed} last-10 drill lists. Show Seen reuses these so its
# Files counts, date re-aggregation and drill match the entity report exactly.
summary_lookup() {   # $1 = <basename>.rpt
    [ -f "$1" ] || return 0
    awk -F'\t' '
        /^TABLE\t/ { t++ }
        t==1 && $1=="ROW" {
            bk=""; cf=""; cp=""
            for (i=6;i<=NF;i++) { x=$i
                if      (x ~ /^@data:buckets=/)           { sub(/^@data:buckets=/,"",x);           bk=x }
                else if (x ~ /^@data:coreids-failed=/)    { sub(/^@data:coreids-failed=/,"",x);    cf=x }
                else if (x ~ /^@data:coreids-processed=/) { sub(/^@data:coreids-processed=/,"",x); cp=x }
            }
            print $2 "\t" $3 "\t" $4 "\t" $5 "\t" bk "\t" cf "\t" cp
        }' "$1"
}

# EXACT-match tuple builder (accounts, logins, hosts): each configured
# name (config_list) matched exactly (case aside) against the grid summary's
# logged values; a seen name links to its detail page (slugmap overrides
# honoured). Three tagged streams: C = the logged values + their counts, O = the
# slug overrides, N = the configured names. C and O must precede N. Output:
#   name<TAB>seen<TAB>count<TAB>failed<TAB>processed<TAB>ccf<TAB>ccp<TAB>buckets<TAB>link
exact_tuples() {   # $1 grid-basename  $2 details sub-dir  $3 config cache  [$4 alias tsv: config-name -> logged-name]
    {
        summary_lookup "$REPORTS_DIR/$1.rpt" | awk -F'\t' 'NF{print "C\t" $0}'
        slugmap_lines "$2"                      | awk -F'\t' 'NF>=2{print "O\t" $1 "\t" $2}'
        [ -n "${4:-}" ] && [ -f "$4" ] && awk -F'\t' 'NF>=2{print "A\t" $1 "\t" $2}' "$4"
        config_list "$3"                        | awk 'NF{print "N\t" $0}'
    } | awk -F'\t' -v dsub="$2" '
        # The slugmap is COMPREHENSIVE (details.sh records every page, the
        # slug carries the direction suffix) — a name absent from it has no
        # page, so there is no slugify fallback: no map entry, no link.
        function pageslug(n){ return (n in ovr) ? ovr[n] : "" }
        $1=="C" { k=toupper($2); real[k]=$2; cnt[k]=$3; fail[k]=$4; proc[k]=$5; bkt[k]=$6; cf[k]=$7; cp[k]=$8; next }
        $1=="O" { ovr[$2]=$3; next }
        $1=="A" { al[toupper($2)]=toupper($3); next }   # config spelling -> its logged alias (raw-IP endpoint -> PTR name)
        # N = the configured name; $4 = its base result. A name matched in the
        # logs is seen (real counts). A name never in the logs but result==blue
        # is a server-log-only entity — counted as SEEN too (the Server bucket
        # counts it, so Seen must), but with BLANK counts (no real transfer) and
        # its config-only detail-page link.
        $1=="N" { name=$2; if (name=="") next; k=toupper(name); mk=k
          # a configured RAW-IP endpoint logs under its reverse-DNS name
          # (parse.sh PTR substitution): match through the alias
          if (!(k in cnt) && (k in al) && (al[k] in cnt)) mk=al[k]
          seenreal=(mk in cnt); s=(seenreal || $4=="blue" || $4=="green")?1:0   # a GREEN name with no log rows = the UC3 clean-poll rule (result.sh): seen, blank counts, like blue
          ps = (dsub != "") ? pageslug(seenreal ? real[mk] : name) : ""
          print name "\t" s "\t" (seenreal?cnt[mk]:"") "\t" (seenreal?fail[mk]:"") "\t" (seenreal?proc[mk]:"") "\t" (seenreal?cf[mk]:"") "\t" (seenreal?cp[mk]:"") "\t" (seenreal?bkt[mk]:"") "\t" (ps != "" ? dsub "/" ps : "") }
    ' | LC_ALL=C sort
}

# ---- direction split of "seen" ----------------------------------------------
# Per member, the CONFIGURED direction partitions the seen names — In + Out
# always equals Seen, because every entity belongs to exactly one side of the
# configuration:
#   logins   -> In  by definition (a login = the partner authenticating INTO ST)
#   hosts    -> Out by definition (a host = the endpoint ST connects OUT to)
#   accounts -> the side its comm profiles are on: a login (In) or hosts (Out)
#               — no partner has both (see flow-manager.sh: _logins-hosts.tsv is empty)
#   subscriptions -> _subscriptions-logins.tsv (In) / _subscriptions-hosts.tsv
#               (Out) — a proven partition of all subscriptions
# The WHITELIST is inbound by definition (allowed source IPs), so its Seen IS
# its In (matched on Inbound legs, as the raw IP or via the hostname the parse
# substituted — input/<env>/hostnames) and Out is 0. Emitted as non-rendered META
# lines in the .rpt (the whitelist set rides with hosts), read by
# bin/build/publish.sh's root-index Entities coverage table.
DIRMAP="$REPORTS_DIR/.dirmap.$$"
# clean the PID-named temps on ANY exit — an orphan in the freshness-watched
# reports tree would force one extra publish (WLMAP is defined further down;
# ${…:-} keeps the trap safe before then under set -u)
trap 'rm -f "$DIRMAP" "${WLMAP:-}"' EXIT
# Keyed by the RAW config name: two spellings of one DNS name (the configured
# ACHFTPACC.PONDRES.EU / achftpacc.pondres.eu pair) stay two entries, matching
# the configured totals; dirsplit folds case only when matching seen names.
awk -F'\t' '
    # B = configured BOTH ways (production: 20 accounts carry a CLIENT login
    # AND a SERVER host). The host load must not OVERWRITE the login load —
    # it did until 2026-08-29, so a both account counted Out-only everywhere
    # downstream (dirsplit/cfgdir/resultsplit and the coverage TSV dir col).
    # each rule is IDEMPOTENT and order-proof: a SECOND host row must not
    # downgrade B back to O (AXINI carries 2 hosts — 2026-08-29 fix), and a
    # login row after a host row must upgrade O to B just the same
    FILENAME ~ /_accounts-logins\.tsv$/      { if ($1!="") { k2="A" SUBSEP $1; d[k2]=(d[k2]=="O"||d[k2]=="B")?"B":"I" }; next }
    FILENAME ~ /_accounts-hosts\.tsv$/       { if ($1!="") { k2="A" SUBSEP $1; d[k2]=(d[k2]=="I"||d[k2]=="B")?"B":"O" }; next }
    FILENAME ~ /_subscriptions-logins\.tsv$/ { if ($1!="") { k2="S" SUBSEP $1; d[k2]=(d[k2]=="O"||d[k2]=="B")?"B":"I"; sd[$1]=(sd[$1]=="O"||sd[$1]=="B")?"B":"I" }; next }
    FILENAME ~ /_subscriptions-hosts\.tsv$/  { if ($1!="") { k2="S" SUBSEP $1; d[k2]=(d[k2]=="I"||d[k2]=="B")?"B":"O"; sd[$1]=(sd[$1]=="I"||sd[$1]=="B")?"B":"O" }; next }
    FILENAME ~ /_logins\.tsv$/               { if ($1!="") d["L" SUBSEP $1]="I"; next }   # base files: col 1 = name
    FILENAME ~ /_hosts\.tsv$/                { if ($1!="") d["H" SUBSEP $1]="O"; next }
    END { for (k in d) { split(k, a, SUBSEP); print a[1] "\t" a[2] "\t" d[k] } }
' "$CONFIG_XREF/_accounts-logins.tsv" "$CONFIG_XREF/_accounts-hosts.tsv" \
  "$CONFIG_XREF/_subscriptions-logins.tsv" "$CONFIG_XREF/_subscriptions-hosts.tsv" \
  "$CONFIG_BASE/_logins.tsv" "$CONFIG_BASE/_hosts.tsv" 2>/dev/null > "$DIRMAP" || : > "$DIRMAP"

# Split a member's SEEN tuples by the configured direction: "in<TAB>out".
dirsplit() {   # $1 = the member's type code in DIRMAP (A|S|L|H); tuples on stdin
    awk -F'\t' -v t="$1" '
        FNR==NR { if ($1==t) dm[toupper($2)]=$3; next }
        $2==1   { d3 = dm[toupper($1)]
                  if (d3=="O" || d3=="B") o++
                  if (d3=="I" || d3=="B") i++ }   # B counts once per side, like a both-ways partner
        END     { print i+0 "\t" o+0 }
    ' "$DIRMAP" -
}
# The same split over the whole CONFIGURED list: "in<TAB>out" per type. (An
# unclassifiable config entry — an account with no comm profile — is in neither,
# so In+Out can fall one short of the configured total.)
cfgdir() {   # $1 = type code
    awk -F'\t' -v t="$1" '$1==t { if ($3=="I" || $3=="B") i++; if ($3=="O" || $3=="B") o++ } END { print i+0 "\t" o+0 }' "$DIRMAP"
}

# Per-item coverage lines for the root-index Entities table's cell DETAIL
# pages (docs/coverage/, rendered by bin/build/publish.sh): one line per configured
# name — "name<TAB>dir<TAB>seen<TAB>link<TAB>last-ts<TAB>last-outcome" — the
# exact item set behind every Configured / Seen / Result cell. The last
# transaction is derived like resultsplit below.
coverage_items() {   # $1 = the member's type code in DIRMAP; tuples on stdin
    awk -F'\t' -v t="$1" '
        function ts(s,   c) { c=index(s, ","); if (c) s=substr(s, 1, c-1)
            c=index(s, "  "); return (c ? substr(s, 1, c-1) : s) }
        FNR==NR { if ($1==t) dm[toupper($2)]=$3; next }
        NF {
            f=ts($6); p=ts($7); lastts=""; lo=""
            if (f!="" || p!="") { if (p=="" || (f!="" && f>p)) { lastts=f; lo="F" } else { lastts=p; lo="P" } }
            print $1 "\t" dm[toupper($1)] "\t" $2 "\t" $9 "\t" lastts "\t" lo
        }
    ' "$DIRMAP" -
}

# The LAST-transaction outcome per seen entity, split by configured direction:
# "fi<TAB>fo<TAB>pi<TAB>po<TAB>ftotal<TAB>ptotal". Each tuple carries the 10
# most-recent failed and processed transactions (the ccf/ccp drill lists,
# newest first, "date time  id,…"); whichever list's newest timestamp is later
# is the entity's last transaction — Failed when the failed side is newer.
resultsplit() {   # $1 = the member's type code in DIRMAP; tuples on stdin
    awk -F'\t' -v t="$1" '
        function ts(s,   c) { c=index(s, ","); if (c) s=substr(s, 1, c-1)   # newest entry
            c=index(s, "  "); return (c ? substr(s, 1, c-1) : s) }         # its "date time"
        FNR==NR { if ($1==t) dm[toupper($2)]=$3; next }
        $2==1 {
            f=ts($6); p=ts($7)
            if (f=="" && p=="") next
            last = (p=="" || (f!="" && f>p)) ? "F" : "P"
            d = dm[toupper($1)]
            if (last=="F") { ft++; if (d=="I" || d=="B") fi++; if (d=="O" || d=="B") fo++ }
            else           { pt++; if (d=="I" || d=="B") pi++; if (d=="O" || d=="B") po++ }
        }
        END { print fi+0 "\t" fo+0 "\t" pi+0 "\t" po+0 "\t" ft+0 "\t" pt+0 }
    ' "$DIRMAP" -
}

# Whitelist coverage: configured IPs, and those seen on INBOUND legs (matched
# as the raw IP or via the substituted hostname) — the whitelist only governs
# inbound connections, so Seen == In and Out is 0 by definition.
WLMAP="$REPORTS_DIR/.wlmap.$$"
{
    printf '#\t#\n'   # sentinel: keeps the map non-empty so FILENAME routing stays safe
    # One read of the address -> endpoint map (bin/ip.sh). There is no reverse
    # DNS any more, so a whitelisted address appears here only when it is also a
    # configured endpoint's address.
    if [ -f "$IP_HOSTS_FILE" ]; then
        awk -F'\t' '$1 != "" && $2 != "" { print $1 "\t" $2 }' "$IP_HOSTS_FILE"
    fi
} > "$WLMAP"
mkdir -p "$REPORTS_DIR/coverage"
# whitelist-files.tsv (2026-08-29): ip<TAB>Files — the distinct inbound
# CoreIds seen from each configured address (raw IP or its endpoint-name
# substitute), the whitelist's ACTIVITY source for the acc-vs-prod dormancy
# split (the one type with no entity report). Pre-truncated: the awk only
# opens it on the first print, and a stale file would survive a quiet run.
: > "$REPORTS_DIR/coverage/whitelist-files.tsv"
wl_stats=$(awk -F'\t' -v items="$REPORTS_DIR/coverage/whitelist.tsv" \
               -v wfiles="$REPORTS_DIR/coverage/whitelist-files.tsv" '
    FILENAME ~ /_white\.tsv$/ { if ($1!="") wht[++nw]=$1; next }   # base file: col 1 = IP
    FILENAME ~ /\.wlmap\./    { if ($1!="#") hm[$1]=toupper($2); next }
    $2=="Inbound" && $16!="" {
        u=toupper($16); hin[u]=1
        if (!((u SUBSEP $1) in wseen)) { wseen[u SUBSEP $1]=1; hcnt[u]++ }   # distinct CoreIds per address
        # per host value, the newest inbound row (sortkey) and its outcome
        st=$3; sub(/ Subtransmission$/, "", st)
        if ($13 != "" && $13 > hsk[u]) { hsk[u]=$13; hst[u]=(st=="Processed") ? "P" : "F"; hdisp[u]=$11 " " $12 }
    }
    END { for (i=1;i<=nw;i++) { ip=wht[i]; u=toupper(ip)
            k1=""; s1=""; d1=""
            if (u in hin) { k1=hsk[u]; s1=hst[u]; d1=hdisp[u] }
            if ((ip in hm) && (hm[ip] in hin) && (hsk[hm[ip]] > k1)) { k1=hsk[hm[ip]]; s1=hst[hm[ip]]; d1=hdisp[hm[ip]] }
            seenf = ((u in hin) || ((ip in hm) && (hm[ip] in hin))) ? 1 : 0
            # per-IP coverage line for the cell detail pages (same layout as
            # coverage_items; whitelist entries are In by definition, no link)
            printf "%s\tI\t%d\t\t%s\t%s\n", ip, seenf, d1, s1 > items
            wcnt = ((u in hcnt) ? hcnt[u] : 0)
            if ((ip in hm) && (hm[ip] in hcnt) && hm[ip] != u) wcnt += hcnt[hm[ip]]
            if (wcnt > 0) print ip "\t" wcnt > wfiles
            if (!seenf) continue
            n++
            if (s1=="F") wf++; else wp++ }
          close(items); close(wfiles)
          print nw+0 "\t" n+0 "\t" wf+0 "\t" wp+0 }
' "$CONFIG_BASE/_white.tsv" "$WLMAP" "$PARSED" 2>/dev/null || printf '0\t0\t0\t0')
rm -f "$WLMAP"
IFS=$'\t' read -r wl_cfg wl_seen wl_lf wl_lp <<< "$wl_stats"

# ---- the per-member reports -------------------------------------------------
# Reuse the entity grid summaries (<basename>.rpt) — already one row per entity
# value with the Files count/Error/OK, @data:buckets and drill — and
# match the configured account/subscription names against them. Accounts and
# subscriptions are both 1:1 (no configured name maps to >1 value), so a plain
# normalized (account) / prefix (subscription) join suffices; emit_tables adds the
# seen flag, the Server-log column and the Seen/Not-Seen tabs.
ul="Files"; dn=""   # empty drill noun => report.js default "File"

# accounts: EXACT match (case-insensitive) of config name <-> account value.
acc_tuples=$(exact_tuples account accounts _accounts.tsv)
{
    printf 'TITLE\tSeen — Accounts\n'
    printf 'DESC\tConfigured accounts (partners.json) checked against the accounts that actually appear in the transfer logs.\n'
    printf '%s\n' "$acc_tuples" | emit_tables "Account" "$ul" "$dn"
    printf 'NOTE\tSeen = the account name matches an account in the logs **exactly** (ignoring case only). `-` and `_` are different characters: **%s** and **%s** are two separate accounts, each with its own activity and its own detail page. %s = its matched activity count.\n' "FRE-SAPCD-FLANDERIJN" "FRE_SAPCD_FLANDERIJN" "$ul"
    IFS=$'\t' read -r d_in d_out <<< "$(printf '%s\n' "$acc_tuples" | dirsplit A)"
    IFS=$'\t' read -r c_in c_out <<< "$(cfgdir A)"
    IFS=$'\t' read -r r_fi r_fo r_pi r_po r_ft r_pt <<< "$(printf '%s\n' "$acc_tuples" | resultsplit A)"
    printf '%s\n' "$acc_tuples" | coverage_items A > "$REPORTS_DIR/coverage/accounts.tsv"
    printf 'META\tseen_in\t%s\nMETA\tseen_out\t%s\nMETA\tconfigured_in\t%s\nMETA\tconfigured_out\t%s\n' "$d_in" "$d_out" "$c_in" "$c_out"
    printf 'META\tlast_failed\t%s\nMETA\tlast_failed_in\t%s\nMETA\tlast_failed_out\t%s\nMETA\tlast_processed\t%s\nMETA\tlast_processed_in\t%s\nMETA\tlast_processed_out\t%s\n' "$r_ft" "$r_fi" "$r_fo" "$r_pt" "$r_pi" "$r_po"
    foot
} > "$REPORTS_DIR/showseen-accounts.rpt.tmp" && mv "$REPORTS_DIR/showseen-accounts.rpt.tmp" "$REPORTS_DIR/showseen-accounts.rpt"
echo "Data written to $REPORTS_DIR/showseen-accounts.rpt." >&2

# subscriptions: config name is an EXACT (case-insensitive) PREFIX of a
# subscription value — '-' and '_' stay distinct, so a UC1_X_Y config name
# can never match a UC4_X-Y site value.
sub_tuples=$( {
    summary_lookup "$REPORTS_DIR/subscription.rpt" | awk -F'\t' 'NF{print "C\t" $0}'
    slugmap_lines subscriptions                          | awk -F'\t' 'NF>=2{print "O\t" $1 "\t" $2}'
    config_list _subscriptions.tsv                        | awk 'NF{print "N\t" $0}'
} | awk -F'\t' '
    # comprehensive slugmap: no map entry, no page, no link (see exact_tuples)
    function pageslug(n){ return (n in ovr) ? ovr[n] : "" }
    $1=="C" { sv[++nv]=$2; svu[nv]=toupper($2); cnt[nv]=$3; fail[nv]=$4; proc[nv]=$5; bkt[nv]=$6; cf[nv]=$7; cp[nv]=$8; next }
    $1=="O" { ovr[$2]=$3; next }
    $1=="N" { name=$2; if (name=="") next; nn=toupper(name); mi=0
      # the EXACT match first, then the clean sub name as a prefix of the site
      # value ending at a NAME-PART BOUNDARY (2026-08-31 audit: unbounded and
      # in count order, UC4_ODV_ARE_APERTURE could claim …APERTURE2 Files,
      # buckets and link the moment the traffic swung)
      for (i=1;i<=nv;i++) if (svu[i]==nn) { mi=i; break }
      if (mi==0) for (i=1;i<=nv;i++) if (index(svu[i], nn)==1 && substr(svu[i], length(nn)+1, 1) !~ /[A-Za-z0-9]/) { mi=i; break }
      seenreal=(mi>0); s=(seenreal || $4=="blue" || $4=="green")?1:0   # blue = server-log-only, seen but blank counts; an unmatched GREEN is the UC3 clean-poll rule (result.sh), treated the same
      ps = pageslug(seenreal ? sv[mi] : name)
      print name "\t" s "\t" (seenreal?cnt[mi]:"") "\t" (seenreal?fail[mi]:"") "\t" (seenreal?proc[mi]:"") "\t" (seenreal?cf[mi]:"") "\t" (seenreal?cp[mi]:"") "\t" (seenreal?bkt[mi]:"") "\t" (ps != "" ? "subscriptions/" ps : "") }
' | LC_ALL=C sort)
{
    printf 'TITLE\tSeen — Subscriptions\n'
    printf 'DESC\tConfigured subscriptions (subscriptions.json) checked against the subscription values that actually appear in the transfer logs.\n'
    printf '%s\n' "$sub_tuples" | emit_tables "Subscription" "$ul" "$dn"
    printf 'NOTE\tSeen = the subscription name is a prefix of a subscription value in the logs (the parser keeps only the part before _SCP_, so the logged value is the clean subscription name). %s = its matched activity count.\n' "$ul"
    IFS=$'\t' read -r d_in d_out <<< "$(printf '%s\n' "$sub_tuples" | dirsplit S)"
    IFS=$'\t' read -r c_in c_out <<< "$(cfgdir S)"
    IFS=$'\t' read -r r_fi r_fo r_pi r_po r_ft r_pt <<< "$(printf '%s\n' "$sub_tuples" | resultsplit S)"
    printf '%s\n' "$sub_tuples" | coverage_items S > "$REPORTS_DIR/coverage/subscriptions.tsv"
    printf 'META\tseen_in\t%s\nMETA\tseen_out\t%s\nMETA\tconfigured_in\t%s\nMETA\tconfigured_out\t%s\n' "$d_in" "$d_out" "$c_in" "$c_out"
    printf 'META\tlast_failed\t%s\nMETA\tlast_failed_in\t%s\nMETA\tlast_failed_out\t%s\nMETA\tlast_processed\t%s\nMETA\tlast_processed_in\t%s\nMETA\tlast_processed_out\t%s\n' "$r_ft" "$r_fi" "$r_fo" "$r_pt" "$r_pi" "$r_po"
    foot
} > "$REPORTS_DIR/showseen-subscriptions.rpt.tmp" && mv "$REPORTS_DIR/showseen-subscriptions.rpt.tmp" "$REPORTS_DIR/showseen-subscriptions.rpt"
echo "Data written to $REPORTS_DIR/showseen-subscriptions.rpt." >&2

# logins / hosts: the same EXACT-match All / Seen / Not Seen split,
# against the partners.json comm-profile logins/hosts, each with its own per-name server
# cache dir feeding the Server-log column (the tuples carry the CONFIG
# spelling, which is also how the server parse keys the per-name files —
# hosts included, since it attributes case-insensitive matches under the
# configured name).
login_tuples=$(exact_tuples login logins _logins.tsv)
{
    printf 'TITLE\tSeen — Logins\n'
    printf 'DESC\tConfigured logins (the partners.json comm-profile login names) checked against the logins that actually appear in the transfer logs.\n'
    printf '%s\n' "$login_tuples" | emit_tables "Login" "$ul" "$dn"
    printf 'NOTE\tSeen = the configured login name matches a login in the logs **exactly** (ignoring case only). Only configured logins are listed here — every logged login, configured or not, is in the Logins entity report. %s = its matched activity count. Click an Error or OK count for that outcome'\''s 10 most recent (newest first).\n' "$ul"
    IFS=$'\t' read -r d_in d_out <<< "$(printf '%s\n' "$login_tuples" | dirsplit L)"
    IFS=$'\t' read -r c_in c_out <<< "$(cfgdir L)"
    IFS=$'\t' read -r r_fi r_fo r_pi r_po r_ft r_pt <<< "$(printf '%s\n' "$login_tuples" | resultsplit L)"
    printf '%s\n' "$login_tuples" | coverage_items L > "$REPORTS_DIR/coverage/logins.tsv"
    printf 'META\tseen_in\t%s\nMETA\tseen_out\t%s\nMETA\tconfigured_in\t%s\nMETA\tconfigured_out\t%s\n' "$d_in" "$d_out" "$c_in" "$c_out"
    printf 'META\tlast_failed\t%s\nMETA\tlast_failed_in\t%s\nMETA\tlast_failed_out\t%s\nMETA\tlast_processed\t%s\nMETA\tlast_processed_in\t%s\nMETA\tlast_processed_out\t%s\n' "$r_ft" "$r_fi" "$r_fo" "$r_pt" "$r_pi" "$r_po"
    foot
} > "$REPORTS_DIR/showseen-logins.rpt.tmp" && mv "$REPORTS_DIR/showseen-logins.rpt.tmp" "$REPORTS_DIR/showseen-logins.rpt"
echo "Data written to $REPORTS_DIR/showseen-logins.rpt." >&2

# A configured RAW-IP endpoint used to log under its PTR name, so an alias
# bridged the two for the exact match. With no reverse DNS the parse leaves such
# an address raw in col 16, where it matches _hosts.tsv directly — the alias is
# gone. (It resolved exactly 2 endpoints when removed; both stay seen.)
host_tuples=$(exact_tuples remote-host hosts _hosts.tsv)
{
    printf 'TITLE\tSeen — Hosts\n'
    printf 'DESC\tConfigured partner hosts (the partners.json comm-profile hosts) checked against the remote hosts that actually appear in the transfer logs.\n'
    printf '%s\n' "$host_tuples" | emit_tables "Remote Host" "$ul" "$dn"
    printf 'NOTE\tSeen = the configured hostname matches a remote host in the logs **exactly** (ignoring case only). A logged remote host is the reverse-DNS name of the connecting IP, which can differ from the configured hostname — such a partner can show as not seen here even though it connects. Only configured hosts are listed here — every logged remote host, configured or not, is in the Remote Hosts entity report. %s = its matched activity count. Click an Error or OK count for that outcome'\''s 10 most recent (newest first).\n' "$ul"
    # the whitelist coverage rides with hosts (both derive from the host values)
    IFS=$'\t' read -r d_in d_out <<< "$(printf '%s\n' "$host_tuples" | dirsplit H)"
    IFS=$'\t' read -r c_in c_out <<< "$(cfgdir H)"
    IFS=$'\t' read -r r_fi r_fo r_pi r_po r_ft r_pt <<< "$(printf '%s\n' "$host_tuples" | resultsplit H)"
    printf '%s\n' "$host_tuples" | coverage_items H > "$REPORTS_DIR/coverage/hosts.tsv"
    printf 'META\tseen_in\t%s\nMETA\tseen_out\t%s\nMETA\tconfigured_in\t%s\nMETA\tconfigured_out\t%s\nMETA\twl_configured\t%s\nMETA\twl_seen\t%s\nMETA\twl_seen_in\t%s\nMETA\twl_seen_out\t0\n' \
        "$d_in" "$d_out" "$c_in" "$c_out" "$wl_cfg" "$wl_seen" "$wl_seen"
    printf 'META\tlast_failed\t%s\nMETA\tlast_failed_in\t%s\nMETA\tlast_failed_out\t%s\nMETA\tlast_processed\t%s\nMETA\tlast_processed_in\t%s\nMETA\tlast_processed_out\t%s\n' "$r_ft" "$r_fi" "$r_fo" "$r_pt" "$r_pi" "$r_po"
    printf 'META\twl_last_failed\t%s\nMETA\twl_last_processed\t%s\n' "$wl_lf" "$wl_lp"
    foot
} > "$REPORTS_DIR/showseen-hosts.rpt.tmp" && mv "$REPORTS_DIR/showseen-hosts.rpt.tmp" "$REPORTS_DIR/showseen-hosts.rpt"
echo "Data written to $REPORTS_DIR/showseen-hosts.rpt." >&2

# (the Flows / transfer-profiles member was REMOVED 2026-07 and the transfer
# profile left the application entirely 2026-07; the _profiles config caches
# stay, feeding the parse subscription fallback only)

# (the three PDA members — partners / applications / domains — were REMOVED
# 2026-07: their showseen-*.rpt had no reader left. The status figures take the
# PDA "Seen" from the coverage TSVs instead, because an organisation configured
# BOTH ways is ONE row whose Seen cannot be summed from the per-direction rows
# — bin/analyses/reports/home.sh's pda_seen_total over
# data/<env>/transfer/reports/coverage/{partners,domains,applications}.tsv,
# materialized by ensure_pda_tsvs. The classic four still come from the INTRO
# counts of the .rpt written above.)

rm -f "$DIRMAP"
