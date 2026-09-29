#!/usr/bin/env bash
#
# st-reports-update.sh — RUNTIME-ONLY build step (2026-08-31, user request):
# ingest ONE delivered update archive BEFORE anything parses:
#
#   bin/build/st-reports-update.sh ARCHIVE    bin/build/exchange-in.sh calls
#       it per acc*/prd* archive of the INBOX (the git repo it pulls); the
#       exit status says consumed (0) or left in place (1). The former
#       ~/cloud drop folder is gone (2026-09-12, user request: the inbox is
#       the only intake).
#
# An archive is packed elsewhere with the SAME password st-reports-archive.sh
# generates (input/secrets/st-reports.pass) and carries fresh exports:
#
#   1. a name claiming the OTHER environment (prd-… in the Acceptance
#      checkout) is refused untouched — never routed onto this checkout;
#   2. unpack it (password from input/secrets/st-reports.pass);
#   3. an archive carrying the OTHER environment's tree (a production/ or
#      input/production/ directory in the Acceptance checkout) is refused
#      BEFORE anything is copied — a half-copied checkout is worse than none;
#   4. copy the exports onto input/ (the config / policy files overwrite
#      their older selves; a LOG export never replaces a different one — an
#      identical re-delivery is skipped, a different export with the same
#      first-record day is kept under a numbered name, 2026-09-29). Two layouts:
#        a. the REPO TREE — flow-manager/ rooted at the archive root or under
#           input/; the OLD per-environment layout (input/… or
#           <env>/…) is accepted when <env> is THIS one;
#        b. every OTHER file, at any depth, routed by name and — the two log
#           exports — RENAMED on the way in (2026-09-12, user request):
#              logEntry*.csv      -> input/server/logEntry_yyyy-mm-dd.csv
#              fileTransfer*.csv  -> input/transfer/fileTransfer_yyyy-mm-dd.csv
#              transferLog*.csv   -> input/transfer/fileTransfer_yyyy-mm-dd.csv (the old name)
#              *.json             -> input/flow-manager/subscriptions.json or
#                                    partners.json — told apart by CONTENT, not
#                                    by name (2026-09-12, user request): the
#                                    first object's meta.href says
#                                    /api/v2/subscriptions/ or /api/v2/partners/,
#                                    else the keys ("participants" /
#                                    "patternName" vs "communicationProfiles");
#                                    an unrecognised JSON keeps its own name
#              *.txt              -> input/          (the policy files —
#                                    environment.txt and README.txt never)
#           yyyy-mm-dd (zero-padded month and day) is read from the file itself:
#           the date of its first data record — the exports are newest-first,
#           so that is the day the export was cut. A file whose date cannot
#           be read keeps its own name; two files of one archive mapping to
#           the same name get a numbered suffix rather than overwriting each
#           other. Any other file is listed and ignored.
#   5. delete the archive (every part of a multi-volume set) — only after a
#      fully successful copy.
#
# Nothing else in the archive is looked at: ip/, renames/, secrets/ and
# anything else outside the mapping is listed and ignored. No archive is the
# quiet no-op. A FAILURE (missing password file, wrong password, corrupt
# archive, nothing ingestible inside, the other environment) LEAVES the
# archive in place: fix or remove the file and rebuild.
#
# Runs before the have-config check in bin/build.sh, so an update delivering
# a checkout's FIRST flow-manager exports enables the build in the same run.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
source bin/envlabel.sh   # ENV_LABEL / ENV_KEY / ENV_INBOX / env_of_name / env_inbox_find

