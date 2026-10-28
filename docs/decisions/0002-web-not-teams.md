# 0002 — Plain web app, not a Teams app

Date: 2026-10-28 · Status: Accepted

## Context

A Teams app adds packaging, Teams SSO, and admin approval for custom apps. The owner confirmed the tool does not need to live in Teams.

## Decision

Ship a standalone web app with App Service built-in Entra authentication, app roles, and an enterprise app with assignment required.

## Consequences

- Works on any browser: desks, phones, a floor TV in kiosk mode.
- No in-Teams experience. Alerts still go to a Teams channel via webhook if wanted.
- A wall display needs a dedicated Viewer-only account or a read-only display route.
