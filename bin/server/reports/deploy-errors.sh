#!/usr/bin/env bash
#
# deploy-errors.sh — "Deploy errors": the accounts and subscriptions a
# CONFIGURATION defect stops dead, and that have not recovered since.
#
# TWO message families, both a deployment mistake rather than a runtime fault:
#
# 1. The Advanced Routing step error
#
#   ARSP0001: [<ACCOUNT>] [<SUBSCRIPTION>]  An error occurred while sending
#   the file {…} to a partner site. Step configuration suggests to stop
#   further route execution.
#
#   The routing step did not merely fail — its configuration told
#   SecureTransport to ABANDON the rest of the route, so nothing downstream
#   ran for that file.
#
# 2. The PeSIT receive-side gap (2026-08)
#
#   [Pesit Default] Transfer profile '<P>' of account 'SECURETRANSPORT' is
#   used for incoming transfer, but 'Receive File As' field not set.
#
#   One unset field on the profile, and EVERY incoming transfer of that flow
#   errors — the same "configured wrong, nothing gets through" shape, so it
#   belongs on this page. The naming entity is the SUBSCRIPTION the profile
#   belongs to (xref/_profiles-subscriptions.tsv): the message's own account
#   is the platform's SECURETRANSPORT, and a transfer profile is
#   parse-internal — it has no page and must never be surfaced as an entity
#   (CLAUDE.md). A profile that does not resolve to exactly ONE subscription
#   is counted as unattributable and left out, never guessed.
#
# The Cause column says which family a row comes from (both, when an entity
# has each).
#
# ONE row per entity, and the entity is whichever bracket names the flow: the
# ACCOUNT normally, the SUBSCRIPTION when the account is the platform's own
# SECURETRANSPORT (blacklisted everywhere else on the site, so it would make a
# useless row) — EXCEPT the ARPA0001 variant ("publishing the file {…} to an
# account"), whose second bracket names the destination ACCOUNT even behind
# SECURETRANSPORT. An account's "@FE000593" endpoint suffix is stripped exactly as
# bin/transfer/parse.sh strips it, so the name matches _files.tsv and the
# detail-page link resolves.
#
# UNRESOLVED ONLY. An entity whose LAST such message is followed by an OK File
# is dropped — the route was stopped, then something got through, so it is
# history rather than a live problem. A UC3 SUBSCRIPTION is also dropped when a
# SUCCESSFUL POLL follows its last message (2026-08): the listing succeeded, so
# the flow works again even when there was nothing to fetch. Same rule as the
# Connection failures box
# on Subscriptions in boxes, and the comparison is exact to the millisecond:
# the message timestamp is rebuilt into the _files.tsv sortkey shape
# (YYYYMMDDHH:MM:SS.mmm), so a same-day recovery counts and not just a later
# day. OK follows the site outcome policy — Error is Failed or Expired,
# everything else (incl. Waiting) is OK.
#
# ONE pass over the server cache (2 GB): it is the expensive input, so the
# messages and the recovery test share a single awk, tuples go to a temp file,
# and only the ~100 tuples are sorted.
#
# Reads: $PARSED (the server cache), the transfer $FILES,
#        xref/_profiles-subscriptions.tsv (the profile -> flow resolution).
# Writes: data/<env>/server/reports/deploy-errors.rpt
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"

OUT="$REPORTS_DIR/deploy-errors.rpt"
FILES_TSV="$TRANSFER_CACHE/_files.tsv"
[ -f "$FILES_TSV" ] || FILES_TSV=/dev/null
PROFSUB="$CONFIG_XREF/_profiles-subscriptions.tsv"
[ -f "$PROFSUB" ] || PROFSUB=/dev/null
# The transfer cache is a cross-area DEP: the "recovered since" test reads it,
# so a transfer reparse has to re-trigger this report. The profile map is a
# config dep: a re-derived xref changes which flow a message names.
skip_if_fresh "$OUT" "${BASH_SOURCE[0]}" "$FILES_TSV" "$PROFSUB"
ensure_parsed
ensure_config

