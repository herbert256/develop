# bin/sample/gen-config.awk — stage 2: the estate spec -> the two FlowManager
# config exports. printf-written JSON (the generator never needs jq): bare
# top-level arrays, 2-space indent, LF — the shape bin/flow-manager.sh consumes.
#
#   awk -F'\t' -f prelude.awk -f gen-config.awk \
#       -v EST=input/<env>/.sample/_estate.tsv \
#       -v PJSON=input/<env>/flow-manager/partners.json \
#       -v SJSON=input/<env>/flow-manager/subscriptions.json
#
# Consistency contract: participants[].comProfileId (subscriptions) ==
# communicationProfiles[].businessId (partners) — both come from estate col 14.
# flowId (col 12) is what renames/flowid-names.tsv must byte-match.

function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }

# ---- collect the estate -----------------------------------------------------
{
    fk = $1; uc = $3; site = $4; acct = $5
    if (!(acct in ABIZ)) { AORD[++NA] = acct; ABIZ[acct] = $15 }
    if (uc == "A") { AORPH[acct] = 1; ALOGIN[acct] = ""; next }   # orphan: partner record only
    NS++
    S_site[NS] = site; S_acct[NS] = acct; S_prof[NS] = $7; S_flow[NS] = $12
    S_biz[NS] = $13; S_cp[NS] = $14; S_pat[NS] = $16; S_fdk[NS] = $17
    S_sched[NS] = $23; S_uc[NS] = uc; S_tags[NS] = $30; S_cred[NS] = $29
    # per-account aggregation
    ACPS[acct] = ACPS[acct] SUBSEP NS                 # comm profiles = one per flow
    if ($6 != "") ALOGIN[acct] = $6
    if ($31 != "") {
        n = split($31, w, ";")
        for (i = 1; i <= n; i++) if (!((acct, w[i]) in WSEEN)) { WSEEN[acct, w[i]] = 1; AWL[acct] = AWL[acct] SUBSEP w[i] }
    }
    if ($19 != "") { S_host[NS] = $19; S_port[NS] = $22 }
    else           { S_host[NS] = "";  S_port[NS] = $22 }
    if (index($30, "credexp") > 0) ACREDEXP[acct] = 1
}

