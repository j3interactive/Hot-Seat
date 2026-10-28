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
- **Device → seat**: store the seat ID on the device (Entra device extension attribute or Intune device category), not in the device name, so PCs can move without a rename.

## Where it runs

- Azure Automation (PowerShell 7): morning sync, nightly reset. Schedules can't run more often than hourly, so frequent checks live elsewhere.
- Presence worker (always on): Genesys notification subscription. Renew channels before expiry; on restart, resync current presence for scheduled agents.
- Alerts: post to the supervisors' Teams channel via webhook when seats open or a no-show needs confirming. No Teams app needed.

## Privacy

Derive statuses only. Supervisors never see badge times, raw sign-in logs or locations. Confirm the use of badge and sign-in data with HR before enabling those signals.
