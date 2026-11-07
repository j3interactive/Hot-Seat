# 0004 — Desk PC sign-ins from Entra logs, seat mapping in Datto

Date: 2026-11-07 · Status: Accepted

## Decision

The desk sign-in signal reads Windows sign-ins from the Entra sign-in logs
(Microsoft Graph `auditLogs/signIns`, Windows Sign In app). The seat each PC
sits at is kept in a Datto RMM user-defined field (`Seat`) and copied to the
Entra device's `extensionAttribute1` by an hourly sync runbook.

Replaces the earlier plan of Defender for Endpoint device logons or an Intune
device category.

## Why

- Entra sign-in logs are already in the tenant, give the user, the Entra
  device ID and the event time, and need no extra license beyond Entra ID P1.
- Datto's `LastLoggedInUser` was considered and rejected as the timing source:
  it is the last user only, with no timestamp, and doesn't change on sign-out.
- Datto is the asset record, so the seat belongs there. Copying it to Entra
  makes it usable for Intune assignments through dynamic device groups.
- Defender device logon events need Defender for Endpoint P2, which isn't
  confirmed as licensed.

## Consequences

- Desk sign-ins prove arrival only; departures still come from Genesys presence.
- Datto hostname must match the Entra device display name; the sync flags mismatches.
- Needs HR sign-off before the signal is turned on.
