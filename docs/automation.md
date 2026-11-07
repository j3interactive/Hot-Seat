# Automating availability

## Signals

| Signal | Tells us | Used for | Trust |
|---|---|---|---|
| Genesys WFM schedules + approved time off | Home agent isn't working today | Morning `Open` | High — fully automatic |
| Genesys presence / routing status | Agent hasn't logged in after shift start, or logged off | `LikelyOpen` no-shows; early leaves | Medium — supervisor confirms no-shows |
| Desk PC sign-in (Entra sign-in logs, seat from Datto UDF) | Who actually signed in at which desk, and when | Arrivals at the home desk; agents at another desk; `OccupiedUnclaimed` | Medium — sign-ins only, no sign-outs |
| Avigilon badge events | Agent has or hasn't entered the building | Strengthens a no-show | Medium |

## State logic

```
06:00  for each seat with a home agent:
         not scheduled today            -> Open        (source WFM)
         scheduled                      -> Assigned    (store shift start/end)
       seats with no home agent          -> Open
       active blocks                     -> Blocked

every 2-5 min (worker): read new Windows sign-ins, map device -> seat
         home agent signs in at home desk -> stays Assigned; clears any LikelyOpen
         home agent signs in at another desk
                                          -> home seat LikelyOpen (source Device)
         someone other than home/claimed agent signs in at a desk
                                          -> OccupiedUnclaimed (flag only)

shift start + grace (15 min, configurable):
         scheduled, no Genesys login, no desk sign-in today, no badge (if enabled)
                                          -> LikelyOpen  (source Presence)
         supervisor confirms              -> Open
         supervisor dismisses / agent logs in or signs in -> Assigned

during the day:
         agent offline in Genesys after scheduled end -> Open
         (desk sign-ins can't show departures; Genesys presence covers them)

claim:   Open | confirmed LikelyOpen      -> Claimed
release: Claimed                          -> Open

nightly: close the day, archive events, nothing carries over
```

## Desk PC sign-ins (Entra + Datto)

Two sources, each doing what it's good at:

- **When and who: Entra sign-in logs.** Metro desk PCs are Entra joined, so a
  Windows sign-in is logged against the **Windows Sign In** application
  (app ID `38aa3b87-a06d-4817-b275-7a316988d93b`) with the user and
  `deviceDetail.deviceId` (the Entra device ID). The worker polls
  `GET /v1.0/auditLogs/signIns` filtered to that app and to
  `createdDateTime` after its last checkpoint.
  - Needs `AuditLog.Read.All` (application permission, admin consent) on the
    worker's managed identity, and Entra ID P1.
  - Events land a few minutes after they happen; the worker uses
    `createdDateTime`, not arrival time.
  - The first sign-in of the day is reliable. Unlocks are not guaranteed to
    log, and there are no sign-out events, so desk sign-ins prove arrival only.
- **Which seat: Datto RMM user-defined field.** Each Metro desk PC carries its
  seat ID in a Datto UDF labelled `Seat` (e.g. `D8`). Datto is the asset
  record, so moving a PC means changing one field, not renaming the device.
  A sync runbook copies the value to the Entra device object
  (`extensionAttributes.extensionAttribute1`), which:
  - lets the worker resolve `deviceId` → seat with no Datto call per sign-in;
  - makes the seat usable in Entra dynamic device groups
    (`device.extensionAttribute1 -startsWith "D"`) for Intune assignments.

The join between the two is the device name: Datto `hostname` ↔ Entra device
`displayName`. The sync runbook flags any Datto device with a seat but no
unique Entra match, or two PCs claiming the same seat, instead of guessing.

## Required mappings

- **Agent → home seat**: `Seat.HomeAgentGenesysUserId` (+ UPN). Sourced from the Supervisor Tracker hierarchy and Genesys; never committed here.
- **Device → seat**: Datto UDF `Seat` is the source of truth; copied to Entra `extensionAttribute1` and to `Seat.DeviceId` (Entra device ID) by the device sync. Not in the device name, so PCs can move without a rename.
- **Sign-in user → agent**: Entra UPN → `Seat.HomeAgentUpn` / claim's agent UPN.

## Where it runs

- Azure Automation (PowerShell 7):
  - Morning sync (~6:00 AM ET): Genesys schedules and time off.
  - Device sync (hourly, plus on demand): Datto `Seat` UDF → Entra `extensionAttribute1` and `Seat.DeviceId`. Reads Datto with a read-only API user; writes Entra with `Device.ReadWrite.All`.
  - Nightly reset.
  - Schedules can't run more often than hourly, so frequent checks live in the worker.
- Worker (always on):
  - Genesys notification subscription. Renew channels before expiry; on restart, resync current presence for scheduled agents.
  - Sign-in poll every 2–5 minutes from a stored checkpoint; on restart, re-read since the start of the work day.
- Alerts: post to the supervisors' Teams channel via webhook when seats open or a no-show needs confirming. No Teams app needed.

## Privacy

Derive statuses only. Supervisors never see badge times, raw sign-in logs, device names or locations. Sign-in events are reduced to "signed in at seat X today" and kept as derived `SeatEvent` rows (90 days); raw log entries are not stored. Confirm the use of badge and sign-in data with HR before enabling those signals.
