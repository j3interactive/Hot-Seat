# AGENTS.md — Metro Hot Seating

Read this file first, every session. It is the source of truth for what this
project is, the decisions already made, and how to change it safely. If you
change a decision, update this file and add a record under `docs/decisions/`
in the same commit.

## What this is

A live, real-time web app that shows supervisors on the Metro floor which
desks are free right now, lets them claim a desk for an agent, and keeps the
map current automatically from Genesys schedules and presence.

It replaces `NEW Metro Seating Chart 5.27.26.xlsx`: one sheet of free-text
availability per supervisor per weekday, plus hand-drawn floor tabs (Floor,
Nesting, Wescalations, The Academy). Its problems are what this app fixes:
free-text status, no claim step (double booking), goes stale, and seat rules
buried in side columns (e.g. the D8 keyboard rule).

- Owner: Jason Reed (Senior Systems Administrator, Ace Applications, for Emovis Operations)
- Tenants: primary `fte.emovisops.com`; secondary `emovisops.com`. This app lives in the primary tenant unless stated otherwise.
- Users: ~13 floor supervisors (claim seats), viewers such as leadership or a floor TV (read only), and admins (edit seats, blocks).

## Decisions already made (do not reopen without the owner)

| # | Decision | Record |
|---|---|---|
| 1 | Azure-native web app with real-time push, not SharePoint lists + SPFx | `docs/decisions/0001-azure-web-app.md` |
| 2 | Plain web app with Entra sign-in, not a Teams app | `docs/decisions/0002-web-not-teams.md` |
| 3 | Azure SQL is the system of record; claims are atomic in the database | `docs/decisions/0003-azure-sql-system-of-record.md` |
| 4 | Automation suggests, supervisors confirm, for no-shows; schedule-based opens are fully automatic | `docs/automation.md` |

## Architecture in one screen

Full detail: `docs/architecture.md`.

- **Front end**: single-page app with an absolutely positioned floor map. Layout comes from `data/floor-layout.json` (served by `GET /api/layout`), never hardcoded. The pilot (`public/`) is dependency-free JavaScript; move to React + TypeScript when it grows past one screen.
- **API**: Node.js + Express on App Service (`server/`). All writes go through it. It enforces permissions, block rules and claim concurrency.
- **Real-time**: Azure Web PubSub. The API broadcasts a `seat.changed` event after every committed change; clients patch their local state. Clients never trust a push alone — on reconnect they refetch the day.
- **Data**: Azure SQL (`db/schema.sql`).
- **Auth**: App Service built-in auth with Entra ID. Enterprise app has "Assignment required"; app roles `Seating.Admin`, `Seating.Supervisor`, `Seating.Viewer`, plus `Seating.Automation` for the runbooks and worker.
- **Automation**:
  - Azure Automation runbook, ~6:00 AM ET: pull Genesys WFM schedules and time off, mark seats Open for home agents not scheduled.
  - Always-on worker (App Service WebJob or Container App): Genesys notification subscription for presence and routing status; flags no-shows and early leaves.
  - Nightly runbook: close out the day, archive events, reset claims.
- **Secrets**: Key Vault + managed identities. No secrets in code, config files or this repo.
- **Monitoring**: Application Insights.

### Pilot shortcuts (fix before production)

The dev pilot deployed by `infra/deploy.sh` cuts these corners on purpose:
- Availability is sample data by weekday (`server/sample.js`) plus manual "Mark open / assigned". Replaced by the WFM sync (phase 4).
- The Web PubSub connection string and the Entra client secret are App Service settings, not Key Vault references. No Key Vault yet.
- The app's managed identity is `db_ddladmin` so it can create the schema on first start. Drop to reader/writer and run migrations from the pipeline instead.
- Web PubSub is the Free tier (20 connections, no SLA).
- No blocks UI yet; `Block` table exists but is unused.

## Running and deploying

- Local: `npm install && npm run dev` → http://localhost:8080 with an in-memory store and a fake admin user (`DEV_USER`). Headers `x-dev-user` / `x-dev-role` let you simulate other users. `DEV_USER` is ignored on App Service.
- Azure (dev): in Cloud Shell, clone the repo and run `./infra/deploy.sh`. It creates the app registration and roles, deploys `infra/main.bicep` to `rg-metroseating-dev`, grants the managed identity database access (`tools/sql-grant.js`) and zip-deploys the code. Safe to re-run; re-running is also how you ship code changes for now.
- Users get access by being assigned a role on the "Metro Hot Seating (dev)" enterprise app. Unassigned users cannot sign in.

## Domain rules (the app must enforce these)

