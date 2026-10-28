# 0003 — Azure SQL is the system of record

Date: 2026-10-28 · Status: Accepted

## Decision

All seat, status, claim, block and audit data lives in Azure SQL. Every write goes through the API. Web PubSub messages are notifications only; clients refetch on reconnect.

## Why

Atomic conditional updates make double-claims impossible; relational history supports reporting; Basic/S0 tiers are inexpensive at this scale. Serverless was rejected because the app is used all day and would never auto-pause.
