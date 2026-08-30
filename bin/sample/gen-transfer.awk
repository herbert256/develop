# bin/sample/gen-transfer.awk — stage 4: sorted T rows -> per-day transfer CSVs.
# Input: the T rows of _events.tsv sorted by absms DESCENDING (newest first,
# the real exports' order), so each day's rows arrive contiguously and in
# order; one output file per calendar day, header first.
#
#   awk -F'\t' -f prelude.awk -f gen-transfer.awk -v DIR=input/<env>/transfer
#
# Row shape (the real export): 41 comma-separated fields, every field
# double-quoted EXCEPT 19 Size (bare integer) and 39 Server Name (bare word).
BEGIN {
    HDR = "Status, Account, Login, UserClass, UserType, Application, Transfer Site, Direction, Action By, File, Remote Partner, Transfer Profile, Transfer Content Type, Remote Folder, Local Filename, Local Folder, ICAP Details, Local File, Size, Protocol, Secure, Mode, Start Time, End Time, Duration, Remote Host, Remote Port, Proxy Host, Transfer ID, Session ID, Session Start Time, Operation Index, Pesit Message, CoreId, Resubmitted, Additional info, X-Forwarded-For, SecurityParameters, Server Name, Alternated Addresses, Server Address"
    SEC["S1"] = "Cipher: aes128-ctr, MAC: hmac-sha2-256, Key Exchange: diffie-hellman-group-exchange-sha256, Public Key: ssh-rsa."
    SEC["S2"] = "Cipher: aes128-ctr, MAC: hmac-sha2-256, Key Exchange: curve25519-sha256, Public Key: rsa-sha2-256."
    SEC["S3"] = "Cipher: aes128-gcm@openssh.com, MAC: <implicit>, Key Exchange: diffie-hellman-group16-sha512, Public Key: rsa-sha2-256."
    SEC["T2"] = "Protocol: TLSv1.2 Cipher suite: TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384."
    SEC["T3"] = "Protocol: TLSv1.3 Cipher suite: TLS_AES_128_GCM_SHA256."
    SEC["NU"] = "null"
    ST["P"] = "Processed"; ST["F"] = "Failed"; ST["S"] = "Failed Subtransmission"; ST["A"] = "Failed (aborted)"
}
function q(s) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
function icap(c, fn) {
    if (c == "NP") return "Scanning was not performed"
    if (c == "AL") return "ALLOWED;ICAP server Name: acme-av;ICAP server URL: icap://av.mft.acme.example:1344/AVSCAN;Duration of Scanning: " (30 + rint(200)) " ms;ICAP Status: 204 No Modifications Needed;Result of Scanning: ALLOW;ResultMessage: Transfer ALLOWED. ICAP status: 204 No Modifications Needed;Custom Headers: None#"
    if (c == "BL") return "BLOCKED;ICAP server Name: acme-av;ICAP server URL: icap://av.mft.acme.example:1344/AVSCAN;Duration of Scanning: " (30 + rint(200)) " ms;ICAP Status: 200 OK;Result of Scanning: BLOCK;ResultMessage: Transfer BLOCKED: virus signature matched;Custom Headers: None#"
    if (c == "ER") return "Error occurred during scanning;ICAP server Name: acme-av;Result of Scanning: Error - ICAP server not reachable#"
    return "UNKNOWN"
}
$1 != "T" { next }
{
    abs = $2 + 0; dur = $3 + 0
    day = abs_iso(abs)
    if (day != CUR) {
        if (CUR != "") close(OUTF)
        CUR = day
        OUTF = DIR "/transferLog_" substr(day, 6, 2) "-" substr(day, 9, 2) ".csv"
        print HDR > OUTF
    }
    srnd(hash("fmt|" $20 "|" $19))
    login = ($6 == "") ? "UNKNOWN" : $6
    site  = ($7 == "") ? "UNKNOWN" : $7
    host  = ($13 == "") ? "UNKNOWN" : $13
    srv   = ($10 == "pesit") ? "Pesit Default" : ($10 == "ssh") ? "Ssh Default" : ($10 == "ftp") ? "none" : "UNKNOWN"
    # field 10 (File): the Inbound pesit legs carry the PROFILE token there —
    # the real export's shape; the real file name is field 15 (Local Filename)
    f10 = ($10 == "pesit" && $8 == "Inbound") ? $22 : $11
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", \
        q(ST[$4]), q($5), q(login), q("VirtClass"), q("Virtual"), q("FlowManagerApplication"), \
        q(site), q($8), q($9), q(f10), q("UNKNOWN"), q($22), q("FILE"), \
        q($8 == "Inbound" ? "Upload/" : "/"), q($11), q("/"), q(icap($16, $11)), \
        q("/data/FlowManager/" $5 "/" $11), $12, q($10), q("true"), q($15), \
        q(fmt_ts(abs)), q(fmt_ts(abs + dur)), q(humandur(dur)), q(host), q($14), q("UNKNOWN"), \
        q($19), q($18), q(fmt_ts($23 + 0)), q("UNKNOWN"), q("UNKNOWN"), q($20), q($21), \
        q("UNKNOWN"), q("UNKNOWN"), q(SEC[$17]), srv, q("UNKNOWN"), q("192.0.2.76") > OUTF
}
