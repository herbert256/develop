#!/usr/bin/env bash
# ip.sh — the address <-> endpoint map. SOURCED, never run.
#
# ONE file per env:
#
#     input/<env>/ip/ip-hosts.tsv     <ip> <TAB> <host>
#
# Address-sorted, host as tiebreaker. Several rows may share a host (an endpoint
# with several A records) and several may share an address (two endpoints behind
# one address). Written by ip_put and ONLY by ip_put.
#
# A transposed hosts-ip.tsv briefly existed alongside it so consumers keyed on
# the NAME could read a file already in their direction. It was dropped: it held
# no information this file lacks, and of its five consumers four already ran an
# awk over it and only had to swap which column they key on — the whole cost of
# removing it was one extra awk fork per env per build (~1 ms on 99 rows).
#
# THERE IS NO REVERSE DNS ANYWHERE IN THE PIPELINE (dropped 2026-07). Measured
# before removing it, on acceptance: 4,141 of 4,221 cached entries existed only
# because an address is whitelisted, 2,740 of those had no PTR at all, and of the
# names that did exist most encoded the address itself (134-146-0-12.shell.com)
# or named the partner's ISP rather than the endpoint. The decisive figure is the
# parse cache: of the 46 host names in _transfers.tsv col 16, 44 were configured
# endpoints that FORWARD DNS names correctly, and only 2 came from a PTR — on 5
# rows out of 199,371. So the whole reverse path, its 30-day TTL, its age sidecar
# and its negative-cache convention are gone; what names an endpoint is the
# configuration, not its PTR.
#
# WHY input/ AND NOT data/. These are DNS answers: they cannot be regenerated
# from anything in the repo, and an address a partner has since stopped using is
# still needed to name the rows already in the log. data/ is declared safe to
# `rm -rf` precisely because everything under it regenerates locally, so this
# cannot live there. It is PER ENV — the two estates share no partners and no
# endpoints, and a host name here is the one CONFIGURED FOR THAT ENV.
#
# WHO WRITES:
#   bin/flow-manager.sh    forward-resolves every non-IP host in base/_hosts.tsv,
#                          one row per A record. Only when it actually rebuilds.
#   bin/transfer/parse.sh  rule (b): an OUT-side address absent from the map is
#                          added under its account's unique configured host.
# Both go through ip_put, and only one of them runs at a time per env
# (flow-manager.sh precedes the parses), so no locking is needed.
#
# Provides:
#   IP_DIR / IP_HOSTS_FILE   the paths
#   ip_put [KEEPFILE]   read "ip<TAB>host" pairs on stdin and publish the map
#
# An absent file reads as an empty map everywhere, so an EMPTY input/<env>/ip/ is
# a valid starting state: the next flow-manager.sh rebuild fills it.

IP_DIR="${IP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/input/${AXWAY_ENV:-acceptance}/ip}"
IP_HOSTS_FILE="$IP_DIR/ip-hosts.tsv"

# Replace OUT with TMP only when the content differs, so a re-resolution that
# returns the same A records keeps its mtime. The map is a freshness dep
# (unknown-entities.sh, entity-search.sh); rewriting it unchanged would drag
# every consumer along — the same rule cov_put and expire-files.sh follow.
_ip_commit() {
    local tmp=$1 out=$2
    if [ -f "$out" ] && cmp -s "$tmp" "$out"; then rm -f "$tmp"; else mv -f "$tmp" "$out"; fi
}

# ip_put [KEEPFILE] — fold the "ip<TAB>host" pairs on stdin into the map.
#
# UNION with what is already there, never a replacement. A caller only knows its
# own pairs: flow-manager.sh knows what DNS answers today, parse.sh knows which
# address a partner actually connected from, and those legitimately differ — an
# endpoint that has since moved to a new address must keep naming the rows
# already in the log. Replacing instead of unioning would make the two writers
# delete each other's rows on alternate runs.
#
# KEEPFILE (optional, col 1 = host) prunes rows whose host is no longer
# configured, which is what keeps the union bounded. flow-manager.sh passes
# base/_hosts.tsv; parse.sh passes nothing, since every host it writes came from
# that same list.
ip_put() {
    local keep=${1:-} src tmp_ih
    mkdir -p "$IP_DIR"
    src=$(mktemp "${TMPDIR:-/tmp}/ipput.XXXXXX")
    # stdin + the existing map, normalised: real IPv4 only, host lowercased
    # (endpoints are canonically lowercase site-wide) and never equal to its own
    # address — a raw-IP endpoint maps to itself, which names nothing.
    # `if`, not `&&`: on the first run the map does not exist yet, and a group
    # ending in a failed test makes the whole pipeline fail under `set -o pipefail`.
    { cat; if [ -f "$IP_HOSTS_FILE" ]; then cat "$IP_HOSTS_FILE"; fi; } \
      | awk -F'\t' '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $2 != "" {
            h = tolower($2); if (h != $1) print $1 "\t" h }' > "$src"
    if [ -n "$keep" ] && [ -f "$keep" ]; then
        awk -F'\t' -v K="$keep" '
            BEGIN { while ((getline l < K) > 0) { split(l, a, "\t"); if (a[1] != "") k[tolower(a[1])] = 1 } }
            ($2 in k)' "$src" > "$src.k" && mv "$src.k" "$src"
    fi
    tmp_ih="$IP_HOSTS_FILE.$$.tmp"
    # Address order with the host as tiebreaker. The sort key is ZERO-PADDED into
    # the line rather than expressed as `sort -t. -kN,Nn`: a numeric key would
    # compare two different hosts of one address as EQUAL, and `sort -u` would
    # then silently drop one of them.
    awk -F'\t' '{ split($1, o, "."); printf "%03d%03d%03d%03d\t%s\t%s\t%s\n", o[1], o[2], o[3], o[4], $2, $1, $2 }' "$src" \
      | LC_ALL=C sort -u | cut -f3- > "$tmp_ih"
    rm -f "$src"
    _ip_commit "$tmp_ih" "$IP_HOSTS_FILE"
    return 0
}
