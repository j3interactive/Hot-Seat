# Metro Hot Seating (Hot-Seat)

A live seating map for the Metro floor. Supervisors see which desks are free
right now, claim a desk for an agent in one click, and every other supervisor's
screen updates within a second. Availability fills in automatically from
Genesys schedules and presence, so nobody has to maintain a spreadsheet.

Replaces `NEW Metro Seating Chart 5.27.26.xlsx`.

## How it works

1. **6:00 AM** — a runbook reads today's Genesys WFM schedules and time off. Any desk whose home agent isn't working is marked **Open**.
2. **Through the day** — Genesys presence events flag agents who haven't logged in after shift start (**Likely open**, a supervisor confirms) or who logged off early.
3. **Supervisors claim** open desks for floaters and moved agents. Claims are atomic: two supervisors can't take the same desk.
4. **Everyone sees it live** — changes are pushed to every open browser.
5. **Overnight** — the day closes out and resets.

## Stack

React + TypeScript · Azure App Service / Functions · Azure SQL · Azure Web PubSub · Entra ID sign-in · Azure Automation · Key Vault · Application Insights. Details in [docs/architecture.md](docs/architecture.md); estimated cost $20–$200/month in [docs/cost.md](docs/cost.md).

## Quick start (data)

```bash
python3 tools/build_seed.py        # regenerates db/seed.sql from data/floor-layout.json
```

Apply `db/schema.sql`, then `db/seed.sql`, to an Azure SQL database.

## Working on this repo

Read [AGENTS.md](AGENTS.md) first — it holds the decisions, domain rules, privacy rules and conventions. AI coding agents are pointed there automatically.

## Status

Design and mockup done. See [docs/roadmap.md](docs/roadmap.md).
