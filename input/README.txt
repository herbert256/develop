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
  blacklist.txt  platform-internal values blanked at parse time (see CLAUDE.md)
  skip.txt       the SKIP LIST — a matched rule drops the whole record
  rename.txt     DISPLAY renames, applied to that environment's rendered pages
  logical.txt    fixed FlowID -> Logical pins for the Logical derivation
  logical_{domains,apps,partners}.txt  PART replacements for the PDA derivation
                 (logical_partners.txt also carries the partner ALIASES —
                 a variant token rewritten to its canonical organisation)
  BL.txt         BL numbers per subscription ("<subscription> <BL>[,<BL>...]"),
                 a second source of BL entities beside the subscriptions.json tags
  logons_old.txt the FE logins' last logon on the OLD gateway ("<login> <stamp>"
                 per line) — the FE status information page's Last Gateway column
The eight policy files are PER ENVIRONMENT since 2026-08-31 (user request);
bin/build/migrate-input.sh moves a checkout's old shared copies into the env
dirs once, and folds a retired partner-aliases.tsv into logical_partners.txt.