- Seat IDs are the floor labels exactly: `A1`–`A41`, `B1`–`B27`, `C1`–`C27`, `D1`–`D23`, `E1`–`E21`, `F1`–`F15`, `G1`–`G30`, `H1`–`H3`, `I1`–`I24` (Escalations), `N1`–`N24` (Nesting), `T1`–`T29` (Academy). Never renumber; the floor signage uses them.
- Seat types: `Agent`, `SupervisorDesk`, `TrainerDesk`, `Ops`. Only `Agent` seats can be claimed.
- The board is today only. No week view or forward booking: the API accepts only today's work date (America/New_York), and the nightly reset starts a fresh day.
- Daily status, per seat per work date: `Assigned` → `Open` / `LikelyOpen` → `Claimed`; plus `Blocked` and `OccupiedUnclaimed`. Definitions in `docs/data-model.md`.
- A claim succeeds only if the seat is `Open` (or `LikelyOpen` after a supervisor confirms) and its row version matches. On conflict return 409 with who claimed it.
- Blocks (room closed, pod closed, seat out of service) override everything except an existing claim, which is surfaced as a conflict for an admin.
- Seat notes are shown whenever the seat is selected or claimed (e.g. D8: remove the special keyboard; agent uses a regular keyboard).
- Escalations agents should stay on the main floor when possible — show as an area note, do not block.

## Data and privacy rules

- **No employee data in this repo.** No agent names, UPNs, Genesys user IDs, badge IDs or device IDs. The seed holds seat geometry and pod labels only. Home-agent and device mappings are loaded into SQL from Genesys / Entra / the Supervisor Tracker at runtime.
- Supervisor display names appear in `data/floor-layout.json` only as pod labels (how the floor refers to pods). Real ownership is by Entra object ID in SQL.
- Badge (Avigilon) and device sign-in data are used only to derive a status. Never store or show raw timestamps or locations to supervisors. Retain derived events for 90 days unless the owner says otherwise.
- This repo must stay private.

## Conventions

- TypeScript everywhere in the app; PowerShell 7 for Azure Automation runbooks (matches the owner's other runbooks); Python only for one-off tools in `tools/`.
- Infrastructure as code in `infra/` (Bicep) when it is added. Resource naming: `<type>-metroseating-<env>`, e.g. `app-metroseating-prod`, `sql-metroseating-prod`, `wps-metroseating-prod`, `kv-metroseating-prod`. Environments: `dev`, `prod`.
- Times are stored in UTC; work dates and shift logic use `America/New_York`.
- Changing the floor: edit `data/floor-layout.json`, run `python3 tools/build_seed.py`, commit both the JSON and the regenerated `db/seed.sql`. Never hand-edit `db/seed.sql`.
- Schema changes: add a numbered migration under `db/migrations/` once the database exists; keep `db/schema.sql` as the current full picture.
- Commit messages: imperative, explain why.

## Repo map

```
AGENTS.md                  this file
CLAUDE.md                  points agents here
README.md                  human overview and quick start
server/                    Express API: index (routes), auth (Easy Auth claims), store-sql / store-memory, realtime (Web PubSub), sample (pilot data)
public/                    front end: index.html, app.js, styles.css
infra/main.bicep           Azure resources for one environment
infra/deploy.sh            end-to-end deploy from Cloud Shell
infra/app-roles.json       Entra app roles (IDs are fixed; never change them)
data/floor-layout.json     areas, pods, seat grid, landmarks (source of truth for geometry)
db/schema.sql              Azure SQL schema (the app applies it on first start)
db/seed.sql                generated from floor-layout.json (for manual loads; the app seeds itself)
tools/build_seed.py        generator for db/seed.sql
tools/sql-grant.js         grants the managed identity database access
docs/architecture.md       components, flows, diagram
docs/automation.md         availability signals and state logic
docs/data-model.md         tables, statuses, claim concurrency
docs/cost.md               Azure cost estimate
docs/roadmap.md            build phases and status
docs/decisions/            architecture decision records
mockup/README.md           where the interactive mockup lives
```

## Current status

See `docs/roadmap.md`. As of 2026-10-28: pilot app built (map, claims, roles, real-time) and being deployed to a dev environment in the fte.emovisops.com tenant. Next: supervisor feedback, then the Genesys WFM sync (phase 4).

## Before you finish any change

1. Did a decision change? Update the table above and add a decision record.
2. Did the floor change? Regenerate `db/seed.sql`.
3. Did status meanings or tables change? Update `docs/data-model.md`.
4. Update `docs/roadmap.md` status.
5. Confirm no employee data or secrets were added.
