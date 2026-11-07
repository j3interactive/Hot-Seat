# 0004 — A PC's seat lives on the device and is mirrored into Intune

Date: 2026-11-07 · Status: Accepted

## Decision

Which desk a PC sits at is recorded on the device, not in this repo or in the device name, and is written by one script (`tools/Set-SeatDeviceTag.ps1`) from the Metro Seat → Computer Map:

| Where | Value | Used for |
|---|---|---|
| Entra device `extensionAttribute1` | `A1` | Dynamic device groups (e.g. by pod or area); the Hot-Seat device signal |
| Intune device notes, one `[Seat]` line | `[Seat] A1 · Main Floor · Pod A1–A14` | Seen by the helpdesk on the device Overview page. Other note text is kept |
| Intune device category, one per area | `Metro - Main Floor`, `Metro - Escalations`, `Metro - Nesting`, `Metro - The Academy` | A filterable, exportable column in the Intune device list; Intune assignment filters |

Devices are matched Entra → Intune by Entra device ID, never by name, so the planned rename-by-serial doesn't break the mapping.

## Why

The owner wants the seat map to feed asset tracking and be visible in Intune. Intune has no seat or location field, so each place gets the form it can use: the extension attribute for automation (Intune can't show it), notes for people, and categories for filtering. Categories are per area, not per seat: 264 categories would be unmanageable and would clutter the Company Portal category prompt.

## Consequences

- Graph permissions: `Device.ReadWrite.All` and `DeviceManagementManagedDevices.ReadWrite.All`. Notes and category assignment use the Graph beta endpoint.
- The script won't overwrite an extension attribute or a non-Metro category already used for something else without `-Force`.
- Next (not built): a nightly runbook that pulls Intune hardware details for tagged PCs into SQL, and an admin Assets page in Hot-Seat (seat → PC → serial, model, last seen; flags gaps and drift). This widens Hot-Seat into asset tracking for Metro PCs.
