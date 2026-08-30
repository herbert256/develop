#!/usr/bin/env bash
#
# uc-cases.sh — the single source of truth for what each UC<n> subscription
# prefix means. Sourced by bin/transfer/reports/details.sh (the Subscription
# Summary "Use case" row) and bin/analyses/publish.sh (the Use cases page).
#
# The UC number encodes the file's journey and our role:
#   From / To  — where the file comes FROM and goes TO, each Internal (our own
#                systems, reached over the internal CFT/PeSIT hub) or External
#                (a third-party partner).
#   We are     — client (WE connect out) or server (the partner connects in);
#                the two relays are mixed.
#   We         — send (a file leaves our org) / receive (a file enters it);
#                a relay does neither cleanly.
#   exp        — the direction a normal 1-partner flow expects (out = we connect
#                out, in = partner connects in); "" for the relays (mixed/both),
#                so the Use cases page's direction-consistency check skips them.
#   trigger    — how OUR client action starts, for the use cases where we are the
#                client (UC1/UC3/UC5): "Cronjob" (a Quartz receive scheduler polls
#                the partner — UC3, and UC5's pull side) or "Dir scan" (we watch a
#                source folder and push as files appear — UC1). "" where the
#                partner connects in (the server use cases UC2/UC4, and UC8).
#
# UC1-4 are one external partner bridged to our internal application over CFT.
# UC5-UC8 are direct relays (two endpoints, NO internal CFT leg), one per
# source/target push-pull combination — the FlowManager template catalog
# (input/flow-manager/templates.json) names all four:
#   UC5 PARTNER_PULL_ST_PARTNER_PUSH  we pull from the source, we push to the target
#   UC6 PARTNER_PULL_ST_PARTNER_PULL  we pull from the source, the target collects
#   UC7 PARTNER_PUSH_ST_PARTNER_PULL  the source delivers,     the target collects
#   UC8 PARTNER_PUSH_ST_PARTNER_PUSH  the source delivers,     we push to the target
# ALL FOUR link TWO PARTNERS — that is what makes them relays, and it is why
# a UC5-UC8 account name is domain_partner_partner, NOT the domain_application_
# partner of UC1-UC4 (see the PDA derivation in bin/flow-manager.sh: both name
# tokens become partners and the account gets no application). UC6/UC7 have a
# PUBLISHED template but no subscriptions yet, so their rows are template-
# derived and unvalidated against real traffic.

uc_meta() {   # $1 = UC token (UC1, …) -> "From<TAB>To<TAB>WeAre<TAB>We<TAB>Human<TAB>exp<TAB>trigger"
    case $1 in
        UC1) printf 'Internal\tExternal\tClient\tSend\tWe are the client and send a file to the partner\tout\tOpsWise' ;;
        UC2) printf 'Internal\tExternal\tServer\tSend\tWe are the server; the partner connects in and collects a file from us\tin\tPartner' ;;
        UC3) printf 'External\tInternal\tClient\tReceive\tWe are the client and receive a file from the partner\tout\tCronjob' ;;
        UC4) printf 'External\tInternal\tServer\tReceive\tWe are the server; the partner connects in and delivers a file to us\tin\tPartner' ;;
        UC5) printf 'External\tExternal\tClient\trelay\tRelay for 2 partners, we are the client to both; we receive a file from the source and send it to the target\tout\tCronjob' ;;
        UC6) printf 'External\tExternal\tClient + Server\trelay\tRelay for 2 partners, we are the client and receive a file from the source; the target connects in and collects it from us\t\tCronjob' ;;
        UC7) printf 'External\tExternal\tServer\trelay\tRelay for 2 partners, we are the server to both; the source connects in and delivers a file, the target connects in and collects it\tin\tPartner' ;;
        UC8) printf 'External\tExternal\tServer + Client\trelay\tRelay for 2 partners, we are the server and the source connects in and delivers a file to us; we send it to the target\t\tOpsWise' ;;
        *)   printf '\t\t\t\t\t\t' ;;
    esac
}
