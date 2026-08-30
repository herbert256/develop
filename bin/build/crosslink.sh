#!/usr/bin/env bash
#
# bin/build/crosslink.sh — resolve the top-bar ENVIRONMENT-SWITCH target, build-time.
#
# Since the runtime top bar (2026-07) the publishes bake only a compact
# `<div class="topbar" data-eb=… data-env=…>` placeholder per page — report.js
# renders the bar client-side. The env-switch TARGET is the one per-page datum
# only a build can know (an env's pages are rendered before the other env
# exists), so this step runs AFTER both env publishes and stamps each
# placeholder with a `data-twin` attribute, BOTH WAYS:
#   - the twin page (same path, other environment) exists  -> its href
#   - it does not                                          -> the OTHER env's
#     own 404 page (docs/<other>/404.html, written by bin/build/publish.sh)
# So the switch never hits the webserver's 404. Idempotent: any existing
# data-twin is replaced, so re-runs (and a re-publish of one env followed by a
# new crosslink) always converge. A page not yet stamped still works —
# report.js falls back to a plain pathname swap. Only the two env trees are
# touched — the shared root pages (home, build report) keep their client-side
# dual-anchor env toggle, and the baked-chrome pages (help) carry no
# placeholder.
#
# Usage:  bin/build/crosslink.sh    (after all publishes; build.sh runs it last)
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# Freshness. This step REWRITES ~2700 pages, so it can never take a docs page
# as an input — it would invalidate itself. What it actually depends on is
# which pages EXIST in each env, and that changes only when a publish runs:
# every publish drops a stamp in data/<env>/.publish when it finishes, so this
# is up to date exactly when its own stamp is newer than all of them.
# (No area lib here — bin/build/ scripts source nothing but their own logic.)
STAMP="data/.publish/crosslink.stamp"        # shared: this step spans both envs
if [ -z "${AXWAY_FORCE_PUBLISH:-}" ] && [ -f "$STAMP" ]; then
    stale=0
    # every stamp of both envs — the area publishes plus the two cross-cutting
    # steps that also write pages (the index pages and acc-vs-prod), all of
    # which run BEFORE this one, so their stamps are older when nothing ran
    for dep in "${BASH_SOURCE[0]}" data/acceptance/.publish/*.stamp data/production/.publish/*.stamp; do
        if [ -f "$dep" ] && [ "$dep" -nt "$STAMP" ]; then
            stale=1; break
        fi
    done
    if [ "$stale" = 0 ]; then
        echo "crosslink.sh: no environment was re-published; switch links unchanged." >&2
        exit 0
    fi
fi

for env in acceptance production; do
    other=production; [ "$env" = production ] && other=acceptance
    [ -d "docs/$env" ] || continue
    if [ ! -f "docs/$other/404.html" ] && [ ! -d "docs/$other" ]; then
        # the other env was never published: leave this tree's switches
        # unstamped (report.js's client-side fallback still works)
        echo "crosslink.sh: docs/$other missing — leaving $env switch links unfilled." >&2
        continue
    fi
    find "docs/$env" -name '*.html' -print0 \
    | E="$env" O="$other" xargs -0 perl -i -pe '
        s{<div class="topbar"((?:(?!>).)*)>}{
            my $attrs = $1;
            if ($attrs =~ / data-env=/) {
                my ($e, $o) = ($ENV{E}, $ENV{O});
                my $rel = $ARGV; $rel =~ s{^docs/\Q$e\E/}{};
                my $ups = () = $rel =~ m{/}g;                       # page depth below the env root
                my $up  = "../" x ($ups + 1);                        # ../ to the docs root
                my $target = -f "docs/$o/$rel" ? $rel : "404.html";  # twin page, else the other env 404
                $attrs =~ s{ data-twin="[^"]*"}{};
                qq{<div class="topbar"$attrs data-twin="$up$o/$target">}
            } else {
                qq{<div class="topbar"$attrs>}                       # a baked bar: leave it alone
            }
        }e;
    '
    # summary: how many of this env's pages have no twin (their switch lands
    # on the other env's 404 page)
    total=$(find "docs/$env" -name '*.html' | wc -l | tr -d ' ')
    # `|| true`: ZERO orphans — every page has a twin — is the ideal steady
    # state, and a zero-match grep exits 1 under set -euo pipefail; wc has
    # already printed the 0 by then, so the count stays correct.
    orphan=$(grep -rlE "data-twin=\"[^\"]*/$other/404\.html\"" "docs/$env" --include='*.html' 2>/dev/null | wc -l | tr -d ' ' || true)
    echo "crosslink.sh: $env -> $other: $total page(s) linked, $orphan without a twin (-> $other/404.html)." >&2
done

mkdir -p data/.publish && : > "$STAMP"
