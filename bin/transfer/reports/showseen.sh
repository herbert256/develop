#!/usr/bin/env bash
#
# showseen.sh — cross-reference the CONFIGURED entities against what actually
# shows up in the transfer logs. Five source lists, read from the bin/flow-manager.sh
# caches (built from the partners.json / subscriptions.json config exports):
#   data/flow-manager/base/_accounts.tsv      -> the configured accounts   (partner names)
#   data/flow-manager/base/_subscriptions.tsv -> the configured subscriptions
#   data/flow-manager/base/_logins.tsv        -> the configured logins     (comm-profile login names)
#   data/flow-manager/base/_hosts.tsv         -> the configured hosts      (comm-profile hosts[])
# Emits per member:
#   data/transfer/reports/coverage/<member>.tsv   the COVERAGE TSV — one line per
#       configured name: name, configured direction, seen, detail link, last
#       transaction, its outcome (coverage_items below). Read by the analyses
#       (bin/analyses/lib.sh ensure_pda_tsvs, home.sh, entity-search.sh,
#       first-seen.sh) and the Entities views' not-seen rows (publish_lib).
#   (the showseen-<member>.rpt files went 2026-09-29: home.sh read only their
#   "Seen: N", which it now counts from the coverage TSV — the same tuples)
# The seen flags and last transactions are lifted straight from the classic
# entity records (<basename>.rpt, their FIRST table — written by
# entities.sh since 2026-09-30) so this and the entity reports agree.
#
# "Seen" match (case-insensitive, but '-' and '_' are DIFFERENT characters):
#   accounts      — name == an account value (_transfers.tsv col 4), EXACTLY
#   subscriptions — name is a PREFIX of a subscription value (col 6): the parser
#                   keeps the site only up to _SCP_, so col 6 is already the clean
#                   subscription name (usually an exact match; prefix still covers
#                   a longer sub-named variant)
#   logins        — name == a login value (col 5), EXACTLY
#   hosts         — name == a remote-host value (col 16), EXACTLY (there is
#                   no reverse DNS: col 16 is the endpoint as parse.sh
#                   resolved it through the input/ip forward map).
# Only configured names are listed (a logged-but-unconfigured value is not);
# the entity grid reports list every logged value.
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
#   ./showseen.sh    # reads data/flow-manager/_*.tsv + the cache, writes data/transfer/reports/coverage/<member>.tsv
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
echo "Found ${#files[@]} file(s) in '$INPUT_DIR', processing..." >&2

# (The former per-member "Server log" yes/no column + last-10 drill is GONE:
# the server-log mentions now live in ONE place — the "Last 10 server log
# lines" table on a not-seen entity's DETAIL page, details.sh srv_lines_table.)

# A configured-entity list from the bin/flow-manager.sh caches. Tolerates a missing cache file — no config export anywhere —
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

# Parse a classic entity .rpt (its FIRST/Summary table) into one line per entity value:
#   value<TAB>count<TAB>failed<TAB>processed<TAB>lastf<TAB>lastp
# lastf/lastp = the start ("date time") of the value's newest Error / OK File
# (ROW fields 6/7 — the first entry of the former drill lists, trimmed
# 2026-09-29), the entity's last transaction below.
summary_lookup() {   # $1 = <basename>.rpt
    [ -f "$1" ] || return 0
    awk -F'\t' '
        /^TABLE\t/ { t++ }
        t==1 && $1=="ROW" { print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 }' "$1"
}

