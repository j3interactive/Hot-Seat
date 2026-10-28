# Roadmap

Update the status column whenever a phase moves.

| Phase | Scope | Status |
|---|---|---|
| 0 | Design, decision records, interactive mockup | Done (2026-10-28) |
| 1 | Azure SQL schema + seed of all seats from the Metro chart | Done in pilot (app creates and seeds on first start) |
| 2 | Web app: floor map, day view, claim/release, Entra sign-in and roles | Pilot built 2026-10-28 |
| 3 | Real-time with Azure Web PubSub | Pilot built 2026-10-28 (Free tier) |
| 4 | 6 AM Genesys WFM sync runbook (automatic Opens) | Not started |
| 5 | Presence worker: no-shows (with supervisor confirm) and early leaves; Teams channel alerts | Not started |
| 6 | Optional signals (Avigilon badges, desk PC sign-ins) and utilization reporting | Not started — needs HR sign-off |
| — | Production hardening: Key Vault, CI/CD (GitHub Actions + OIDC), least-privilege SQL, blocks UI, Web PubSub Standard | Not started — see "Pilot shortcuts" in AGENTS.md |

Phases 1–4 make a usable live tool; 5–6 make it smarter.

## Open questions

- Which Genesys management units cover Metro agents?
- Source of the agent → home seat mapping: Supervisor Tracker lists, Genesys, or both?
- Avigilon platform: Alta (cloud) or Unity/ACM (on-prem)?
- Is Defender for Endpoint licensed (for device logon events)?
- Pod → supervisor ownership: confirm the mapping in `data/floor-layout.json` (some pods were inferred from the sheet).
- Custom domain for the app.
