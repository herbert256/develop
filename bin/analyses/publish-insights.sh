#!/usr/bin/env bash
#
# bin/analyses/publish-insights.sh — the BOX-REASON SIDECAR
# (data/analyses/reports/_subs-boxes.tsv: subscription <TAB> the reason of the
# most specific box it sits in), read by the Entities Subscriptions Error
# view's Reason column (publish_lib.sh) and failed.sh's server rows. Called by
# bin/analyses/publish.sh (its full run and its catch-up — the failed.sh
# catch-up rewrote _errpage-evidence.tsv, the sidecar's one input that moved).
# Its three insight PAGES went 2026-09-29 (user request): Whitelist audit and
# Config hygiene with the Cleanup group, Subscriptions in boxes with the
# Overview trim — the box memberships (_subs_box_rows) stay, as the sidecar's
# source. Runs from any directory; no arguments.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../publish_lib.sh"   # cd's to the repo root; html_head/esc/…

XREF="$DATA/flow-manager/xref"
FBASE="$DATA/flow-manager/base"
FILESC="$DATA/transfer/cache/_files.tsv"
TRPT="$DATA/transfer/reports"
SRPT="$DATA/server/reports"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT


# ---- the BOXES --------------------------------------------------------------
# What is true of each CONFIGURED subscription, one box per signal (the former
# Subscriptions in boxes page's columns). The boxes come from three kinds of
# source: a report's own .rpt, boxes derived here from _files.tsv (One-legged,
# Waiting, Expired), and the config/coverage caches (Not seen, Seen, OK,
# Error). _subs_box_rows below is the ONE authority for the box list. A
# missing source .rpt (production skips some server reports) contributes no
# rows.
# Missing cron reads the pageless missing-cronjobs.rpt like any report-backed
# column (the Polling page shows those rows as Schedule "no cron").
# _subs_box_rows -> "<colno>\t<subscription>" for every box, one line per
# (box, subscription). (The Accounts in boxes page that shared it went
# 2026-09-29.)
# endk() — a _files.tsv row's END (col 24, "YYYY-MM-DD HH:MM:SS.mmm") in the
# col 6 sortkey shape "YYYYMMDDHH:MM:SS.mmm", the start sortkey when the parse
# wrote no end: "an OK File after it" means one that ENDED after it, the
# 2026-09-12 rule result.sh applies (a retry burst that started before the
# error and delivered after it is a recovery). Shared by every box below.
ENDK_AWK='
    function endk(   e) { e = $24; return (e ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) ? substr(e, 1, 4) substr(e, 6, 2) substr(e, 9, 2) substr(e, 12) : $6 }
