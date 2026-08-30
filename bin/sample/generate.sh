#!/usr/bin/env bash
#
# bin/sample/generate.sh — (re)generate the SAMPLE ESTATE: every input file of
# both environments, synthetic and DETERMINISTIC (seed AXWAY_SAMPLE_SEED,
# default 42 — re-running reproduces byte-identical files; a different seed
# gives a different but equally valid estate).
#
#   bin/sample/generate.sh            # both environments
#   bin/sample/generate.sh acc|prd    # one environment
#
# Writes, per env:  input/<env>/flow-manager/{partners,subscriptions}.json,
#   input/<env>/{transfer,server}/*.csv (one file per day, newest-first rows),
#   input/<env>/renames/{subscriptions,profiles,flowid-names}.tsv,
#   input/<env>/ip/ip-hosts.tsv, input/<env>/.sample/ (estate spec + expected
#   figures) — plus, once: input/{README,blacklist,skip}.txt and
#   input/partner-aliases.tsv (from bin/sample/templates/).
#
# REFUSES to run without input/.sample-estate (see bin/sample/lib.sh) — the
# guard that keeps a synced copy of bin/ from ever clobbering the runtime
# repo's real exports. After regenerating: bin/fresh.sh (full rebuild), then
# bin/sample/verify.sh.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
source "$ROOT/bin/fastawk.sh"
cd "$ROOT"

sample_guard

envs=()
case "${1:-}" in
    "")                  envs=(acceptance production) ;;
    acc|acceptance)      envs=(acceptance) ;;
    prd|prod|production) envs=(production) ;;
    *) echo "usage: bin/sample/generate.sh [acc|prd]" >&2; exit 2 ;;
esac

