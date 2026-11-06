# Automating availability

## Signals

| Signal | Tells us | Used for | Trust |
|---|---|---|---|
| Genesys WFM schedules + approved time off | Home agent isn't working today | Morning `Open` | High — fully automatic |
| Genesys presence / routing status | Agent hasn't logged in after shift start, or logged off | `LikelyOpen` no-shows; early leaves | Medium — supervisor confirms no-shows |
| Avigilon badge events | Agent has or hasn't entered the building | Strengthens a no-show | Medium |
| Desk PC sign-in (Defender device logons / Intune) | Who is actually at the desk | `OccupiedUnclaimed` | Medium; depends on licensing |

## State logic

```
06:00  for each seat with a home agent:
         not scheduled today            -> Open        (source WFM)
         scheduled                      -> Assigned
       seats with no home agent          -> Open
       active blocks                     -> Blocked

shift start + grace (15 min, configurable):
         scheduled, not logged in, no badge (if enabled)
                                          -> LikelyOpen  (source Presence)
         supervisor confirms              -> Open
         supervisor dismisses / agent logs in -> Assigned

during the day:
         agent offline after scheduled end -> Open
         someone other than home/claimed agent signs in at the desk PC
                                          -> OccupiedUnclaimed (flag only)

claim:   Open | confirmed LikelyOpen      -> Claimed
release: Claimed                          -> Open

nightly: close the day, archive events, nothing carries over
```

## Required mappings

- **Agent → home seat**: `Seat.HomeAgentGenesysUserId` (+ UPN). Sourced from the Supervisor Tracker hierarchy and Genesys; never committed here.
- **Device → seat**: the seat ID is stored on the PC's Entra device object in `extensionAttribute1` (e.g. `A1`), not in the device name or this repo, so PCs can be renamed or moved without touching the app. Set it with `tools/Set-SeatDeviceTag.ps1` from a `SeatId,ComputerName` CSV (exported from the Metro Seat → Computer Map workbook; never committed). Run with `-WhatIf` first; `-ClearUnlisted` clears PCs that left the floor. Re-run whenever a PC is swapped. The device worker resolves a sign-in's device to a seat by reading this attribute; `Seat.DeviceId` is filled from it at runtime.
  - First mapping received 2026-11-06: 226 of 264 seats have a PC. No PC listed yet for A6, A21 (sup desk), H1–H3, N12, N13, N15, N16 and the Academy (T1–T29).

## Where it runs

- Azure Automation (PowerShell 7): morning sync, nightly reset. Schedules can't run more often than hourly, so frequent checks live elsewhere.
- Presence worker (always on): Genesys notification subscription. Renew channels before expiry; on restart, resync current presence for scheduled agents.
- Alerts: post to the supervisors' Teams channel via webhook when seats open or a no-show needs confirming. No Teams app needed.

## Privacy

Derive statuses only. Supervisors never see badge times, raw sign-in logs or locations. Confirm the use of badge and sign-in data with HR before enabling those signals.
