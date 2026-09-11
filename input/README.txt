input/ — the SAMPLE ESTATE: fully synthetic Axway SecureTransport exports for
the develop repo, written by bin/sample/generate.sh (deterministic; re-run it
to regenerate, see bin/sample/). NOTHING under input/ is real: fake orgs
(GLOBEX, INITECH, WONKA, ...), RFC 5737 TEST-NET addresses, RFC 2606
.example hosts. The runtime repos hold the real operational exports and are
NEVER touched by the generator (the input/.sample-estate marker gates it).

One repo = ONE environment (2026-09-11): the trees are flat — no environment
level anywhere. Layout:
  environment.txt  this checkout's label (one line; "Sample" here, Acceptance /
                 Production in the runtime repos) — hand-maintained, never
                 synced, NOT written by the generator (see bin/envlabel.sh)
  flow-manager/  partners.json + subscriptions.json (the config exports)
  transfer/      transferLog_MM-DD.csv (one per day, newest-first rows)
  server/        logEntry_MM-DD.csv    (one per day, newest-first rows)
  renames/       machine-maintained rename maps (bin/renames.sh)
  ip/            the address<->endpoint map (bin/ip.sh)
  blacklist.txt  platform-internal values blanked at parse time (see CLAUDE.md)
  skip.txt       the SKIP LIST — a matched rule drops the whole record
  rename.txt     DISPLAY renames, applied to the rendered pages
  logical.txt    fixed FlowID -> Logical pins for the Logical derivation
  logical_{domains,apps,partners}.txt  PART replacements for the PDA derivation
                 (logical_partners.txt also carries the partner ALIASES —
                 a variant token rewritten to its canonical organisation)
  BL.txt         BL numbers per subscription ("<subscription> <BL>[,<BL>...]"),
                 a second source of BL entities beside the subscriptions.json tags
  logons_old.txt the FE logins' last logon on the OLD gateway ("<login> <stamp>"
                 per line) — the Partners - Incoming page's Gateway column
  coreid-url.txt the SecureTransport File Tracking URL every CoreId on the site
                 links to — one line, @COREID@ where the id goes (2026-09-07)
  .sample/       the generator's estate spec + the figures verify.sh asserts
The estate is the UNION of the two former sample environments: every
acceptance scenario plus the production-only shapes (multi-FE and multi-host
accounts, the extended transfer-site fold, the non-UC-named hybrid flows).