for env in "${envs[@]}"; do
    IN="input/$env"
    mkdir -p "$IN/.sample" "$IN/flow-manager" "$IN/ip" "$IN/renames" "$IN/transfer" "$IN/server"
    echo "sample: [$env] estate spec ..." >&2
    rm -f "$IN/.sample/_estate.tsv" "$IN/.sample/_calendar.tsv" "$IN/.sample/_expected.tsv"
    sawk -f "$SCRIPT_DIR/estate.awk" -v ENV="$env" -v KNOBS="$KNOBS" -v PARTNERS="$PARTNERS" \
         -v OUTDIR="$IN/.sample" -v SEED="$AXWAY_SAMPLE_SEED" </dev/null
    LC_ALL=C sort -o "$IN/.sample/_expected.tsv" "$IN/.sample/_expected.tsv"

    echo "sample: [$env] flow-manager exports ..." >&2
    sawk -F'\t' -f "$SCRIPT_DIR/gen-config.awk" \
         -v PJSON="$IN/flow-manager/partners.json" -v SJSON="$IN/flow-manager/subscriptions.json" \
         "$IN/.sample/_estate.tsv"

    echo "sample: [$env] renames + ip sidecars ..." >&2
    # flowid-names.tsv: the byte fixed-point of fm_snapshot_renames' jq
    # projection (flowId, name, profile — LC_ALL=C sorted), so the first
    # config run records ZERO phantom renames.
    awk -F'\t' '$3 != "A" { print $12 "\t" $4 "\t" $7 }' "$IN/.sample/_estate.tsv" \
        | LC_ALL=C sort > "$IN/renames/flowid-names.tsv"
    # subscriptions.tsv: the full internal server-log spelling of every flow
    # (SITE_PROFILE -> SITE), plus the planted HISTORICAL renames — the old
    # clean name (and its full spelling) as logged by the early window.
    awk -F'\t' '
        $3 == "A" { next }
        { print $4 "_" $7 "\t" $4 }
        match($30, /rename=[^,]*/) {
            old = substr($30, RSTART + 7, RLENGTH - 7)
            print old "\t" $4
            if (old "_" $7 != $4 "_" $7) print old "_" $7 "\t" $4
        }
    ' "$IN/.sample/_estate.tsv" | LC_ALL=C sort -u > "$IN/renames/subscriptions.tsv"
    # profiles.tsv: the dashed spellings some rows log -> the canonical form
    awk -F'\t' '$3 != "A" && $8 != "" { print $8 "\t" $7 }' "$IN/.sample/_estate.tsv" \
        | LC_ALL=C sort -u > "$IN/renames/profiles.tsv"
    # ip-hosts.tsv: every OUT-side endpoint's address rows, in bin/ip.sh
    # ip_put's exact order (zero-padded octet sort key), so the parse's own
    # union pass is a byte-level no-op and the file's mtime stays put.
    awk -F'\t' '$3 != "A" && $19 != "" { n = split($20, a, ";"); for (i = 1; i <= n; i++) print a[i] "\t" $19 }' \
        "$IN/.sample/_estate.tsv" \
        | awk -F'\t' '{ split($1, o, "."); printf "%03d%03d%03d%03d\t%s\t%s\t%s\n", o[1], o[2], o[3], o[4], $2, $1, $2 }' \
        | LC_ALL=C sort -u | cut -f3- > "$IN/ip/ip-hosts.tsv"

    echo "sample: [$env] event stream ..." >&2
    sawk -F'\t' -f "$SCRIPT_DIR/gen-events.awk" \
         -v CAL="$IN/.sample/_calendar.tsv" -v OUT="$IN/.sample/_events.tsv" \
         "$IN/.sample/_calendar.tsv" "$IN/.sample/_estate.tsv"

    echo "sample: [$env] transfer CSVs ..." >&2
    rm -f "$IN"/transfer/*.csv
    LC_ALL=C sort -t"$(printf '\t')" -k2,2nr "$IN/.sample/_events.tsv" \
        | sawk -F'\t' -f "$SCRIPT_DIR/gen-transfer.awk" -v DIR="$IN/transfer"

    echo "sample: [$env] server CSVs ..." >&2
    rm -f "$IN"/server/*.csv
    LC_ALL=C sort -t"$(printf '\t')" -k2,2nr "$IN/.sample/_events.tsv" \
        | sawk -F'\t' -f "$SCRIPT_DIR/gen-server.awk" -v DIR="$IN/server"

    rm -f "$IN/.sample/_events.tsv"
    printf 'sample: [%s] %s transfer rows, %s server rows.\n' "$env" \
        "$(cat "$IN"/transfer/*.csv | wc -l | tr -d ' ')" \
        "$(cat "$IN"/server/*.csv | wc -l | tr -d ' ')" >&2
done

# ---- the shared input-root policy files -------------------------------------
cp "$TPL_DIR/blacklist.txt" input/blacklist.txt
cp "$TPL_DIR/skip.txt" input/skip.txt
cp "$TPL_DIR/partner-aliases.tsv" input/partner-aliases.tsv
cp "$TPL_DIR/rename.txt" input/rename.txt
cp "$TPL_DIR/logical.txt" input/logical.txt
cp "$TPL_DIR/logical_domains.txt" input/logical_domains.txt
cp "$TPL_DIR/logical_apps.txt" input/logical_apps.txt
cp "$TPL_DIR/logical_partners.txt" input/logical_partners.txt

cat > input/README.txt <<'EOF'
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
EOF

for env in acceptance production; do
    [ -d "input/$env" ] || continue
    cat > "input/$env/README.txt" <<EOF
input/$env/ — SAMPLE data for the $env environment, generated by
bin/sample/generate.sh. Synthetic end to end: fake partners, TEST-NET
addresses, .example hosts. See input/README.txt and bin/sample/.
EOF
    cat > "input/$env/flow-manager/README.txt" <<'EOF'
The FlowManager config exports (partners.json + subscriptions.json), read by
bin/flow-manager.sh. SAMPLE data — regenerated by bin/sample/generate.sh.
EOF
    cat > "input/$env/transfer/README.txt" <<'EOF'
The transfer log exports (transferLog_MM-DD.csv, newest-first rows), read by
bin/transfer/parse.sh. SAMPLE data — regenerated by bin/sample/generate.sh.
EOF
    cat > "input/$env/server/README.txt" <<'EOF'
The server log exports (logEntry_MM-DD.csv, newest-first rows), read by
bin/server/parse.sh. SAMPLE data — regenerated by bin/sample/generate.sh.
EOF
    cat > "input/$env/ip/README.txt" <<'EOF'
ip-hosts.tsv — the address<->endpoint map (ip TAB host), owned by bin/ip.sh
(ip_put unions, never replaces; no reverse DNS anywhere). The generator
writes it in ip_put's own order, so builds never churn it. SAMPLE data.
EOF
    cat > "input/$env/renames/README.txt" <<'EOF'
The rename maps, read through bin/renames.sh: subscriptions.tsv (logged name
-> current name), profiles.tsv (logged profile -> current), flowid-names.tsv
(the flowId->name snapshot fm_snapshot_renames diffs). Machine-maintained in
a real estate; here written by bin/sample/generate.sh as the byte fixed-point
of the generated config export.
EOF
done

echo "sample: done." >&2
