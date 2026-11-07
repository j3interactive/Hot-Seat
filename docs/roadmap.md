# Roadmap

Update the status column whenever a phase moves.

| Phase | Scope | Status |
|---|---|---|
| 0 | Design, decision records, interactive mockup | Done (2026-10-28) |
| 1 | Azure SQL schema + seed of all seats from the Metro chart | Done in pilot (app creates and seeds on first start) |
| 2 | Web app: floor map, today-only view, claim/release, Entra sign-in and roles | Pilot built 2026-10-28; week view removed and seat-level supervisors added 2026-10-31 |
| 3 | Real-time with Azure Web PubSub | Pilot built 2026-10-28 (Free tier) |
| 4 | 6 AM Genesys WFM sync runbook (automatic Opens) | Not started |
| 5 | Presence worker: no-shows (with supervisor confirm) and early leaves; Teams channel alerts | Not started |
| 6 | Desk PC sign-ins (Entra sign-in logs + Datto seat UDF, see decision 0004), Avigilon badges, utilization reporting | Designed 2026-11-07; not built — needs HR sign-off and the seat UDF filled on every Metro PC |
| — | Production hardening: Key Vault, CI/CD (GitHub Actions + OIDC), least-privilege SQL, blocks UI, Web PubSub Standard | Not started — see "Pilot shortcuts" in AGENTS.md |

Phases 1–4 make a usable live tool; 5–6 make it smarter.

## Open questions

- Which Genesys management units cover Metro agents?
- Source of the agent → home seat mapping: Supervisor Tracker lists, Genesys, or both?
- Avigilon platform: Alta (cloud) or Unity/ACM (on-prem)?
- Datto: read-only API user created and its keys in Key Vault? (API access enabled and `Seat` = UDF 3, done 2026-11-07.)
- Do Metro PC hostnames in Datto match their Entra device names?
- Pilot check: do Windows sign-ins (including Windows Hello unlocks) show up in the Entra sign-in logs for Metro PCs, and how quickly?
- Seat → supervisor mapping (`seatSupervisors`, from the Floor tab colors): confirm B14–B27 = Jean, D1/D6 and E16–E21 = Kim B. (Edgar C. also has a desk by E16–E21), and whether Syair D. (A1–A13), Noah and Wayne should appear.
- Custom domain for the app.
