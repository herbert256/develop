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
# ONE SSH SESSION LOGS BOTH SHAPES — the "had initiated a connection" line AND
# its authentication — so the two sources are two views of the same
# connections, never to be added (2026-09-29 audit: 198.51.100.10 read 1548 =
# 774 + 774). Per address: max(inbound lines, authentications) + the
# disallowed screenings (refused before any session, so no inbound line);
# with no authentication and no refusal, the allowed screenings stand in for
# the authentications. The verdicts only test the count > 0.
FILENAME ~ /_inbound-addr\.tsv$/ { if ($1 != "" && $2 + 0 > 0) { I[$1] += $2; K[$1] = 1 }; next }
FILENAME ~ /_logons-hosts\.tsv$/ {
    if ($1 == "") next
    au = $4 + 0; if (au + $7 == 0) au = $6 + 0
    A[$1] += au; D[$1] += $7 + 0; K[$1] = 1
    next
}
END { for (a in K) { n = ((I[a] + 0 > A[a] + 0) ? I[a] + 0 : A[a] + 0) + D[a]
                     if (n > 0) printf "%s\t%d\n", a, n } }