'
_subs_box_rows() {
    local spec f c nf
        # column 1 — One-legged, REFINED (2026-07): a one-legged CoreId is only
        # a problem when NO OK File followed it — an OK delivery after the last
        # one-legged occurrence means the flow recovered. Computed from
        # _files.tsv directly (pirates' own condition is col 10 == 1, so the
        # membership can only shrink, never disagree with pirates-details);
        # the cache carries full sortkeys, so "after" is exact, not per-day.
        # OK = not Failed/Expired (the site-wide rule: Waiting counts as OK),
        # and "after" means the OK File ENDED after it (col 24, the 2026-09-12
        # rule result.sh applies — endk() puts that end in the sortkey shape;
        # the start when the parse wrote no end).
        # columns 5 + 6 — Waiting / Expired: the subscription's LAST _files
        # entry (max sortkey; the later row wins a tie, as in result.sh) has
        # that outcome — the newest staged file is still awaiting pickup (5)
        # or was deleted before any pickup (6).
        if [ -f "$FILESC" ]; then
            awk -F'\t' "$ENDK_AWK"'
                $12 == "" || $12 == "Unknown" { next }   # "Unknown" = no subscription (2026-09-29): in no box
                {
                    if (!(($12) in ls)) orda[++na] = $12
                    if ($6 >= ls[$12]) { ls[$12] = $6; lout[$12] = $2 }
                    if ($10 == 1) { if (!(($12) in lp)) ord[++n] = $12; if ($6 > lp[$12]) lp[$12] = $6 }
                    if ($2 != "Failed" && $2 != "Expired") { ek = endk(); if (ek > lo[$12]) lo[$12] = ek }
                }
                END {
                    for (i = 1; i <= n; i++) { s = ord[i]
                        if (lo[s] == "" || lo[s] <= lp[s]) print "1\t" s }
                    for (i = 1; i <= na; i++) { s = orda[i]
                        if (lout[s] == "Waiting") print "5\t" s
                        else if (lout[s] == "Expired") print "6\t" s }
                }' "$FILESC"
        fi
        # colno : rpt : page href (analyses-relative) : column label : ROW field
        # holding the subscription name (no-remote-dir leads with its Last date)
        for spec in \
            "2:$TRPT/from-green-to-red.rpt:failed.html:From green to red:2" \
            "3:$SRPT/went-kaput.rpt:-:Trouble after success:2" \
            "4:$TRPT/only-red.rpt:failed.html:Only red:2" \
            "7:$SRPT/no-remote-dir.rpt:uc-status-uc3.html:No Dir:3" \
            "8:$SRPT/no-remote-files.rpt:uc-status-uc3.html:No Files:3" \
            "9:$TRPT/missing-cronjobs.rpt:polling.html:Missing cron:2" \
            "10:$TRPT/went-quiet.rpt:../transfer/went-quiet-subscriptions.html:Went quiet:2"; do
            c=${spec%%:*}; f=${spec#*:}; f=${f%%:*}; nf=${spec##*:}
            [ -f "$f" ] || continue
            # table 1 only; skip empty-state colspan rows and pseudo-values —
            # a real subscription name never contains a space (which also drops
            # no-remote-dir's "Clone - UC3_…" config artifacts)
            awk -F'\t' -v c="$c" -v nf="$nf" '
                $1 == "TABLE" { t++ }
                $1 == "ROW" && t == 1 {
                    if ($2 ~ /^@\{colspan/) next
                    nm = $nf; sub(/^@\{[^}]*\}/, "", nm)
                    if (nm == "" || nm ~ / / || substr(nm, 1, 1) == "(") next
                    print c "\t" nm
                }' "$f"
        done
        # column 11 has NO report of its own — it is a state, read straight from
        # the source the Entities views are built from, so the figures here and
        # there cannot drift:
        #   11 not seen — showseen's coverage TSV, col 3 = the seen flag.
        [ -f "$TRPT/coverage/subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 == 0 { print "11\t" $1 }' "$TRPT/coverage/subscriptions.tsv"
        #   13 OK — result "green": the newest File was delivered. Also no report;
        #      the Subscriptions / OK entity view is the list. Including it is what
        #      turns this from a problem list into a complete box-up of the estate,
        #      so the first box can honestly say TOTAL.
        [ -f "$FBASE/_subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 == "green" { print "13\t" $1 }' "$FBASE/_subscriptions.tsv"
        #   17 seen — coverage col 3 != 0, the exact complement of 11. The
        #      Subscriptions / Seen entity view is the list, and the invariant
        #      is Seen + Not seen = Total.
        #   18 error — result "red": its newest File Failed, or a server-log
        #      Error after its last transfer, or (a UC3 that never transferred)
        #      three failed connection attempts in a row — never merely an
        #      Expired newest File, which is orange. The Subscriptions / Error
        #      entity view is the list.
        [ -f "$TRPT/coverage/subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 != 0 { print "17\t" $1 }' "$TRPT/coverage/subscriptions.tsv"
        [ -f "$FBASE/_subscriptions.tsv" ] && \
            awk -F'\t' '$1 != "" && $3 == "red" { print "18\t" $1 }' "$FBASE/_subscriptions.tsv"
        # column 14 — Connection failures, UNRESOLVED (the One-legged rule): the
        # server logged a connection failure for this subscription and NO OK File
        # followed it. A flow whose connections failed and then delivered has
        # recovered; site-failures keeps the full history either way. The filter
        # is what makes the column mean "still broken". "Followed" = the OK
        # File ENDED after the failure (col 24 — result.sh's rule; endk()).
        # The failure instant comes from the @data:loglines payload (newest
        # first, so entry 1 is the latest) rather than the row's Last seen DATE,
        # which is too coarse to order against an OK File on the same day; a row
        # without the payload falls back to that date at END of day, so only an
        # OK on a LATER day clears it — the conservative reading, since wrongly
        # clearing hides a live problem while wrongly flagging only costs a look.
        if [ -f "$SRPT/site-failures.rpt" ] && [ -f "$FILESC" ]; then
            awk -F'\t' "$ENDK_AWK"'
                FILENAME ~ /site-failures/ {
                    if ($1 == "TABLE") { t++; next }
                    if ($1 != "ROW" || t != 1) next
                    nm = $2; sub(/^@\{[^}]*\}/, "", nm); if (nm == "") next
                    key = ""
                    for (i = 3; i <= NF; i++)
                        if (index($i, "@data:loglines=") == 1) {
                            split(substr($i, 16), L, "\037"); s = L[1]
                            if (s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) {
                                d = substr(s, 1, 10); gsub(/-/, "", d); key = d substr(s, 12, 12)
                            }
                            break
                        }
                    if (key == "" && $6 ~ /^[0-9]/) { d = $6; gsub(/-/, "", d); key = d "23:59:59.999" }
                    if (key != "") cf[nm] = key
                    next
                }
                { if ($12 != "" && $2 != "Failed" && $2 != "Expired") { ek = endk(); if (ek > lok[$12]) lok[$12] = ek } }
                END { for (s in cf) if (lok[s] == "" || lok[s] < cf[s]) print "14\t" s }
            ' "$SRPT/site-failures.rpt" "$FILESC"
        fi
        # columns 20 / 21 — Login errors (in / out), UNRESOLVED (2026-08): the
        # Logons report's failure rows joined onto subscriptions — in: the
        # login's Disallowed/Bad key/Key failures/Locked funnel counts, via
        # _logins-subscriptions; out: the remote host's outbound auth
        # failures, via _hosts-subscriptions. The one-legged rule applies: an
        # OK File AFTER the last error clears the flag. The out side takes its
        # instant from the newest loglines entry (falling back to the Last
        # date at end of day); the in side has only per-DATE funnel buckets
        # (metrics m2/m4/m5/m6 = Disallowed/Bad key/Key failures/Locked), so
        # the error date counts as end-of-day — only a LATER day's OK clears.
        if [ -f "$SRPT/logon.rpt" ] && [ -f "$FILESC" ]; then
            awk -F'\t' -v LS="$XREF/_logins-subscriptions.tsv" "$ENDK_AWK"'
                BEGIN { while ((getline l < LS) > 0) { n = split(l, a, "\t")
                            if (n >= 2 && a[1] != "") SUBS[toupper(a[1])] = SUBS[toupper(a[1])] "\037" a[2] }
                        close(LS) }
                FILENAME ~ /logon\.rpt/ {
                    if ($1 == "TABLE") { t++; next }
                    if ($1 != "ROW" || t != 1) next
                    nm = $2; sub(/^@\{[^}]*\}/, "", nm); if (nm == "") next
                    if (($4+0) + ($7+0) + ($8+0) + ($9+0) == 0) next
                    led = ""
                    for (i = 3; i <= NF; i++) if (index($i, "@data:buckets=") == 1) {
                        nb = split(substr($i, 15), B, ",")
                        for (j = 1; j <= nb; j++) { split(B[j], M, ":")
                            if ((M[4]+0) + (M[6]+0) + (M[7]+0) + (M[8]+0) > 0 && M[1] > led) led = M[1] }
                        break }
                    if (led == "") next
                    key = led; gsub(/-/, "", key); key = key "23:59:59.999"
                    ku = toupper(nm)
                    if (ku in SUBS) { m2 = split(substr(SUBS[ku], 2), S2, "\037")
                        for (i2 = 1; i2 <= m2; i2++) if (S2[i2] != "" && (!(S2[i2] in ce) || key > ce[S2[i2]])) ce[S2[i2]] = key }
                    next
                }
                { if ($12 != "" && $2 != "Failed" && $2 != "Expired") { ek = endk(); if (ek > lok[$12]) lok[$12] = ek } }
                END { for (s in ce) if (lok[s] == "" || lok[s] < ce[s]) print "20\t" s }
            ' "$SRPT/logon.rpt" "$FILESC"
            awk -F'\t' -v HS="$XREF/_hosts-subscriptions.tsv" "$ENDK_AWK"'
                BEGIN { while ((getline l < HS) > 0) { n = split(l, a, "\t")
                            if (n >= 2 && a[1] != "") SUBS[tolower(a[1])] = SUBS[tolower(a[1])] "\037" a[2] }
                        close(HS) }
                FILENAME ~ /logon\.rpt/ {
                    if ($1 == "TABLE") { t++; next }
                    if ($1 != "ROW" || t != 2) next
                    h = $2; sub(/^@\{[^}]*\}/, "", h); if (h == "") next
                    key = ""
                    for (i = 3; i <= NF; i++) if (index($i, "@data:loglines=") == 1) {
                        split(substr($i, 16), L, "\037"); s = L[1]
                        if (s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) {
                            d = substr(s, 1, 10); gsub(/-/, "", d); key = d substr(s, 12, 12) }
                        break }
                    if (key == "" && $11 ~ /^[0-9]/) { d = $11; gsub(/-/, "", d); key = d "23:59:59.999" }   # Last ($11; $10 is First — 2026-09-29 fix)
                    if (key == "") next
                    hu = tolower(h)
                    if (hu in SUBS) { m2 = split(substr(SUBS[hu], 2), S2, "\037")
                        for (i2 = 1; i2 <= m2; i2++) if (S2[i2] != "" && (!(S2[i2] in ce) || key > ce[S2[i2]])) ce[S2[i2]] = key }
                    next
                }
                { if ($12 != "" && $2 != "Failed" && $2 != "Expired") { ek = endk(); if (ek > lok[$12]) lok[$12] = ek } }
                END { for (s in ce) if (lok[s] == "" || lok[s] < ce[s]) print "21\t" s }
            ' "$SRPT/logon.rpt" "$FILESC"
        fi
        # (column 12 "Server log only" and column 19 "Failing polls" were the
        # blue result and the UC3 "server - error" status, both removed
        # 2026-09-27; their numbers stay unused so no box id changes meaning.)
        # column 15 — Deploy: the server told SecureTransport to ABANDON the
        # route (deploy-errors.rpt, ARSP0001 "stop further route execution").
        # That report already drops anything that recovered, so this box
        # inherits the UNRESOLVED reading like column 14. Its rows name an
        # ACCOUNT or a SUBSCRIPTION, so a subscription is flagged when it is
        # named directly OR when one of its configured accounts is — and, for
        # the account case, only when the flow itself has NOT moved a file OK
        # (ENDED, col 24) after the row's last message (2026-08-31 audit: box
        # 15 is the top-ranked Reason, and an account row fanned onto every
        # flow of a hybrid account put its healthy siblings in the red Deploy
        # box).
        if [ -f "$SRPT/deploy-errors.rpt" ]; then
            _fc15="$FILESC"; [ -f "$_fc15" ] || _fc15=/dev/null
            awk -F'\t' -v AS="$XREF/_accounts-subscriptions.tsv" -v SUBF="$FBASE/_subscriptions.tsv" -v FC="$_fc15" "$ENDK_AWK"'
                BEGIN { while ((getline l < AS) > 0) { n = split(l, a, "\t")
                            if (n >= 2 && a[1] != "") ASUB[toupper(a[1])] = ASUB[toupper(a[1])] "\037" a[2] }
                        close(AS)
                        while ((getline l < SUBF) > 0) { split(l, a, "\t")
                            if (a[1] != "") EST[toupper(a[1])] = 1 }
                        close(SUBF) }
                FILENAME == FC { if ($12 != "" && $2 != "Failed" && $2 != "Expired") { ek = endk(); if (ek > lok[toupper($12)]) lok[toupper($12)] = ek }; next }
                $1 == "TABLE" { t++; next }
                $1 != "ROW" || t != 1 { next }
                { nm = $2; sub(/^@\{[^}]*\}/, "", nm); if (nm == "") next
                  k = toupper(nm)
                  # a "Subscription" name NOT in the configured estate would add
                  # a phantom row (the table rows are the union of the box
                  # lists) — send it through the account map instead.
                  if ($3 == "Subscription" && (k in EST)) { print "15\t" nm; next }
                  # the row Last message (col 6, "YYYY-MM-DD HH:MM:SS.mmm") in the
                  # _files.tsv sortkey shape; a flow with an OK File after it has recovered
                  key = $6; if (key ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) key = substr(key, 1, 4) substr(key, 6, 2) substr(key, 9, 2) substr(key, 12); else key = ""
                  if (k in ASUB) { m = split(substr(ASUB[k], 2), S, "\037")
                                   for (i = 1; i <= m; i++) if (S[i] != "" && (key == "" || lok[toupper(S[i])] == "" || lok[toupper(S[i])] < key)) print "15\t" S[i] } }
            ' "$_fc15" "$SRPT/deploy-errors.rpt"
        fi
        :   # the tests above are the last commands; keep the exit status 0
}

