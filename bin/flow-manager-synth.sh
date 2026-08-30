#!/usr/bin/env bash
#
# flow-manager-synth.sh — SYNTHESIZE the two FlowManager exports
# (input/<env>/flow-manager/{subscriptions,partners}.json) from the TRANSFER
# LOGS, for an environment that has real log exports but no configuration
# export (production, 2026-08). A MANUAL stopgap: run it once per log drop
# until a real export exists — a real export simply overwrites these files
# and everything downstream is none the wiser.
#
# WHAT IT CAN AND CANNOT KNOW. The whole site distinguishes CONFIGURED from
# SEEN; a synthesized config is by construction "configured = seen", so the
# coverage/not-in-flow-manager analyses go vacuous for this env. Folder
# paths, FM deep links, templates and partner groups cannot be derived and
# are left out (their reports degrade to empty). Everything the parse and
# the entity machinery need IS here, in exactly the shape
# bin/flow-manager.sh extracts:
#
#   subscriptions.json  [ { name, patternName,
#                           parameters: { customAttribute_FlowIdentifier,
#                                         source_folder_monitoring_scan_dir |
#                                         target_working_dir },
#                           participants: [ { name, comProfileId } ] } ]
#   partners.json       [ { name,
#                           communicationProfiles: [ { businessId, login,
#                                                      hosts: [...] } ],
#                           customAttributes: { AllowIP1: "ip;ip;…" } } ]
#
# THE DERIVATION (production 2026-08 reality: the Transfer Site column holds
# only "none"/platform values — the flow identity lives in the Transfer
# Profile column, e.g. STRESSTSTIN and the STOUTFM<n> family):
#
#   subscription  one per distinct Transfer Profile (UNKNOWN excluded), named
#                 BY THE PROFILE — customAttribute_FlowIdentifier = the same
#                 name, so parse.sh's REVERSE CONFIG FALLBACK attributes
#                 every leg (the logged site column is blank after the
#                 blacklist, exactly the case that fallback exists for).
#                 patternName carries the pesit push marker matching the
#                 flow's observed pesit leg direction, so the fallback's
#                 disambiguation logic holds if a profile ever maps to two.
#   flowdir       the majority FILE-MOVEMENT over the profile's legs (partner
#                 protocols move the file the way the connection points,
#                 pesit the opposite — the parse's own FLOWDIR rule): out ->
#                 source_folder_monitoring_scan_dir, in -> target_working_dir,
#                 tie -> neither (relay).
#   participants  the accounts co-occurring with the profile (the "@tail" is
#                 stripped like parse.sh does; blacklisted accounts excluded),
#                 each referencing its account's FIRST comm profile.
#   partner       one per account; one communicationProfile PER LOGIN seen
#                 with it (blacklisted logins excluded), all sharing the
#                 account's endpoint set.
#   hosts         the DNS-named remote hosts seen with the account (an IP is
#                 never a configured endpoint here — outbound IPs resolve
#                 through input/<env>/ip/ once real, inbound ones belong in
#                 the whitelist).
#   AllowIP       the IPv4 sources of the account's INBOUND legs.
#
# Reads the blacklist (bin/blacklist.sh format) so platform pseudo-entities
# never become configured names. CSV tokenizing is the same hand-rolled
# quoted-comma-safe walk parse.sh uses.
#
# Usage:
#   AXWAY_ENV=production bin/flow-manager-synth.sh
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."
source bin/env.sh
source bin/fastawk.sh

