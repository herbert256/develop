#!/usr/bin/env bash
#
# account-sharing.sh — "Account sharing": which accounts serve MORE than one
# subscription, and in what shape. The patterns are few and telling:
#
#   Mailbox pair        exactly UC2 + UC4 — the partner's inbound mailbox:
#                       one connection, drop + pickup. The only inbound
#                       sharing that occurs.
#   Outbound pair       exactly UC1 + UC3 — the outbound mirror: we push to
#                       and poll the same partner.
#   Outbound fan-out    several UC1/UC3 flows on one partner relation (up
#                       to dozens).
#   Both directions     inbound AND outbound use cases on one account —
#                       does not occur for real partners; the synthetic
#                       ST end-to-end monitor account is built this way.
#
# Config-only: reads the flow-manager xref (accounts -> subscriptions), no
# parse cache. A transfer-DATA report housed with the ANALYSES scripts (like
# cross-reference.sh): it sources the transfer lib and writes a transfer rpt;
# bin/analyses/reports.sh runs it (wave 1 — no PDA TSVs, no home.rpt). The
# PAGE renders into docs/<env>/analyses/ via SUBS_GROUP_REPORTS.
#
# Usage:
#   ./account-sharing.sh   # -> data/<env>/transfer/reports/account-sharing.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../transfer/lib.sh"
mkdir -p "$REPORTS_DIR"
OUT="$REPORTS_DIR/account-sharing.rpt"
XREF_AS="$CONFIG_XREF/_accounts-subscriptions.tsv"

ensure_config
if [ ! -s "$XREF_AS" ]; then
    echo "account-sharing: no $XREF_AS — page not published." >&2
    rm -f "$OUT"
    exit 0
fi
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$XREF_AS"

GENDATE=$(date '+%Y-%m-%d %H:%M:%S')

# One pass: per account its UC mix; kinds as above (the leading korder digit
# fixes the display order); accounts walked in xref FILE order into an
# ordered roster, the final sort is kind, then subscription count desc
# (inverted 3-digit key), then name.
# the DERIVED use case map (bin/flow-manager.sh): a production hybrid flow
# carries no UC prefix — read from the name alone, the estate's largest
# shared account (eight derived-UC2 flows) landed in "Ungrouped flows" with
# every UC column 0 (2026-08-31 audit)
UCDF="$CONFIG_XREF/_subscriptions-ucderived.tsv"; [ -f "$UCDF" ] || UCDF=/dev/null
awk -F'\t' -v UCDF="$UCDF" '
    function ucof(s) { if (match(s, /^UC[0-9]+/)) return substr(s, 1, RLENGTH); if (toupper(s) in UCD) return UCD[toupper(s)]; return "other" }
    BEGIN { while ((getline l9 < UCDF) > 0) { split(l9, a9, "\t"); if (a9[1] != "" && a9[2] != "") UCD[toupper(a9[1])] = a9[2] } close(UCDF) }
    {
        if (ASUB[$1] == "") AORD[++na] = $1                  # emptiness test, not membership (mawk)
        ASUB[$1] = (ASUB[$1] == "" ? "" : ASUB[$1] "\037") $2
        n[$1]++; u = ucof($2)
        if      (u == "UC1") u1[$1]++
        else if (u == "UC2") u2[$1]++
        else if (u == "UC3") u3[$1]++
        else if (u == "UC4") u4[$1]++
        else                 uo[$1]++
    }
    END {
        for (i = 1; i <= na; i++) {
            a = AORD[i]
            if (n[a] == 1) continue
            inb = u2[a] + u4[a] > 0; outb = u1[a] + u3[a] > 0
            if (inb && outb)                                          { k = 4; kind = "Both directions" }
            else if (inb)  { if (u2[a] == 1 && u4[a] == 1 && n[a] == 2) { k = 1; kind = "Mailbox pair" }
                             else                                       { k = 5; kind = "Inbound (irregular)" } }
            else if (outb) { if (u1[a] == 1 && u3[a] == 1 && n[a] == 2) { k = 2; kind = "Outbound pair" }
                             else                                       { k = 3; kind = "Outbound fan-out" } }
            else                                                        { k = 6; kind = "Ungrouped flows" }
            # sort the subscription list for the cell (small; insertion)
            m = split(ASUB[a], V, "\037")
            for (x = 2; x <= m; x++) { v = V[x]; y = x - 1; while (y >= 1 && V[y] > v) { V[y+1] = V[y]; y-- } V[y+1] = v }
            cell = V[1]; for (x = 2; x <= m; x++) cell = cell "\037" V[x]
            # sortable key: kind order, inverted count (3-digit), name — the
            # sort itself happens in the shell pipeline (a TAB inside an
            # awk-piped command string word-splits in sh)
            printf "%d\t%03d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n", \
                k, 999 - n[a], a, kind, u1[a]+0, u2[a]+0, u3[a]+0, u4[a]+0, uo[a]+0, n[a], cell
        }
    }
