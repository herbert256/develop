# fastawk.sh — route every unqualified `awk` call to mawk (sourced, not run).
#
# The system awk on this Mac is BSD onetrueawk, the slowest common awk; mawk
# (Homebrew) runs the same POSIX programs 4-9x faster and was validated
# byte-identical on the full pipeline (parse caches and every .rpt — the only
# cross-awk variance was the @data:buckets in-cell ORDER, an order-independent
# set for report.js, plus two count-tie orderings that now carry deterministic
# tiebreakers). A shim dir with awk->mawk is prepended to PATH so all scripts
# and their children pick it up; when mawk is not installed this is a no-op
# and everything runs on the system awk as before.
#
# Sourced by bin/transfer/lib.sh, bin/server/lib.sh, bin/publish_lib.sh and
# bin/flow-manager.sh — i.e. every pipeline entry point.
if command -v mawk >/dev/null 2>&1; then
    _FASTAWK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/data/.awkshim"
    if [ ! -x "$_FASTAWK_DIR/awk" ]; then
        mkdir -p "$_FASTAWK_DIR"
        ln -sf "$(command -v mawk)" "$_FASTAWK_DIR/awk"
    fi
    case ":$PATH:" in
        *":$_FASTAWK_DIR:"*) ;;
        *) PATH="$_FASTAWK_DIR:$PATH"; export PATH ;;
    esac
fi
