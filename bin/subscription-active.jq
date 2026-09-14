# subscription-active.jq — why a subscription is NOT active (2026-09-14, user
# request). One line per named subscription in subscriptions.json:
#   name <TAB> codes      codes = the comma-joined reasons, empty = active
#   1  status.code UNDEPLOYED
#   2  status.code SAVED_NOT_DEPLOYED
#   3  a *_receive_scheduler_enable parameter set to No (sftp, ftp or relay0)
#   4  source_folder_monitoring_state Inactive
# The ONE definition, shared by the Subscriptions analyses page (the Active
# column, bin/analyses/publish.sh) and the subscription detail pages (the
# Features Status rows, bin/transfer/reports/details.sh) so the two never
# disagree. Value tests are case-insensitive; a null status or parameters
# object counts as active.
.[] | select(.name != null and .name != "") | . as $s
| ($s.parameters // {}) as $p
| [ (if $s.status.code == "UNDEPLOYED" then "1" else empty end),
    (if $s.status.code == "SAVED_NOT_DEPLOYED" then "2" else empty end),
    (if ([$p | to_entries[] | select(.key | test("receive_scheduler_enable$")) | .value | tostring | ascii_downcase] | any(. == "no")) then "3" else empty end),
    (if (($p.source_folder_monitoring_state // "") | tostring | ascii_downcase) == "inactive" then "4" else empty end) ] as $c
| [ $s.name, ($c | join(",")) ] | @tsv