# the build report's Inbox block (build/inbox.tsv, reset by bin/build.sh):
# status ⇥ archive ⇥ detail — every outcome leaves one line
inbox_note() { [ -d build ] && printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> build/inbox.tsv; return 0; }
PASSF="input/secrets/st-reports.pass"
# csv_ymd FILE -> "yyyy-mm-dd" from the first data record's MM/DD/YYYY date
# (the header is line 1; up to five lines are read), "" when none is found
csv_ymd() {
    awk 'NR > 1 && match($0, /[0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][0-9][0-9]/) { s = substr($0, RSTART, RLENGTH); print substr(s, 7, 4) "-" substr(s, 1, 2) "-" substr(s, 4, 2); exit }
         NR > 6 { exit }' "$1"
}
# json_kind FILE -> "subscriptions" | "partners" | "" from the first 64 KB of a
# FlowManager export: the first object's meta.href names the collection
# (/api/v2/subscriptions/ or /api/v2/partners/); without it the keys decide
# ("participants" / "patternName" belong to a subscription,
# "communicationProfiles" to a partner) — 2026-09-12, user request
json_kind() {
    head -c 65536 "$1" | awk '
        { h = h $0 }
        END {
            if (index(h, "/api/v2/subscriptions/")) { print "subscriptions"; exit }
            if (index(h, "/api/v2/partners/"))      { print "partners"; exit }
            if (index(h, "\"participants\"") || index(h, "\"patternName\"")) { print "subscriptions"; exit }
            if (index(h, "\"communicationProfiles\"")) { print "partners"; exit }
            print "" }'
}
# fm_valid KIND FILE -> 0 when FILE is ONE JSON document holding a FlowManager
# collection (KIND subscriptions | partners) whose fields bin/flow-manager.sh
# and its jq siblings put through string functions carry the types they
# expect — null or absent always passes, an empty collection too. A numeric
# .name used to pass the collection-of-objects test, replace the working
# config and then kill flow-manager.sh (audit 2026-09-29 F04).
fm_valid() {
    jq -e -s --arg k "$1" '
        def str:  . == null or type == "string";
        def strs: . == null or (type == "array" and all(.[]; str));
        def obj:  . == null or type == "object";
        def objs: . == null or (type == "array" and all(.[]; type == "object"));
        length == 1 and (.[0] | (type == "array" or type == "object") and all(.[];
            type == "object" and (.name | str) and
            if $k == "partners" then
                (.communicationProfiles | objs)
                and all(.communicationProfiles[]?; (.login | str) and (.hosts | strs) and (.businessId | str))
                and (.customAttributes | obj)
                and all(.customAttributes // {} | to_entries[] | select(.key | test("^AllowIP[0-9]+$")); .value | str)
            else
                (.parameters | obj) and (.status | obj) and (.tags | strs) and (.participants | objs)
            end))' "$2" >/dev/null 2>&1
}

# ingest_one ARCHIVE -> 0 consumed, 1 left in place (with the reason on stderr
# and in the Inbox block)
ingest_one() {
    local UPD=$1 UPDD tmp total=0 claimed other d root sub n src rel base i f dst
    UPDD="${UPD/#$HOME/~}"   # display form
    local -a ignored=() plan_src=() plan_dst=()

    # ---- 1. the name must not claim the other environment -------------------
    claimed=$(env_of_name "$(basename "$UPD")")
    if [ -n "$claimed" ] && [ "$claimed" != "$ENV_KEY" ]; then
        echo "inbox: $UPDD is named for the $claimed environment — this checkout is ${ENV_LABEL:-unlabelled}; the file stays, nothing was copied." >&2
        inbox_note failed "$(basename "$UPD")" "names the $claimed environment (this checkout is ${ENV_LABEL:-unlabelled})"
        return 1
    fi

    # 7zz (the official 7-Zip) first, p7zip's 7z as the fallback — the archive
    # step's own detection (2026-09-29 audit: a machine with only 7zz could
    # pack but never ingest)
    if command -v 7zz >/dev/null 2>&1; then Z7=7zz
    elif command -v 7z >/dev/null 2>&1; then Z7=7z
    else echo "inbox: neither 7zz nor 7z found (brew install sevenzip)." >&2; inbox_note failed "$(basename "$UPD")" "neither 7zz nor 7z found (brew install sevenzip)"; return 1; fi
    [ -s "$PASSF" ] || { echo "inbox: $PASSF missing — cannot unpack $UPDD (the password is generated by the archive step of a completed build; pack updates with that value)." >&2; inbox_note failed "$(basename "$UPD")" "no $PASSF"; return 1; }

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/stupd.XXXXXX")
    # the unpacked (decrypted) exports never outlive this script, whatever
    # fails between the unpack and the copy (2026-09-29 audit)
    trap 'rm -rf "${tmp:-}"' EXIT
    # ---- 2. unpack -----------------------------------------------------------
    if ! "$Z7" x -aoa -p"$(cat "$PASSF")" -o"$tmp" "$UPD" >/dev/null 2>&1; then
        rm -rf "$tmp"
        echo "inbox: could not unpack $UPDD (wrong password or corrupt archive) — the file stays; fix or remove it." >&2
        inbox_note failed "$(basename "$UPD")" "could not unpack (wrong password or corrupt archive)"
        return 1
    fi

    # ---- 3. the other environment's tree is refused BEFORE any copy ----------
    for d in "$tmp"/* "$tmp"/input/*; do
        [ -d "$d" ] || continue
        other=$(env_of_name "$(basename "$d")")
        case "$(basename "$d" | tr '[:upper:]' '[:lower:]')" in
            acceptance|production) ;;
            *) continue ;;
        esac
        if [ "$other" != "$ENV_KEY" ]; then
            rm -rf "$tmp"
            echo "inbox: $UPDD carries the $other environment's tree (${d#$tmp/}) — this checkout is ${ENV_LABEL:-unlabelled}; the file stays, nothing was copied from it." >&2
            inbox_note failed "$(basename "$UPD")" "carries the $other tree (${d#$tmp/})"
            return 1
        fi
    done

    # ---- 4. every file, at any depth, routed by name — the JSON exports by
    # CONTENT (json_kind) and the log exports RENAMED (csv_ymd). The former
    # tree copy of flow-manager/ is gone (2026-09-12): a tree's files go
    # through the same plan, so a mis-named subscriptions.json inside it is
    # recognised too; the old per-environment layout (input/…, <env>/…)
    # only matters for the tree refusal above.
    # ---- 4b. every file, routed by name — the log exports RENAMED -------------
    # (2026-09-12, user request): logEntry_yyyy-mm-dd.csv /
    # fileTransfer_yyyy-mm-dd.csv, the date from the file's first data record
    # (csv_ymd); a file whose date cannot be read keeps its own name; a second
    # file of this archive mapping to a name already planned gets a numbered
    # suffix (never overwrites it)
    local ymd kind j dup
    while IFS= read -r -d '' f; do
        rel="${f#$tmp/}"
        rel="${rel#input/}"
        [ -n "$ENV_KEY" ] && rel="${rel#$ENV_KEY/}"
        base=$(basename "$f")
        sub=""; dst=$base
        # a checkout's own files are never delivered — in ANY case: APFS is
        # case-insensitive, so an Environment.txt IS input/environment.txt and
        # the *.txt branch turned an Acceptance checkout into Production
        # (audit 2026-09-29 F01)
        case "$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')" in
            environment.txt|readme.txt) ignored+=("$rel"); continue ;;
        esac
        case "$base" in
            logEntry*.csv)                      sub=server;   ymd=$(csv_ymd "$f"); [ -n "$ymd" ] && dst="logEntry_$ymd.csv" ;;
            transferLog*.csv|fileTransfer*.csv) sub=transfer; ymd=$(csv_ymd "$f"); [ -n "$ymd" ] && dst="fileTransfer_$ymd.csv" ;;
            *.json)            sub=flow-manager; kind=$(json_kind "$f"); [ -n "$kind" ] && dst="$kind.json" ;;   # by content, not by name
            *.txt)             sub=. ;;             # the policy files live at the input root
        esac
        if [ -z "$sub" ]; then ignored+=("$rel"); continue; fi
        if [ "$sub" = . ]; then dst="input/$dst"; else dst="input/$sub/$dst"; fi
        dup=1; j=0
        while [ $j -lt ${#plan_dst[@]} ]; do
            if [ "${plan_dst[$j]}" = "$dst" ]; then dup=$((dup + 1)); dst="${dst%.*}_$dup.${dst##*.}"; j=0; continue; fi
            j=$((j + 1))
        done
        plan_src+=("$f"); plan_dst+=("$dst")
    done < <(find "$tmp" -type f ! -name '.DS_Store' -print0)

    [ ${#ignored[@]} -eq 0 ] || echo "inbox: ignored (not an export): ${ignored[*]}" >&2

    # ---- 4c. VALIDATE the whole plan BEFORE any copy (2026-09-28 audit F03):
    # a truncated JSON used to replace the working config, the archive was
    # consumed as a success and the build then died on it. Now ONE bad file
    # refuses the WHOLE archive — nothing copied, the archive stays. JSON:
    # parseable, and the two FlowManager exports ONE collection of objects
    # (what bin/flow-manager.sh iterates) with its string fields typed
    # (fm_valid); CSV: not empty.
    local -a bad=()
    i=0
    while [ $i -lt ${#plan_src[@]} ]; do
        f=${plan_src[$i]}
        case "${plan_dst[$i]}" in
            */subscriptions.json|*/partners.json)
                kind=$(basename "${plan_dst[$i]}" .json)
                fm_valid "$kind" "$f" || bad+=("${f#$tmp/} (not a valid FlowManager $kind export)") ;;
            *.json) jq empty "$f" >/dev/null 2>&1 || bad+=("${f#$tmp/} (not valid JSON)") ;;
            *.csv)  [ -s "$f" ] || bad+=("${f#$tmp/} (empty)") ;;
        esac
        i=$((i + 1))
    done
    if [ ${#bad[@]} -gt 0 ]; then
        rm -rf "$tmp"
        echo "inbox: $UPDD REFUSED — ${bad[*]}; nothing was copied, the file stays: fix or remove it." >&2
        inbox_note failed "$(basename "$UPD")" "refused: ${bad[*]}"
        return 1
    fi

    i=0
    local k stem skipped=0
    while [ $i -lt ${#plan_src[@]} ]; do
        src=${plan_src[$i]}; dst=${plan_dst[$i]}
        mkdir -p "$(dirname "$dst")"
        case $dst in
            input/server/*.csv|input/transfer/*.csv)
                # A LOG export never replaces a DIFFERENT one (2026-09-29): the
                # name is the day of the first record, so two exports starting
                # on the same day collided and the one applied LATER silently
                # replaced the other — that export's whole window vanished from
                # input/. The same content is a re-delivery (skipped); different
                # content is kept beside it under a numbered name (the parse
                # drops the records two overlapping exports share).
                k=1; stem=${dst%.csv}
                while [ -f "$dst" ] && ! cmp -s "$src" "$dst"; do k=$((k + 1)); dst="${stem}_$k.csv"; done
                plan_dst[$i]=$dst
                if [ -f "$dst" ]; then
                    echo "inbox: ${src#$tmp/} = $dst (already there, identical — skipped)" >&2
                    skipped=$((skipped + 1)); i=$((i + 1)); continue
                fi ;;
        esac
        cp -p "$src" "$dst"
        total=$((total + 1))
        echo "inbox: ${src#$tmp/} -> $dst" >&2
        i=$((i + 1))
    done
    rm -rf "$tmp"

    if [ "$total" -eq 0 ] && [ "$skipped" -eq 0 ]; then
        echo "inbox: $UPDD holds NO export at all — the file stays; check its layout (expected input/flow-manager/... or logEntry*.csv / fileTransfer*.csv / partners.json / subscriptions.json / the policy .txt files, at any depth)." >&2
        inbox_note failed "$(basename "$UPD")" "holds no export"
        return 1
    fi
    # ---- 5. remove the archive (every part of a multi-volume set) --------------
    case "$UPD" in
        *.7z.001) rm -f "${UPD%.001}".[0-9][0-9][0-9]; echo "inbox: ingested $total file(s); removed every part of $UPDD." >&2 ;;
        *)        rm -f "$UPD"; echo "inbox: ingested $total file(s); removed $UPDD." >&2 ;;
    esac
    inbox_note consumed "$(basename "$UPD")" "$total file(s): $(printf '%s ' ${plan_dst[@]+"${plan_dst[@]}"} | sed 's/ $//')"
    return 0
}

# one archive, named by the caller (exchange-in.sh): the exit status is the
# verdict. (The ~/cloud drop loop that ran without an argument is gone —
# 2026-09-12, user request: the inbox is the only intake.)
[ $# -ge 1 ] || { echo "usage: bin/build/st-reports-update.sh ARCHIVE.7z   (called per inbox archive by bin/build/exchange-in.sh)" >&2; exit 2; }
ingest_one "$1"
exit $?