' "$XREF_AS" | LC_ALL=C sort -t$'\t' -k1,1n -k2,2n -k3,3f > "$OUT.rows"

# totals for the stat boxes
read -r n_total n_single <<< "$(awk -F'\t' '{ c[$1]++ }
    END { t = 0; s = 0; for (a in c) { t++; if (c[a] == 1) s++ } print t, s }' "$XREF_AS")"
n_shared=$(( n_total - n_single ))
n_mailbox=$(awk -F'\t' '$4 == "Mailbox pair" { n++ } END { print n+0 }' "$OUT.rows")
n_outpair=$(awk -F'\t' '$4 == "Outbound pair" { n++ } END { print n+0 }' "$OUT.rows")
n_fan=$(awk -F'\t' '$4 == "Outbound fan-out" { n++ } END { print n+0 }' "$OUT.rows")
n_both=$(awk -F'\t' '$4 == "Both directions" { n++ } END { print n+0 }' "$OUT.rows")

{
    printf 'TITLE\tAccount sharing\n'
    printf 'DESC\tWhich accounts serve more than one subscription, and in what shape: the UC2+UC4 mailbox pair (one partner connection, drop + pickup), the UC1+UC3 outbound pair, outbound fan-outs — and the accounts mixing both directions.\n'
    printf 'INTRO\tAn account is a partner relation, and one relation often carries **several flows**. The shapes are few: a **Mailbox pair** (exactly UC2 + UC4) is the partner'\''s inbound mailbox — ONE connection used to drop and pick up, which is why those pages carry the shared-connection notes; an **Outbound pair** (exactly UC1 + UC3) is the outbound mirror — we push to and poll the same partner; an **Outbound fan-out** runs several UC1/UC3 flows over one relation. **Both directions** on one account is rare for real partners — the synthetic ST monitor account has it by design. Inbound sharing beyond the pair (two UC2s, two UC4s) is the **Inbound (irregular)** kind: the hybrid production accounts, where one partner relation carries several flows.\n'
    printf 'STAT\twhite\t%s\tAccounts with subscriptions\n' "$n_total"
    printf 'STAT\twhite\t%s\tSingle subscription\n' "$n_single"
    printf 'STAT\twhite\t%s\tShared\n' "$n_shared"
    printf 'STAT\tgreen\t%s\tMailbox pairs (UC2+UC4)\n' "$n_mailbox"
    printf 'STAT\tgreen\t%s\tOutbound pairs (UC1+UC3)\n' "$n_outpair"
    printf 'STAT\twhite\t%s\tOutbound fan-outs\n' "$n_fan"
    printf 'STAT\torange\t%s\tBoth directions\n' "$n_both"
    printf 'TABLE\tShared accounts\twide\tnofilter\tnosort\n'
    printf 'HEAD\tAccount\tKind\tUC1\tUC2\tUC3\tUC4\tOther\tSubs\tSubscriptions\n'
    printf 'KIND\tacct\ttext\tnum\tnum\tnum\tnum\tnum\tnum\tclines\n'
    awk -F'\t' '{ printf "ROW\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $3, $4, $5, $6, $7, $8, $9, $10, $11 }' "$OUT.rows"
    awk -F'\t' '{ n++; s1+=$5; s2+=$6; s3+=$7; s4+=$8; so+=$9; st+=$10 }
        END { printf "TOTAL\tTotal (%d account(s))\t\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t@{class=num}%d\t\n", n+0, s1+0, s2+0, s3+0, s4+0, so+0, st+0 }' "$OUT.rows"
    printf 'NOTE\tThe kind reads the subscription NAMES'\'' UC prefix (UC1/UC3 = we connect out, UC2/UC4 = the partner connects in), or the use case DERIVED from the configuration for a flow without one (the hybrid production flows). Rows are ordered by kind, then by size. Single-subscription accounts (the majority) are counted in the boxes above but not listed. A login usually rides its account 1-to-1, so "same account" and "same FE login" describe the same sharing; a hybrid production account shares one login across its flows — or carries SEVERAL FE logins, one per flow (the multi-FE shape, 2026-08-31).\n'
    printf 'KEYWORDS\taccount,sharing,shared,mailbox,uc2,uc4,uc1,uc3,pair,fan-out,both directions,relation\n'
    printf 'FOOT\tGenerated on %s\n' "$GENDATE"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
rm -f "$OUT.rows"

echo "Data written to $OUT ($n_shared shared account(s): $n_mailbox mailbox pair(s), $n_outpair outbound pair(s), $n_fan fan-out(s), $n_both both-directions)." >&2