# EXACT-match tuple builder (accounts, logins, hosts): each configured
# name (config_list) matched exactly (case aside) against the grid summary's
# logged values; a seen name links to its detail page (slugmap overrides
# honoured). Three tagged streams: C = the logged values + their counts, O = the
# slug overrides, N = the configured names. C and O must precede N. Output:
#   name<TAB>seen<TAB>count<TAB>failed<TAB>processed<TAB>lastf<TAB>lastp<TAB>link
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
        $1=="C" { k=toupper($2); real[k]=$2; cnt[k]=$3; fail[k]=$4; proc[k]=$5; cf[k]=$6; cp[k]=$7; next }
        $1=="O" { ovr[$2]=$3; next }
        $1=="A" { al[toupper($2)]=toupper($3); next }   # config spelling -> its logged alias (raw-IP endpoint -> PTR name)
        # N = the configured name; $4 = its base result. A name matched in the
        # logs is seen (real counts). A name never in the logs but result==green
        # (green through its subscriptions; until 2026-09-28 also the UC3
        # clean-poll rule) is counted as SEEN too, with BLANK counts (no real
        # transfer) and its config-only detail-page link.
        $1=="N" { name=$2; if (name=="") next; k=toupper(name); mk=k
          # a configured RAW-IP endpoint logs under its reverse-DNS name
          # (parse.sh PTR substitution): match through the alias
          if (!(k in cnt) && (k in al) && (al[k] in cnt)) mk=al[k]
          seenreal=(mk in cnt); s=(seenreal || $4=="green")?1:0   # a GREEN name with no log rows: seen, blank counts
          ps = (dsub != "") ? pageslug(seenreal ? real[mk] : name) : ""
          print name "\t" s "\t" (seenreal?cnt[mk]:"") "\t" (seenreal?fail[mk]:"") "\t" (seenreal?proc[mk]:"") "\t" (seenreal?cf[mk]:"") "\t" (seenreal?cp[mk]:"") "\t" (ps != "" ? dsub "/" ps : "") }
    ' | LC_ALL=C sort
}

# ---- the configured direction (the coverage TSVs' dir column) ----------------
# Per member, the CONFIGURED side of every name:
#   logins   -> In  by definition (a login = the partner authenticating INTO ST)
#   hosts    -> Out by definition (a host = the endpoint ST connects OUT to)
#   accounts -> the side its comm profiles are on: a login (In) or hosts (Out)
#               — no partner has both (see flow-manager.sh: _logins-hosts.tsv is empty)
#   subscriptions -> _subscriptions-logins.tsv (In) / _subscriptions-hosts.tsv
#               (Out) — a proven partition of all subscriptions
# coverage_items below writes it as the TSVs' second column (I / O / B).
DIRMAP="$REPORTS_DIR/.dirmap.$$"
trap 'rm -f "$DIRMAP"' EXIT   # the PID-named temp, on ANY exit
# Keyed by the RAW config name: two spellings of one DNS name (the configured
# ACHFTPACC.PONDRES.EU / achftpacc.pondres.eu pair) stay two entries, matching
# the configured totals; coverage_items folds case only when looking a name up.
awk -F'\t' '
    # B = configured BOTH ways (production: 20 accounts carry a CLIENT login
    # AND a SERVER host). The host load must not OVERWRITE the login load —
    # it did until 2026-08-29, so a both account counted Out-only everywhere
    # downstream (the coverage TSV dir col).
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

# Per-item coverage lines for the root-index Entities table's cell DETAIL
# pages (docs/coverage/, rendered by bin/build/publish.sh): one line per configured
# name — "name<TAB>dir<TAB>seen<TAB>link<TAB>last-ts<TAB>last-outcome" — the
# exact item set behind every Configured / Seen / Result cell. The last
# transaction: each tuple carries the start ("date time") of the newest
# failed and the newest processed File (lastf / lastp — the classic .rpt ROW
# fields 6/7); whichever is later is the entity's last transaction — F when
# the failed side is newer.
coverage_items() {   # $1 = the member's type code in DIRMAP; tuples on stdin
    awk -F'\t' -v t="$1" '
        FNR==NR { if ($1==t) dm[toupper($2)]=$3; next }
        NF {
            f=$6; p=$7; lastts=""; lo=""
            if (f!="" || p!="") { if (p=="" || (f!="" && f>p)) { lastts=f; lo="F" } else { lastts=p; lo="P" } }
            print $1 "\t" dm[toupper($1)] "\t" $2 "\t" $8 "\t" lastts "\t" lo
        }
    ' "$DIRMAP" -
}

