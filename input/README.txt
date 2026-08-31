input/ — the SAMPLE ESTATE: fully synthetic Axway SecureTransport exports for
the develop repo, written by bin/sample/generate.sh (deterministic; re-run it
to regenerate, see bin/sample/). NOTHING under input/ is real: fake orgs
(GLOBEX, INITECH, WONKA, ...), RFC 5737 TEST-NET addresses, RFC 2606
.example hosts. The runtime repo holds the real operational exports and is
NEVER touched by the generator (the input/.sample-estate marker gates it).

Layout (per environment, acceptance/ + production/):
  flow-manager/  partners.json + subscriptions.json (the config exports)
  transfer/      transferLog_MM-DD.csv (one per day, newest-first rows)
  server/        logEntry_MM-DD.csv    (one per day, newest-first rows)
  renames/       machine-maintained rename maps (bin/renames.sh)
  ip/            the address<->endpoint map (bin/ip.sh)
Root: blacklist.txt + skip.txt (platform policy, see CLAUDE.md) and
partner-aliases.tsv (partner tokens naming one organisation).

BL.txt              BL numbers per subscription ("<subscription> <BL number>", several lines per
                    subscription allowed) — a second source of BL entities beside the
                    subscriptions.json tags; bin/flow-manager.sh unions the two. Shared by both
                    environments; this develop copy is the SAMPLE template (bin/sample/templates/),
                    the real one lives in the runtime checkout's input/.