TMP=$(mktemp -d "${TMPDIR:-/tmp}/axdep.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# tuple: sortkey \t name \t messages \t last-message \t kind
LC_ALL=C awk -F'\t' -v STATS="$TMP/stats" -v xf="$PROFSUB" -v pf="$PARSED" -v RNF="$RENAMES_FILE" -v RNP="$RENAMES_PROF" "$RENAMES_AWK"'
    BEGIN { rn_load(RNF, RNP) }
    # "[A] [B]" -> the naming entity; sets ACC as a side effect.
    function ent(m,   p1, q1, a, rest, p2, q2, s) {
        p1 = index(m, "[");             if (!p1) return ""
        q1 = index(substr(m, p1), "]"); if (!q1) return ""
        a  = substr(m, p1 + 1, q1 - 2); sub(/@.*/, "", a)
        rest = substr(m, p1 + q1)
        p2 = index(rest, "[");             if (!p2) return ""
        q2 = index(substr(rest, p2), "]"); if (!q2) return ""
        ACC = a; s = substr(rest, p2 + 1, q2 - 2)
        return (a == "SECURETRANSPORT" || a == "") ? s : a
    }
    # FILENAME dispatch, not an FNR==1 file counter: the profile map may be
    # /dev/null (no config yet) and awk skips an EMPTY file entirely, which
    # would shift every later file number.
    FILENAME == xf {                            # profile -> subscription(s) (config xref)
        # ALL of them, not a first-wins scalar (2026-08): a Receive-File-As
        # defect sits on the PROFILE, and every flow sharing that profile is
        # affected — union attribution, the same idea as box 15 counting an
        # account against every subscription configured for it. This is not a
        # guess: the misconfigured object is genuinely shared. (The old
        # \001-ambiguous drop dated from when profiles were unique per flow;
        # the 2026-08 rename merged spellings, and the busiest RFA profile —
        # 1,371 lines — fell off the page as "unattributable".)
        if ($1 != "" && $2 != "") { xk = toupper($1)
            if (!((xk SUBSEP $2) in pseen)) { pseen[xk, $2] = 1
                # EMPTINESS, not membership: mawk evaluates the LHS first, so
                # `(xk in PSUB) ? …` would see the key as existing on its very
                # first sight and prepend an empty element (the CLAUDE.md trap)
                PSUB[xk] = (PSUB[xk] != "" ? PSUB[xk] "\037" : "") $2 } }
        next
    }
    FILENAME == pf {                            # the server parse cache
        # a SUCCESSFUL POLL clears a UC3 subscription (2026-08): the listing
        # succeeded — even "0 matched the pattern" means the flow works again,
        # so remember the newest poll per (tail-stripped) site for END
        if (index($5, "Applying the search pattern") > 0 && match($5, /for transfer site '\''[^'\'']*'\''/)) {
            ps = substr($5, RSTART + 19, RLENGTH - 20); sub(/_(SS?|C)CP_.*$/, "", ps)
            if (ps != "") { pu = toupper(ps); d = $1; gsub(/-/, "", d); pk = d $2; if (pk > PMAX[pu]) PMAX[pu] = pk }
            next
        }
        # the PeSIT receive-side gap (2026-08): one unset profile field and
        # every incoming transfer of that flow errors. The entity is the
        # profile\047s SUBSCRIPTION — the message names the platform account
        # SECURETRANSPORT, and a transfer profile is parse-internal (no page,
        # never an entity row). No unique flow -> counted unattributable.
        if (index($5, "is used for incoming transfer") > 0 && index($5, "Receive File As") > 0) {
            if (!match($5, /Transfer profile '\''[^'\'']*'\''/)) next
            # RENAMES (2026-08): the log names the profile as it was called
            # THEN; the PSUB map holds the CURRENT names. Fold through the
            # PROFILE map (rnp_canon — profiles have their own, 218 renamed)
            # or every renamed flow lands in UNMAP and its rows vanish as
            # "unattributable" — which silently emptied this table.
            rp = toupper(rnp_canon(substr($5, RSTART + 18, RLENGTH - 19)))
            if (!(rp in PSUB)) { UNMAP[rp] = 1; next }
            nsub2 = split(PSUB[rp], SUBS2, "\037")
            d = $1; gsub(/-/, "", d); k = d $2            # -> the _files.tsv sortkey shape
            for (i2 = 1; i2 <= nsub2; i2++) {
                e = SUBS2[i2]; u = toupper(e)
                if (KIND[u] == "") KIND[u] = "Subscription"   # Account evidence, if any, still wins
                DISP[u] = e; N[u]++; CFA[u] = 1
                if (k > LASTK[u]) { LASTK[u] = k; LASTD[u] = $1 " " $2 }
            }
            next
        }
        if (index($5, "stop further route execution") == 0) next
        e = ent($5); if (e == "") next
        k = (ACC == "SECURETRANSPORT" || ACC == "") ? "Subscription" : "Account"
        # ARPA0001 "publishing the file {…} to an account": the bracket names
        # the destination ACCOUNT, not a subscription. Account evidence wins
        # over other lines naming the same entity.
        if (k == "Subscription" && substr($5, 1, 9) == "ARPA0001:") k = "Account"
        # RENAMES (2026-08): the bracket carries the name that was current when
        # the line was written. Fold a SUBSCRIPTION to the name the config uses
        # now — before the key is taken, so the old and new spellings of one
        # flow group into a single row instead of two. Accounts are not folded:
        # that export renamed subscriptions and profiles, never accounts.
        if (k == "Subscription") e = rn_canon_pfx(e)
        u = toupper(e); CRT[u] = 1
        if (KIND[u] != "Account") KIND[u] = k
        DISP[u] = e; N[u]++
        d = $1; gsub(/-/, "", d); k = d $2      # -> the _files.tsv sortkey shape
        if (k > LASTK[u]) { LASTK[u] = k; LASTD[u] = $1 " " $2 }
        next
    }
    {                                           # _files.tsv: a later OK File clears it
        if ($2 == "Failed" || $2 == "Expired") next
        a = toupper($3); s = toupper($12); sk = $6
        if (a != "" && (a in LASTK) && sk > LASTK[a]) CLR[a] = 1
        if (s != "" && (s in LASTK) && sk > LASTK[s]) CLR[s] = 1
    }
    END {
        for (u in N) {
            tot++
            if (u in CLR) { cleared++; continue }
            # UC3 poll-recovery: a successful poll AFTER the last message means
            # the flow works again, files or no files — same tail-strip as the
            # poll side so the two name forms meet
            us = u; sub(/_(SS?|C)CP_.*$/, "", us)
            if (KIND[u] == "Subscription" && substr(us, 1, 3) == "UC3" && (us in PMAX) && PMAX[us] > LASTK[u]) { cleared++; continue }
            cz = ((u in CRT) && (u in CFA)) ? "Route stopped + Receive File As" \
                 : ((u in CFA) ? "Receive File As not set" : "Route stopped")
            printf "%s\t%s\t%d\t%s\t%s\t%s\n", LASTK[u], DISP[u], N[u], LASTD[u], KIND[u], cz
        }
        for (up in UNMAP) nun++
        printf "%d\t%d\t%d\n", tot + 0, cleared + 0, nun + 0 > STATS
    }
' "$PROFSUB" "$PARSED" "$FILES_TSV" | LC_ALL=C sort -r > "$TMP/rows"

IFS=$'\t' read -r ntot ncleared nunmapped < "$TMP/stats"
nlist=$(wc -l < "$TMP/rows" | tr -d ' ')

{
    printf 'TITLE\tDeploy errors\n'
    printf 'DESC\tAccounts and subscriptions a configuration defect stops dead — a route abandoned mid-execution, or a PeSIT profile that cannot receive — and that have not had a successful transfer since.\n'
    printf 'INTRO\tTwo server-log lines, both a **deployment mistake** rather than a runtime fault. **"Step configuration suggests to stop further route execution"** (ARSP0001) means a routing step failed and its configuration told SecureTransport to **abandon the rest of the route** — nothing downstream ran for that file. **"…is used for incoming transfer, but '"'"'Receive File As'"'"' field not set"** means a PeSIT transfer profile is missing one field, so **every incoming transfer of that flow errors**; the row names the **subscription** the profile belongs to, since the message itself names only the platform account. The **Cause** column says which applies. One row per **account**, or per **subscription** where the line names the platform account SECURETRANSPORT; newest problem first. **Only the unresolved ones are listed**: an entity that had an **OK File after its last such message** is left out, because something has got through since — and a **UC3 subscription whose poll succeeded after it** is left out too, even when the poll found nothing: the listing works again. Of **%s** entities with a message, **%s** recovered and **%s** are listed.\n' \
        "$ntot" "$ncleared" "$nlist"
    printf 'KEYWORDS\tdeploy,route,routing,step,ARSP0001,stopped,abandon,advanced routing,unresolved,receive file as,pesit,profile,incoming,config\n'
    # Newest problem first is the page DEFAULT (sort=COL:DIR, dir -1 = desc),
    # never `nosort` — that would disable the header clicks altogether. The
    # Last message column is ISO, so a text sort is chronological.
    printf 'TABLE\t\twide\tsort=4:-1\n'
    printf 'HEAD\tAccount or subscription\tType\tCause\tMessages\tLast message\n'
    printf 'KIND\ttext\ttext\ttext\tnum\ttext\n'
    LC_ALL=C awk -F'\t' '
        { sub_ = (tolower($5) == "account") ? "accounts" : "subscriptions"
          printf "ROW\t@{alink=%s/%s}%s\t%s\t%s\t%d\t%s\n", sub_, $2, $2, $5, $6, $3, $4
          m += $3 }
        END { printf "TOTAL\tTotal (%d entities)\t\t\t@{class=num}%d\t\n", NR, m + 0 }
    ' "$TMP/rows"
    printf 'NOTE\tThe entity is the **account** the line names, or the **subscription** when that account is the platform'"'"'s own SECURETRANSPORT — blacklisted everywhere else on the site, so it would make a useless row. An account'"'"'s **@FE…** endpoint suffix is stripped, as the transfer parse strips it, so the name links to its detail page.\n'
    printf 'NOTE\tOnly UNRESOLVED entities appear: one whose last message is followed by an **OK File** has recovered and is left out — as has a **UC3 subscription** whose last message is followed by a **successful poll**, files or no files. The comparison is exact to the millisecond, so a recovery on the SAME day still counts.\n'
    printf 'NOTE\tA **Receive File As** row names the subscription its transfer profile belongs to: the message names the platform account `SECURETRANSPORT`, and a transfer profile is internal flow plumbing with no page of its own. **Config hygiene** lists the same defect per profile, including the ones already recovered.%s\n' \
        "$( [ "${nunmapped:-0}" -gt 0 ] && printf ' **%s** profile(s) matched no single configured flow and are only counted there.' "$nunmapped" )"
    printf 'FOOT\tGenerated on %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

echo "Data written to $OUT ($nlist unresolved of $ntot; $ncleared recovered)." >&2
