#!/usr/bin/env bash
#
# bin/envlabel.sh — the ONE reader of input/environment.txt (sourced, not run).
#
# One repo = one environment (2026-09-11; the acceptance/production dimension
# and bin/env.sh are gone). The file holds the checkout's DISPLAY LABEL on one
# line — "Acceptance" / "Production" in the two runtime repos, "Sample" in
# develop. Hand-maintained, committed in each repo, NEVER synced by
# bin/runtime.sh (like coreid-url.txt: each checkout keeps its own).
#
#   ENV_LABEL   the label as written ("" when the file is missing or empty)
#   ENV_KEY     the label lowercased (archive names, keys)
#   ENV_INBOX   the inbox archive PREFIXES this environment consumes, lowercase,
#               space-separated: acceptance -> "acc", production -> "prd prod";
#               any other label -> "" (no inbox — archives stay where they are)
#
# The label shows as a static top-bar label (report.js buildTopbar reads it
# from topbar-data.js) and in the home title; the prefixes drive the two
# runtime inboxes (bin/build/exchange-in.sh, bin/build/st-reports-update.sh)
# and the key names the outbox archives (bin/build/st-reports-archive.sh).
#
_el_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_LABEL=""
if [ -f "$_el_root/input/environment.txt" ]; then
    ENV_LABEL=$(awk '/^[ \t]*#/ || /^[ \t]*$/ { next }
                     { sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, ""); print; exit }' \
                "$_el_root/input/environment.txt")
fi
ENV_KEY=$(printf '%s' "$ENV_LABEL" | tr '[:upper:]' '[:lower:]')
case $ENV_KEY in
    acceptance) ENV_INBOX="acc" ;;
    production) ENV_INBOX="prd prod" ;;
    *)          ENV_INBOX="" ;;
esac
export ENV_LABEL ENV_KEY ENV_INBOX

# env_of_name NAME -> acceptance | production | "" — the environment a file or
# directory name CLAIMS by its leading token (acc… / prd… / prod…, any case).
env_of_name() {
    local n; n=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case $n in
        acc*)       printf 'acceptance' ;;
        prd*|prod*) printf 'production' ;;
    esac
    return 0
}

# env_inbox_find DIR [PRUNE] — NUL-separated, sorted: every *.7z (and the FIRST
# part *.7z.001 of a multi-volume set) under DIR whose name starts with one of
# ENV_INBOX, any case. With PRUNE (the exchange checkout's .git) the whole tree
# is walked; without it only DIR itself is read (~/cloud holds unrelated files
# and folders). Nothing when ENV_INBOX is empty.
env_inbox_find() {
    local d=$1 p; local -a t=()
    [ -n "$ENV_INBOX" ] || return 0
    for p in $ENV_INBOX; do
        [ ${#t[@]} -eq 0 ] || t+=(-o)
        t+=(-iname "$p*.7z" -o -iname "$p*.7z.001")
    done
    if [ -n "${2:-}" ]; then
        find "$d" -path "$2" -prune -o -type f \( "${t[@]}" \) -print0 | sort -z
    else
        find "$d" -maxdepth 1 -type f \( "${t[@]}" \) -print0 | sort -z
    fi
}
