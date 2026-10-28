# Azure cost estimate

Estimated 2026-10-28. Prices vary by region and agreement — confirm in the Azure pricing calculator before approval.

| Component | Pilot | Production | Notes |
|---|---|---|---|
| App Service (Linux) — web, API, presence worker as WebJob | B1 ≈ $13/mo | P1v3 ≈ $124/mo | B1 handles this load; P1v3 for headroom / scale-out |
| Azure SQL Database | Basic (5 DTU) ≈ $5/mo | Standard S0/S1 ≈ $15–30/mo* | Avoid serverless: it would run all day |
| Azure Web PubSub | Free (20 connections, 20k msgs/day) $0 | Standard 1 unit ≈ $50/mo* | Free fits a pilot; it has no SLA |
| Azure Automation | ≈ $0 | ≈ $0 | Short daily jobs |
| Key Vault | < $1 | < $1 | |
| Application Insights | $0–5 | $5–10 | |
| **Total** | **≈ $20–25/mo** | **≈ $195–215/mo** | Middle option (B1 + S0 + Web PubSub Standard) ≈ $80/mo |

\* Not shown on the pages checked; from general pricing knowledge — verify.

Free-tier check: ~13 supervisors + 1–2 displays < 20 connections; ~300 changes/day × 20 clients ≈ 6,000 messages/day < 20,000.

No new user licenses. The main cost is build time (≈ 4–8 weeks for one developer).

Sources: [Web PubSub pricing](https://azure.microsoft.com/en-us/pricing/details/web-pubsub/), [Web PubSub billing model](https://learn.microsoft.com/azure/azure-web-pubsub/concept-billing-model), [App Service pricing breakdown](https://www.pump.co/blog/azure-app-service-pricing), [Azure SQL pricing](https://www.flexera.com/blog/finops/azure-sql-database-pricing/).
