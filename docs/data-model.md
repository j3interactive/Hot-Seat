# Data model

Schema: [`db/schema.sql`](../db/schema.sql). Seed (geometry only): [`db/seed.sql`](../db/seed.sql), generated from [`data/floor-layout.json`](../data/floor-layout.json).

## Tables

| Table | Holds | Notes |
|---|---|---|
| `Area` | Main Floor, Escalations, Nesting, The Academy | Map canvas size per area |
| `Pod` | A1–A14, B14–B27 … | Position on the map, label, owning supervisor (Entra object ID, loaded at runtime) |
| `Seat` | One row per desk | Grid cell inside its pod, type, note, home agent and device mapping (loaded at runtime) |
| `SeatDay` | Status of each seat on each work date | One row per seat per date; `rowversion` for concurrency |
| `Block` | Closures with a time range and reason | Area, pod or single seat |
| `SeatEvent` | Append-only audit of every change | Who/what changed it and why |

## Statuses (`SeatDay.Status`)

| Status | Meaning | Set by |
|---|---|---|
| `Assigned` | Home agent is scheduled and expected | Morning sync |
| `Open` | Free to claim | Morning sync (not scheduled), supervisor confirm, release, early leave |
| `LikelyOpen` | Scheduled agent hasn't shown; needs a supervisor to confirm | Presence worker |
| `Claimed` | Taken for a specific agent today | Supervisor |
| `Blocked` | Closed by a `Block` | Block rules |
| `OccupiedUnclaimed` | Someone is signed in who isn't the home or claimed agent | Device signal (flag) |

`Source` records where a status came from: `WFM`, `Presence`, `Badge`, `Device`, `Manual`, `Block`, `System`.

## Claim concurrency

```sql
UPDATE dbo.SeatDay
SET Status = 'Claimed', ClaimedForName = @agent, ClaimedForUpn = @agentUpn,
    ClaimedByUpn = @me, ClaimedAt = SYSUTCDATETIME(), Source = 'Manual'
WHERE SeatId = @seat AND WorkDate = @date
  AND Status = 'Open' AND RowVer = @rowVer;
-- @@ROWCOUNT = 0  ->  409 Conflict, return the current row
```

Write the `SeatEvent` in the same transaction; publish to Web PubSub only after commit.

## Retention

`SeatDay` rows older than 400 days and `SeatEvent` rows older than 90 days are purged nightly (keeps a year of utilization reporting; adjust with the owner).