# ---- the per-member outputs --------------------------------------------------
# Reuse the classic entity records (<basename>.rpt) — already one row per entity
# value with the Files count/Error/OK and the newest Error / OK File start — and
# match the configured account/subscription names against them. Accounts and
# subscriptions are both 1:1 (no configured name maps to >1 value), so a plain
# normalized (account) / prefix (subscription) join suffices.
mkdir -p "$REPORTS_DIR/coverage"

# accounts: EXACT match (case-insensitive) of config name <-> account value.
acc_tuples=$(exact_tuples account accounts _accounts.tsv)
printf '%s\n' "$acc_tuples" | coverage_items A > "$REPORTS_DIR/coverage/accounts.tsv"
echo "Data written to $REPORTS_DIR/coverage/accounts.tsv." >&2

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
    $1=="C" { sv[++nv]=$2; svu[nv]=toupper($2); cnt[nv]=$3; fail[nv]=$4; proc[nv]=$5; cf[nv]=$6; cp[nv]=$7; next }
    $1=="O" { ovr[$2]=$3; next }
    $1=="N" { name=$2; if (name=="") next; nn=toupper(name); mi=0
      # the EXACT match first, then the clean sub name as a prefix of the site
      # value ending at a NAME-PART BOUNDARY (2026-08-31 audit: unbounded and
      # in count order, UC4_ODV_ARE_APERTURE could claim …APERTURE2 Files,
      # buckets and link the moment the traffic swung)
      for (i=1;i<=nv;i++) if (svu[i]==nn) { mi=i; break }
      if (mi==0) for (i=1;i<=nv;i++) if (index(svu[i], nn)==1 && substr(svu[i], length(nn)+1, 1) !~ /[A-Za-z0-9]/) { mi=i; break }
      seenreal=(mi>0); s=(seenreal || $4=="green")?1:0   # an unmatched GREEN: seen, blank counts (the UC3 clean-poll greens until 2026-09-28)
      ps = pageslug(seenreal ? sv[mi] : name)
      print name "\t" s "\t" (seenreal?cnt[mi]:"") "\t" (seenreal?fail[mi]:"") "\t" (seenreal?proc[mi]:"") "\t" (seenreal?cf[mi]:"") "\t" (seenreal?cp[mi]:"") "\t" (ps != "" ? "subscriptions/" ps : "") }
' | LC_ALL=C sort)
printf '%s\n' "$sub_tuples" | coverage_items S > "$REPORTS_DIR/coverage/subscriptions.tsv"
echo "Data written to $REPORTS_DIR/coverage/subscriptions.tsv." >&2

# logins / hosts: the same EXACT-match seen split, against the partners.json
# comm-profile logins/hosts (the tuples carry the CONFIG spelling).
login_tuples=$(exact_tuples login logins _logins.tsv)
printf '%s\n' "$login_tuples" | coverage_items L > "$REPORTS_DIR/coverage/logins.tsv"
echo "Data written to $REPORTS_DIR/coverage/logins.tsv." >&2

# A configured RAW-IP endpoint used to log under its PTR name, so an alias
# bridged the two for the exact match. With no reverse DNS the parse leaves such
# an address raw in col 16, where it matches _hosts.tsv directly — the alias is
# gone. (It resolved exactly 2 endpoints when removed; both stay seen.)
host_tuples=$(exact_tuples remote-host hosts _hosts.tsv)
printf '%s\n' "$host_tuples" | coverage_items H > "$REPORTS_DIR/coverage/hosts.tsv"
echo "Data written to $REPORTS_DIR/coverage/hosts.tsv." >&2

# (the Flows / transfer-profiles member was REMOVED 2026-07 and the transfer
# profile left the application entirely 2026-07; the _profiles config caches
# stay, feeding the parse subscription fallback only)

# (the three PDA members — partners / applications / domains — were REMOVED
# 2026-07: their showseen-*.rpt had no reader left. The status figures take the
# PDA "Seen" from the coverage TSVs instead, because an organisation configured
# BOTH ways is ONE row whose Seen cannot be summed from the per-direction rows
# — bin/analyses/reports/home.sh's pda_seen_total over
# data/transfer/reports/coverage/{partners,domains,applications}.tsv,
# materialized by ensure_pda_tsvs. The classic four count their coverage TSV
# written above.)

rm -f "$DIRMAP"
