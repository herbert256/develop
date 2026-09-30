# bin/ssh-family.awk — the [Ssh Default] logon-screening FAMILY classifier,
# ONE copy (2026-09-30): bin/server/reports/logon.sh (the Logons report) and
# bin/logons.sh (the logon summary behind the detail pages and the
# partners-in page) carried it twice, with the rule "a change to either
# matcher belongs in both". Both inject this file into their awk program
# (awk ... "$(cat bin/ssh-family.awk)"'program') — keep it function-only.
#
# ssh_family(m) -> the family letter of message m, "" when it is none of them;
# the username it names in the global SSH_U ("" when the line names none):
#   A  "[Ssh Default] Allowed user 'U' from address 'IP'"
#   T  "User with login name 'U' … successfully authenticated over SSH"
#   D  "[Ssh Default] Disallowed user "U" from address "IP""
#   N  "Unable to find account with username: U" (unquoted; a trailing
#      sentence separator stripped)
#   B  "no certificate is found for user 'ACCOUNT@LOGIN'" (keyed on the LOGIN)
#   K  "[Ssh Default] User LOGIN failed to login successfully N times …"
#   L  "[Ssh Default] User 'U' is locked." / "… locked due to too many failed
#      login attempts." / "User login is locked. Username: "U""
# The order of the tests IS the rule (a line matching two shapes takes the
# first). The callers act on the letter; RSTART / RLENGTH are clobbered.

# the quoted token right after the matched prefix: the quote character itself
# varies per family (Allowed logs single quotes, Disallowed double)
function qtok(rest,   q, p) {
    q = substr(rest, 1, 1)
    if (q != "\x27" && q != "\"") return ""
    p = index(substr(rest, 2), q)
    if (p <= 0) return ""
    return substr(rest, 2, p - 1)
}

function ssh_family(m,   u) {
    u = ""
    if (match(m, /\[Ssh Default\] Allowed user /)) {
        SSH_U = qtok(substr(m, RSTART + RLENGTH)); return "A" }
    if (m ~ /successfully authenticated over SSH/ && match(m, /login name /)) {
        SSH_U = qtok(substr(m, RSTART + RLENGTH)); return "T" }
    if (match(m, /\[Ssh Default\] Disallowed user /)) {
        SSH_U = qtok(substr(m, RSTART + RLENGTH)); return "D" }
    if (match(m, /Unable to find account with username: [^ ]+/)) {
        u = substr(m, RSTART + 38, RLENGTH - 38); sub(/[.,;]$/, "", u)
        SSH_U = u; return "N" }
    if (match(m, /no certificate is found for user /)) {
        u = qtok(substr(m, RSTART + RLENGTH)); sub(/^.*@/, "", u)
        SSH_U = u; return "B" }
    if (match(m, /\[Ssh Default\] User [A-Za-z0-9_.-]+ failed to login successfully/)) {
        u = substr(m, RSTART + 19); sub(/ failed to login.*$/, "", u)
        SSH_U = u; return "K" }
    if (match(m, /\[Ssh Default\] User /) && m ~ /is locked|locked due to too many failed login/) {
        u = qtok(substr(m, RSTART + RLENGTH))
        if (u == "" && match(m, /Username: /)) u = qtok(substr(m, RSTART + RLENGTH))
        SSH_U = u; return "L" }
    SSH_U = ""
    return ""
}