END {
    # ---- partners.json ------------------------------------------------------
    printf "[" > PJSON
    for (ai = 1; ai <= NA; ai++) {
        acct = AORD[ai]
        printf "%s\n  {\n", (ai > 1 ? "," : "") > PJSON
        printf "    \"businessId\": \"%s\",\n", ABIZ[acct] > PJSON
        printf "    \"meta\": {\n      \"href\": \"https://flowmanager.acme.example:443/api/v2/partners/%s\",\n      \"createdTimestamp\": 1780000000000,\n      \"modifiedTimestamp\": 1787000000000\n    },\n", ABIZ[acct] > PJSON
        # customAttributes: AllowIP1..10 (nulls where unused, like the export)
        nw = split(AWL[acct], wl, SUBSEP)             # wl[1] is the empty lead-in
        printf "    \"customAttributes\": {" > PJSON
        for (i = 1; i <= 10; i++) {
            v = (i + 1 <= nw) ? "\"" wl[i + 1] "\"" : "null"
            printf "%s\"AllowIP%d\": %s", (i > 1 ? ", " : ""), i, v > PJSON
        }
        printf ", \"businessUnit\": null, \"partnerType\": null},\n" > PJSON
        # communicationProfiles: one per flow of this account
        printf "    \"communicationProfiles\": [" > PJSON
        nc = split(ACPS[acct], cps, SUBSEP)
        first = 1
        for (ci = 2; ci <= nc; ci++) {
            si = cps[ci] + 0
            printf "%s\n      {\n", (first ? "" : ",") > PJSON; first = 0
            printf "        \"businessId\": \"%s\",\n", S_cp[si] > PJSON
            proto = (S_port[si] == 21) ? "FTP" : "SFTP"
            if (S_host[si] != "") {                    # we connect OUT -> SERVER profile
                printf "        \"name\": \"SCP_%s_%s\",\n", jesc(S_prof[si]), S_cred[si] > PJSON
                printf "        \"type\": \"SERVER\", \"protocol\": \"%s\", \"enabled\": true,\n", proto > PJSON
                printf "        \"clientAuthentication\": \"%s\",\n", (S_cred[si] == "KEY" ? "PUBLIC_KEY" : "PASSWORD") > PJSON
                printf "        \"hosts\": [\"%s\"], \"port\": %d,\n", S_host[si], S_port[si] > PJSON
                printf "        \"serverVerification\": false, \"storedPublicKey\": \"NO_PUBLIC_KEY\"\n      }" > PJSON
            } else {                                   # the partner connects IN -> CLIENT profile
                printf "        \"name\": \"CCP_%s_%s\",\n", jesc(acct), S_cred[si] > PJSON
                printf "        \"type\": \"CLIENT\", \"protocol\": \"%s\", \"enabled\": true,\n", proto > PJSON
                printf "        \"clientAuthentication\": \"%s\",\n", (S_cred[si] == "KEY" ? "PUBLIC_KEY" : "PASSWORD") > PJSON
                printf "        \"login\": \"%s\", \"loginName\": \"%s\",\n", ALOGIN[acct], ALOGIN[acct] > PJSON
                printf "        \"fingerPrintVerified\": false, \"customAuthentication\": false\n      }" > PJSON
            }
        }
        printf "\n    ],\n" > PJSON
        # credentials: the login credential + certificates (some expiring)
        printf "    \"credentials\": [" > PJSON
        cfirst = 1
        if (ALOGIN[acct] != "") {
            printf "\n      {\"businessId\": \"%s\", \"name\": \"%s\", \"type\": \"LOGIN\", \"login\": \"%s\", \"hasPassword\": true,\n       \"customAttributes\": {\"loginRestrictionPolicy\": \"Generic Whitelisting\"}}", substr(ABIZ[acct], 1, 24) "login00age", ALOGIN[acct], ALOGIN[acct] > PJSON
            cfirst = 0
        }
        if (acct in ACREDEXP) {
            # one certificate past expiry, one expiring soon (the certificates page)
            printf "%s\n      {\"businessId\": \"%s\", \"name\": \"%s-cert\", \"type\": \"CERTIFICATE\", \"isPrivateCertificate\": false, \"expiration\": 1786665600000}", (cfirst ? "" : ","), substr(ABIZ[acct], 1, 24) "cert0000expa", jesc(acct) > PJSON
            printf ",\n      {\"businessId\": \"%s\", \"name\": \"%s-cert-next\", \"type\": \"CERTIFICATE\", \"isPrivateCertificate\": false, \"expiration\": 1789948800000}", substr(ABIZ[acct], 1, 24) "cert0000expb", jesc(acct) > PJSON
            cfirst = 0
        }
        printf "\n    ],\n" > PJSON
        printf "    \"domains\": [{\"businessId\": \"c25c8684-4ecc-40fc-9d8b-85e39cbf91f2\", \"name\": \"Default\"}],\n" > PJSON
        printf "    \"name\": \"%s\",\n    \"tags\": [\"sample-estate\"]\n  }", jesc(acct) > PJSON
    }
    printf "\n]\n" > PJSON

    # ---- subscriptions.json -------------------------------------------------
    printf "[" > SJSON
    for (si = 1; si <= NS; si++) {
        printf "%s\n  {\n", (si > 1 ? "," : "") > SJSON
        printf "    \"businessId\": \"%s\",\n", S_biz[si] > SJSON
        printf "    \"meta\": {\n      \"href\": \"https://flowmanager.acme.example:443/api/v2/subscriptions/%s\",\n      \"createdTimestamp\": 1780000000000,\n      \"modifiedTimestamp\": 1787000000000\n    },\n", S_biz[si] > SJSON
        printf "    \"name\": \"%s\",\n", jesc(S_site[si]) > SJSON
        printf "    \"patternName\": \"%s\",\n", S_pat[si] > SJSON
        printf "    \"participants\": [\n" > SJSON
        printf "      {\"businessId\": \"%s\", \"name\": \"%s\", \"comProfileId\": \"%s\",\n       \"role\": \"%s\", \"protocol\": \"SFTP\", \"participantType\": \"partner\"},\n", substr(S_biz[si], 1, 24) "0000par00000", jesc(S_acct[si]), S_cp[si], (S_fdk[si] == "work" || S_fdk[si] == "hybs" ? "source" : "target") > SJSON
        printf "      {\"businessId\": \"%s\", \"name\": \"g2c_hub\", \"comProfileId\": null,\n       \"role\": \"hub\", \"protocol\": \"PESIT\", \"participantType\": \"application\"}\n    ],\n", substr(S_biz[si], 1, 24) "0000hub00000" > SJSON
        # parameters: the profile, the flowdir key, remote dirs + the cron
        printf "    \"parameters\": {\n" > SJSON
        printf "      \"customAttribute_FlowIdentifier\": \"%s\"", jesc(S_prof[si]) > SJSON
        if (S_fdk[si] == "scan") {
            printf ",\n      \"source_folder_monitoring_scan_dir\": \"/data/cft/out/%s/in\"", jesc(S_prof[si]) > SJSON
            printf ",\n      \"source_folder_monitoring_time_between_scans\": \"60\"" > SJSON
            printf ",\n      \"source_folder_monitoring_state\": \"Active\"" > SJSON
            printf ",\n      \"hybrid_partner_sftp_relay0_send_remote_directory\": \"/\"" > SJSON
        } else if (S_fdk[si] == "work") {
            printf ",\n      \"target_working_dir\": \"/data/cft/in/%s\"", jesc(S_acct[si]) > SJSON
            printf ",\n      \"target_target_file_name\": \"&NFNAME\"" > SJSON
            printf ",\n      \"hybrid_partner_sftp_relay0_receive_remote_directory\": \"/outbox\"" > SJSON
            printf ",\n      \"hybrid_partner_sftp_relay0_receive_file_filter_expression\": \"*\"" > SJSON
        } else if (S_fdk[si] == "hybt") {
            printf ",\n      \"target_hybrid_participant\": \"partner_sftp\"" > SJSON
            printf ",\n      \"hybrid_partner_sftp_relay0_send_remote_directory\": \"/\"" > SJSON
        } else if (S_fdk[si] == "hybs") {
            printf ",\n      \"source_hybrid_participant\": \"partner_sftp\"" > SJSON
            printf ",\n      \"hybrid_partner_sftp_relay0_receive_remote_directory\": \"/outbox\"" > SJSON
            printf ",\n      \"hybrid_partner_sftp_relay0_receive_file_filter_expression\": \"*\"" > SJSON
        }
        # the Quartz cron for polled flows (UC3/UC5) — absent on the nocron
        # flows (the Missing-cronjobs report's planted rows)
        if ((S_uc[si] == 3 || S_uc[si] == 5) && index("," S_tags[si] ",", ",nocron,") == 0) {
            cron = cron_of(S_sched[si], S_tags[si])
            if (cron != "") printf ",\n      \"hybrid_partner_sftp_relay0_receive_scheduler_cron_expression\": \"%s\"", cron > SJSON
        }
        printf "\n    },\n" > SJSON
        printf "    \"flowId\": \"%s\",\n", S_flow[si] > SJSON
        printf "    \"flowName\": \"%s\",\n", jesc(S_site[si]) > SJSON
        # tags: the real export carries free-form tags — plant a business-line
        # tag ("BL_" + the FlowID's first part) on most subscriptions beside
        # the sample marker; every 7th gets none, the analyses Subscriptions
        # page's blank-BL case
        nbl = split(S_prof[si], BLP, "_")
        if (si % 7 != 0 && nbl > 0 && BLP[1] != "")
            printf "    \"tags\": [\"BL_%s\", \"sample-estate\"],\n", jesc(BLP[1]) > SJSON
        else
            printf "    \"tags\": [\"sample-estate\"],\n" > SJSON
        printf "    \"status\": {\"code\": \"DEPLOYED\", \"timestamp\": 1787000000000},\n" > SJSON
        printf "    \"domains\": [{\"businessId\": \"c25c8684-4ecc-40fc-9d8b-85e39cbf91f2\", \"name\": \"Default\"}],\n" > SJSON
        printf "    \"type\": \"Subscription\"\n  }" > SJSON
    }
    printf "\n]\n" > SJSON
}

# sched -> Quartz cron. The drift-cron flow's CONFIG says 06:00 while its
# observed polls run later — the Cronjobs page's Drifts row.
function cron_of(sched, tags,   a) {
    if (index("," tags ",", ",driftcron,") > 0) return "0 0 6 ? * *"
    if (sched == "grid15")                      return "0 5/30 * * * ?"
    if (sched == "c15")                         return "0 5/15 * * * ?"
    if (substr(sched, 1, 3) == "ch:")           return "0 " (substr(sched, 4) + 0) " * * * ?"
    if (substr(sched, 1, 3) == "cd:") { split(substr(sched, 4), a, ":"); return "0 " (a[2] + 0) " " (a[1] + 0) " ? * *" }
    return ""
}