IN="input/$AXWAY_ENV/transfer"
OUTDIR="input/$AXWAY_ENV/flow-manager"
shopt -s nullglob
files=("$IN"/*.csv)
shopt -u nullglob
if [ ${#files[@]} -eq 0 ]; then
    echo "flow-manager-synth: no CSVs in $IN — nothing to derive." >&2
    exit 1
fi
mkdir -p "$OUTDIR"

LC_ALL=C awk -v SUBSJ="$OUTDIR/subscriptions.json.tmp" -v PARTJ="$OUTDIR/partners.json.tmp" -v BL="input/blacklist.txt" '
    function split_csv(line,    n, i, c, inquotes, cur) {
        delete field
        n = 0; cur = ""; inquotes = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (inquotes) {
                if (c == "\"") { if (substr(line, i+1, 1) == "\"") { cur = cur "\""; i++ } else inquotes = 0 }
                else cur = cur c
            } else {
                if (c == "\"") inquotes = 1
                else if (c == ",") { n++; field[n] = cur; cur = "" }
                else cur = cur c
            }
        }
        n++; field[n] = cur
        return n
    }
    function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    function isip(h) { return h ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ }
    BEGIN {
        # the blacklist drop values per field (the site keep-regex is not
        # needed: the site column is not read here)
        while ((getline l < BL) > 0) {
            sub(/\r$/, "", l)
            if (l ~ /^#/ || l == "") continue
            n = split(l, a, "\t")
            if (n >= 3 && a[2] == "drop") BLK[a[1] SUBSEP a[3]] = 1
        }
        close(BL)
    }
    {
        sub(/\r$/, "")
        if ($0 == "" || $0 ~ /^"?Status"?,/) next     # the header row
        nf9 = split_csv($0)
        if (nf9 < 26) next
        acct = field[2]; sub(/@.*$/, "", acct)
        login = field[3]; prof = field[12]
        dir = field[8]; proto = tolower(field[20]); host = tolower(field[26])
        cid = field[34]
        realacct = (acct != "" && !(("account" SUBSEP acct) in BLK))
        # ---- the PARTNER side (real accounts only) ----------------------
        if (realacct) {
            if (!((("login" SUBSEP login) in BLK) || login ~ /nobody$/ || login == "UNKNOWN" || login == "")) {
                if (!AL[acct SUBSEP login]++) { ALN[acct]++; ALL[acct, ALN[acct]] = login }
            }
            if (!(acct in ASEEN)) { ASEEN[acct] = 1; AN9[++na] = acct }
            if (host != "" && !isip(host) && host != "localhost" && !(("host" SUBSEP host) in BLK)) {
                if (!AH[acct SUBSEP host]++) { AHN[acct]++; AHL[acct, AHN[acct]] = host }
            }
            if (dir == "Inbound" && isip(host) && !(("host" SUBSEP host) in BLK)) {
                if (!AW[acct SUBSEP host]++) { AWN[acct]++; AWL[acct, AWN[acct]] = host }
            }
        }
        # ---- the CoreId group maps: the delivery leg often logs under the
        # SERVICE account (SECURETRANSPORT) while its profile names the flow
        # — the account comes from ANOTHER leg of the same CoreId, exactly
        # parse.sh group propagation in miniature
        if (cid != "") {
            if (realacct && !(cid in CIDA)) CIDA[cid] = acct
            if (prof != "" && prof != "UNKNOWN" && !(cid in CIDP)) CIDP[cid] = prof
        }
        # ---- the SUBSCRIPTION side (one per profile) --------------------
        if (prof == "" || prof == "UNKNOWN") next
        if (!(prof in PSEEN)) { PSEEN[prof] = 1; PN9[++np] = prof }
        if (realacct && !PA[prof SUBSEP acct]++) { PAN[prof]++; PAL[prof, PAN[prof]] = acct }
        # movement votes: partner protocols move the file the way the
        # connection points, pesit the opposite (the parse FLOWDIR rule)
        if (proto ~ /^(ssh|sftp|scp|ftp|ftps)$/) {
            if (dir == "Inbound") MIN9[prof]++; else if (dir == "Outbound") MOUT[prof]++
        } else if (proto == "pesit") {
            if (dir == "Inbound") { MOUT[prof]++; PIN[prof]++ }
            else if (dir == "Outbound") { MIN9[prof]++; POUT[prof]++ }
        }
    }
    END {
        # the CoreId join: a profile whose own rows never carried a real
        # account takes the accounts of its CoreId groups
        for (cid in CIDP) {
            if (!(cid in CIDA)) continue
            prof = CIDP[cid]; acct = CIDA[cid]
            if (!PA[prof SUBSEP acct]++) { PAN[prof]++; PAL[prof, PAN[prof]] = acct }
        }
        # -------- partners.json: one entry per account, one comm profile
        # per login (all sharing the endpoint set), AllowIP1 = inbound IPs
        printf "[" > PARTJ
        for (i = 1; i <= na; i++) {
            a9 = AN9[i]
            printf "%s\n  {\"name\": \"%s\",\n   \"communicationProfiles\": [", (i > 1 ? "," : ""), jesc(a9) > PARTJ
            hl = ""
            for (j = 1; j <= AHN[a9] + 0; j++) hl = hl (j > 1 ? ", " : "") "\"" jesc(AHL[a9, j]) "\""
            nl9 = ALN[a9] + 0; if (nl9 == 0) { nl9 = 1; ALL[a9, 1] = "" }
            for (j = 1; j <= nl9; j++)
                # .name is REQUIRED string-typed by the Accounts analyses
                # page (it splits the profile name on "_")
                printf "%s\n     {\"businessId\": \"cp_%s_%d\", \"name\": \"SYNTH_%s_%d\", \"login\": \"%s\", \"hosts\": [%s]}", \
                       (j > 1 ? "," : ""), jesc(a9), j, jesc(a9), j, jesc(ALL[a9, j]), hl > PARTJ
            printf "\n   ]" > PARTJ
            if (AWN[a9] + 0 > 0) {
                wl = ""
                for (j = 1; j <= AWN[a9]; j++) wl = wl (j > 1 ? ";" : "") AWL[a9, j]
                printf ",\n   \"customAttributes\": {\"AllowIP1\": \"%s\"}", jesc(wl) > PARTJ
            }
            printf "}" > PARTJ
        }
        printf "\n]\n" > PARTJ
        close(PARTJ)
        # -------- subscriptions.json: one entry per profile
        printf "[" > SUBSJ
        for (i = 1; i <= np; i++) {
            p = PN9[i]
            # the pesit marker patternName (see the header); plain flows get
            # a SYNTH placeholder
            pat = (PIN[p] + 0 > POUT[p] + 0) ? "SYNTH_PESIT_PUSH_ST_APP" : \
                  ((POUT[p] + 0 > 0) ? "SYNTH_ST_CFT_PESIT_PUSH_APP" : "SYNTH")
            printf "%s\n  {\"name\": \"%s\",\n   \"patternName\": \"%s\",\n   \"parameters\": {\"customAttribute_FlowIdentifier\": \"%s\"", \
                   (i > 1 ? "," : ""), jesc(p), pat, jesc(p) > SUBSJ
            if (MOUT[p] + 0 > MIN9[p] + 0)
                printf ", \"source_folder_monitoring_scan_dir\": \"/synthetic/%s\"", jesc(p) > SUBSJ
            else if (MIN9[p] + 0 > MOUT[p] + 0)
                printf ", \"target_working_dir\": \"/synthetic/%s\"", jesc(p) > SUBSJ
            printf "},\n   \"participants\": [" > SUBSJ
            for (j = 1; j <= PAN[p] + 0; j++)
                printf "%s{\"name\": \"%s\", \"comProfileId\": \"cp_%s_1\"}", \
                       (j > 1 ? ", " : ""), jesc(PAL[p, j]), jesc(PAL[p, j]) > SUBSJ
            printf "]}" > SUBSJ
        }
        printf "\n]\n" > SUBSJ
        close(SUBSJ)
        printf "flow-manager-synth: %d subscription(s) (from profiles), %d partner(s).\n", np, na > "/dev/stderr"
    }
' "${files[@]}"

# validate + publish atomically; jq failing leaves the old files untouched
jq -e 'type == "array"' "$OUTDIR/subscriptions.json.tmp" > /dev/null
jq -e 'type == "array"' "$OUTDIR/partners.json.tmp" > /dev/null
mv "$OUTDIR/subscriptions.json.tmp" "$OUTDIR/subscriptions.json"
mv "$OUTDIR/partners.json.tmp" "$OUTDIR/partners.json"
echo "Wrote $OUTDIR/subscriptions.json + partners.json." >&2