# The "main reason" sidecar (2026-08): data/analyses/reports/
# _subs-boxes.tsv, "subscription <TAB> box label" — ONE line per subscription,
# naming the most specific box it sits in. The Entities Subscriptions Error
# view (publish_lib.sh) and failed.sh's server rows fall back to it for their
# Reason, so a red flow says WHY in the same vocabulary this page uses. Membership comes from _subs_box_rows (the one authority); the
# order below is the only thing decided here — most specific cause first.
# Boxes that are states rather than a cause are left out entirely: OK, Seen,
# Not seen, and — deliberately — ERROR, box 18. "Error" only
# restates the red the row is already painted in, so it is not a reason.
# The two ORANGE boxes that describe a MOOD rather than a fault are out for the
# same reason: "Trouble after success" says only that something was logged, and
# "Went quiet" that nothing was — neither tells you what broke, and both would
# outrank nothing on a row that is already red. RED boxes therefore come first
# in the order, the remaining orange ones (a missing cron, an empty remote dir,
# a file waiting for pickup) only after them.
# A red flow in NO box at all is red by SERVER-LOG evidence — the after-last-
# transfer flip — so its reason comes from that evidence instead: _flip_reason()
# reads the Trouble-after-Success report, which carries the very line that
# reddened it, and names the fault. Where the line matches a red box the box
# name is used; the remaining causes are phrased like the deploy-errors Cause
# column, which is the same kind of short verdict.
# The DEPLOY box is refined one level further, because that box holds two
# unrelated defects and the report already tells them apart: its label becomes
# the deploy-errors Cause — "Route stopped" or "Receive File As not set".
_box_reason_order() {
    printf '%s\n' \
        "1${TAB}15${TAB}Deploy" \
        "2${TAB}7${TAB}No Dir" \
        "3${TAB}14${TAB}Connection failures" \
        "4${TAB}21${TAB}Login errors (out)" \
        "5${TAB}20${TAB}Login errors (in)" \
        "6${TAB}1${TAB}One-legged" \
        "7${TAB}6${TAB}Expired" \
        "8${TAB}4${TAB}Only red" \
        "9${TAB}2${TAB}From green to red" \
        "10${TAB}9${TAB}Missing cron" \
        "11${TAB}8${TAB}No Files" \
        "12${TAB}5${TAB}Waiting"
}
# The evidence classifier for a red-by-server-log flow (see above). Input: the
# newest Error/Warn line that flipped it. Output: a short cause in the boxes'
# vocabulary, or "" when the line says nothing recognisable — better a blank
# cell than a guess. The function TEXT lives in bin/flip-reason.awk (2026-08):
# failed.sh classifies its Reason column with the same function, and the
# two must never drift apart — the Entities Reason and the Failed Subscriptions
# page's Reason are the same verdict about the same evidence.
_flip_reason_awk() {
    cat "$SCRIPT_DIR/../flip-reason.awk"
}
_write_box_reason_sidecar() {   # $1 = the _subs_box_rows output
    local TAB; TAB=$(printf '\t')
    local side="$DATA/analyses/reports/_subs-boxes.tsv" tmpp
    mkdir -p "$(dirname "$side")"
    tmpp=$(mktemp "${TMPDIR:-/tmp}/axboxprio.XXXXXX")
    _box_reason_order > "$tmpp"
    local dep="$SRPT/deploy-errors.rpt"; [ -f "$dep" ] || dep=/dev/null
    local asx="$XREF/_accounts-subscriptions.tsv"; [ -f "$asx" ] || asx=/dev/null
    # the Trouble-after-Success EVIDENCE sidecar (name, latest issue, source,
    # message) — every subscription with post-transfer errors, red ones
    # included; its report page lists the still-green half only
    local srvsub="$DATA/server/cache/subscriptions"
    local kap="$SRPT/_kaput-evidence.tsv"; [ -f "$kap" ] || kap=/dev/null
    # a SECOND evidence source, same layout: the newest Error/Warning line the
    # flow's own drill pages show (bin/transfer/reports/failed.sh). The
    # kaput sidecar only covers flows whose last transfer was OK, so a flow that
    # is red BY ITS OWN last file and sits in no specific box has no reason
    # without this — though its error page names the fault.
    local epv="$TRPT/_errpage-evidence.tsv"; [ -f "$epv" ] || epv=/dev/null
    printf '%s\n' "$1" | awk -F'\t' -v P="$tmpp" -v DEP="$dep" -v ASX="$asx" -v KAP="$kap" -v EPV="$epv" -v SRVSUB="$srvsub" "$(_flip_reason_awk)"'
        BEGIN { while ((getline l < P) > 0) { n = split(l, a, "\t")
                    if (n >= 3) { rank[a[2]] = a[1]; lab[a[2]] = a[3] } }
                close(P)
                # the two DEPLOY causes, keyed per subscription: the report row
                # names a subscription (its own cause, which always wins) or an
                # account (the cause carries to every subscription configured
                # for it — box 15 flags them the same way). Rows arrive most
                # frequent first, so the first account cause reaching a
                # subscription is the loudest one.
                while ((getline l < ASX) > 0) { n = split(l, a, "\t")
                    if (n >= 2 && a[1] != "") AS[toupper(a[1])] = AS[toupper(a[1])] "\037" a[2] }
                close(ASX)
                t = 0
                while ((getline l < DEP) > 0) { n = split(l, a, "\t")
                    if (a[1] == "TABLE") { t++; continue }
                    if (a[1] != "ROW" || t != 1 || n < 4) continue
                    nm = a[2]; sub(/^@\{[^}]*\}/, "", nm); if (nm == "" || a[4] == "") continue
                    if (a[3] == "Subscription") { DC[toupper(nm)] = a[4]; own[toupper(nm)] = 1; continue }
                    k = toupper(nm)
                    if (k in AS) { m = split(substr(AS[k], 2), S, "\037")
                        for (i = 1; i <= m; i++) if (S[i] != "" && !(toupper(S[i]) in own) && DC[toupper(S[i])] == "")
                            DC[toupper(S[i])] = a[4] } }
                close(DEP)
                # the server-log evidence per subscription: the newest
                # Error/Warn line after the last OK transfer, which is exactly
                # the line the red flip acted on (col 4 of the sidecar)
                while ((getline l < KAP) > 0) { n = split(l, a, "\t")
                    if (n >= 4 && a[1] != "") { EV[toupper(a[1])] = a[4]
                        if (n >= 5) EVE[toupper(a[1])] = a[5] } }   # newest E-level line
                close(KAP)
                # The error pages, NEWEST LAST as the file is sorted by stamp:
                # keep them as an ordered candidate list per flow so the reason
                # can walk them newest-first and take the first that classifies.
                # The newest line of a burst is often the least informative
                # ("… - Failed to create connection" beside the "Connection
                # failure while <flow> tried to connect …" that explains it).
                while ((getline l < EPV) > 0) { n = split(l, a, "\t")
                    if (n >= 4 && a[1] != "") { k2 = toupper(a[1])
                        EPN[k2]++; EPM[k2, EPN[k2]] = a[4]; EPL[k2, EPN[k2]] = a[3] } }
                close(EPV) }
        # The FIRST classification the error page yields, reading from the
        # START: the opening error of a failure is the cause and everything
        # after it is consequence — a rejected host key, then "failed to create
        # connection", then the connection failure, then a trailing ARRC0029
        # "No files were processed during step execution". ERROR lines before
        # warnings, each in page order (the sidecar stores them oldest first).
        function pagereason(nm3,   k3, i, r3) {
            k3 = toupper(nm3)
            for (i = 1; i <= EPN[k3]; i++) if (EPL[k3, i] == "Error") { r3 = flip_reason(EPM[k3, i]); if (r3 != "") return r3 }
            for (i = 1; i <= EPN[k3]; i++) if (EPL[k3, i] != "Error") { r3 = flip_reason(EPM[k3, i]); if (r3 != "") return r3 }
            return "" }
        # the newest Error/Warn line the flow logged for itself ("" when it has
        # no ring); the rings are newest-first, so line 1 is it
        function ringtop(nm2,   f, l2, a2) {
            f = SRVSUB "/" nm2 "_err_warn.tsv"
            if ((getline l2 < f) > 0) { close(f); split(l2, a2, "\t"); return a2[5] }
            close(f); return "" }
        # the Deploy label is replaced by the CAUSE behind it; a deploy row we
        # cannot attribute keeps the box name
        function label(box, nm2,   c) {   # nm2: "sub" is an awk BUILT-IN name
            if (box != 15) return lab[box]
            c = DC[toupper(nm2)]
            return (c != "") ? c : lab[box] }
        # every subscription the boxes named at all, box or not: the ones with
        # no ranked box are the candidates for the evidence reason. LB[] keeps
        # every label a flow qualifies for, so the END block can let RECENCY
        # choose between them.
        $2 != "" { all[$2] = 1 }
        $2 != "" && ($1 in rank) {
            lb = label($1, $2)
            LB[$2] = LB[$2] "\037" lb "\037"
            if (!($2 in best) || rank[$1] + 0 < best[$2] + 0) { best[$2] = rank[$1]; bl[$2] = lb } }
        END { for (s in all) {
                  # THE SERVER LOG ON ITS OWN ERROR PAGE COMES FIRST (2026-08).
                  # For a flow with a failed File, the page its Failed Subscriptions row opens
                  # is the evidence a reader will check, so the Reason has to be
                  # what that page says — not a box the flow also happens to
                  # sit in.
                  pr = pagereason(s)
                  if (pr != "") { print s "\t" pr; continue }
                  # THEN THE NEWEST LINE ACROSS THE FLOW\047S CONNECTED RINGS
                  # (the kaput evidence: subscription, account, login, and the
                  # single configured host). A box is a rank, not a clock — a
                  # flow with an old route-stop in the Deploy box and a
                  # connection failure from this week read "Route stopped"
                  # while the log had moved on (UC1_ZG_IKAZ_IMPRESS, 2026-08).
                  # The reason is descriptive, not a verdict: the COLOUR still
                  # never rests on a line attributed to no flow.
                  # newest ERROR first; the newest line of any level only when
                  # no error followed at all — a benign warning that happens to
                  # be newer must not outrank the error that explains the red
                  kr = flip_reason(EVE[toupper(s)])
                  if (kr == "") kr = flip_reason(EV[toupper(s)])
                  if (kr != "") { print s "\t" kr; continue }
                  # boxes are the source for everything else
                  if (s in best) {
                      # A flow can sit in several CAUSE boxes at once, and the
                      # fixed order then picks the most specific — which is not
                      # always the CURRENT one: a flow with an old route-stop
                      # and a connection failure from this morning read "Route
                      # stopped" while its log said otherwise. Where the flow
                      # own newest Error/Warn line classifies to a box it is
                      # ALSO in, that wins: same vocabulary, same membership
                      # rules, but the reason now names what the log last said.
                      nl = flip_reason(ringtop(s))
                      if (nl != "" && index(LB[s], "\037" nl "\037") > 0) print s "\t" nl
                      else print s "\t" bl[s]
                      continue }
                  r = flip_reason(EV[toupper(s)])
                  if (r != "") print s "\t" r } }' | LC_ALL=C sort > "$side.tmp"
    rm -f "$tmpp"
    mv "$side.tmp" "$side"
}

_pi_probs=$(_subs_box_rows)
_write_box_reason_sidecar "$_pi_probs"
echo "Wrote the box-reason sidecar $DATA/analyses/reports/_subs-boxes.tsv." >&2
