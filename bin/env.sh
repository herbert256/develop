#!/usr/bin/env bash
#
# bin/env.sh — resolve the active ENVIRONMENT (sourced, not run).
#
# The pipeline serves TWO SecureTransport environments side by side:
#   acceptance   input/acceptance/…  ->  data/acceptance/…  ->  docs/acceptance/…
#   production   input/production/…  ->  data/production/…  ->  docs/production/…
# (data/.awkshim stays shared — the mawk shim is environment-independent.
# input/<env>/hostnames/ is PER ENV: the two estates share no partners or
# endpoints, and the reverse cache's rule (b) labels an address with the
# CONFIGURED host of its own env, so one shared cache would cross-label.)
#
# Every entry script sources this right next to bin/fastawk.sh. The env comes
# from $AXWAY_ENV (bin/build.sh exports it per loop pass); a standalone script
# run without it defaults to production (2026-08-31, user request; was acceptance), so the repo convention that every
# script takes no arguments is preserved.
#
AXWAY_ENV="${AXWAY_ENV:-production}"
case $AXWAY_ENV in
    acceptance|production) ;;
    *) echo "AXWAY_ENV must be 'acceptance' or 'production' (got '$AXWAY_ENV')" >&2; exit 1 ;;
esac
export AXWAY_ENV
