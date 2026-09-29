# server-inbound-addr.awk — the SERVER-SIDE INBOUND CONTACT per client
# ADDRESS (2026-09-29): what the Whitelist audit (publish-insights.sh) and the
# Cleanup backlog (cleanup-backlog.sh) call "server connections" of a
# whitelisted IP. Two inputs, told apart by name (either may be /dev/null):
#   _inbound-addr.tsv   addr ⇥ inbound connection lines (inbound-connections.sh:
#                       the "had initiated a connection" lines that name a
#                       login — a partner connecting IN)
#   _logons-hosts.tsv   bin/logons.sh's per-address logon file: field 4 = the
#                       authentications from that address, 6 = allowed,
#                       7 = disallowed screenings (fields 10+ are OUR outbound
#                       side and never count here)
# Output: addr ⇥ count, one line per address with any inbound contact
# (unsorted — the callers sort).
FILENAME ~ /_inbound-addr\.tsv$/ { if ($1 != "" && $2 + 0 > 0) C[$1] += $2; next }
FILENAME ~ /_logons-hosts\.tsv$/ {
    if ($1 == "") next
    n = $4 + $7; if (n == 0) n = $6 + 0
    if (n > 0) C[$1] += n
    next
}
END { for (a in C) printf "%s\t%d\n", a, C[a] }
