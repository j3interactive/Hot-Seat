# 0001 — Azure-native web app instead of SharePoint lists + SPFx

Date: 2026-10-28 · Status: Accepted

## Context

The first design used SharePoint lists for data and an SPFx web part for the map (the pattern of the Supervisor Tracker). It needs no new spend, but SharePoint has no push to the browser (the map would poll), concurrency has to be hand-built with ETags, and history reporting is awkward.

The owner wants the best possible experience, specifically real-time updates.

## Decision

Build an Azure-native app: React front end, an API on Functions/App Service, Azure SQL, and Azure Web PubSub for push.

## Consequences

- Claims show on every screen within about a second; atomic claims in SQL.
- Proper history for utilization reporting.
- Roughly $20–$200/month Azure spend (see `docs/cost.md`) and an app to own and patch.
- About 3× the build effort of the SharePoint version.
