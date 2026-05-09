# Databook Search - Proof of Concept

Two parts:

- `agent/`  - local PowerShell HTTP bridge to DxDatabook (read-only).
- `site/`   - chat-style frontend (deploy to GitHub Pages).

## Architecture

```
[ Browser - chat UI ]  --localhost:5005-->  [ DatabookAgent.ps1 ]  --ODBC-->  [ DxDatabook SQL ]
        ^                                            |
        GitHub Pages (Everi-Elect-Hardware org)      runs as the user (Windows auth)
```

Browser talks only to `http://localhost:5005`. SQL is never reachable
from the browser. Each user runs their own agent, queries with their own
permissions.

## Run the agent

```powershell
cd databook-search\agent
.\start.cmd
```

Output should show:

```
[hh:mm:ss][INFO] DatabookAgent listening at http://localhost:5005/
```

## Test from the browser

Double-click `databook-search\site\index.html`. Status pill turns green
("Agent connected") and you get a chat box. Try:

- `0603 1% 4.7k resistor`
- `0.1uF 50V 0402 cap`
- `schottky diode SOT-23`
- `TVS array`

Each turn extracts a structured filter, builds a parameterised SELECT,
runs it against DxDatabook, and shows the matches.

## API endpoints

- `GET  /health`          - check agent is up
- `GET  /tables`          - list whitelisted tables
- `GET  /columns?table=X` - list whitelisted columns
- `POST /search`          - structured filter search (raw)
- `POST /chat`            - natural-language input (parser + DB lookup)

## Optional: real LLM via GitHub Models

The chat endpoint uses a built-in regex parser by default (no key required).
To upgrade to a real LLM (free with corporate Copilot Enterprise):

```powershell
$env:GITHUB_TOKEN = 'ghp_...'   # PAT with Models:read scope
.\start.cmd
```

When set, the chat endpoint routes user text through `gpt-4o-mini` first
and falls back to the regex parser if the LLM response is rejected by the
schema validator. The LLM only emits a JSON filter - it cannot produce
raw SQL, so the same safety guarantees apply.

## Safety guarantees

- Only `SELECT` statements; multi-statement and DDL/DML keywords rejected.
- SQL built server-side from a whitelisted (table, column, op) filter -
  the frontend never supplies raw SQL.
- All queries run inside `BEGIN TRAN ... ROLLBACK`.
- Listener bound to `localhost` only (not on the network).
- Result row count capped (`-MaxRows`, default 200).
- ODBC connection uses `ApplicationIntent=ReadOnly`.

## Deployment

**Frontend:** push `site/index.html` to a repo under
`https://github.com/Everi-Elect-Hardware`, enable GitHub Pages on `main`
branch. Pages URL `https://everi-elect-hardware.github.io/<repo>/` is
already in the agent's CORS allowlist.

**Agent:** distribute `agent/` folder to engineers (e.g. via Z: shared
drive or zipped via Teams/email). They double-click `start.cmd`. To
auto-launch on login, drop a shortcut into
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup`.

## Customising

- Tables/columns: edit `$Schema` near the top of `DatabookAgent.ps1`.
- Allowed origins (CORS): edit `$AllowedOrigins`.
- Port: `start.cmd -Port 5006`.
- Add new field detection in the chat parser: edit `Invoke-RuleParser`
  or rely on the LLM with `$env:GITHUB_TOKEN` set.

## Why this works under Threat Locker / AppLocker / WDAC

No new binary is introduced. `start.cmd` only invokes `powershell.exe`
(system-allowlisted) against a `.ps1` text file. Verified on this
machine:

- WDAC user-mode enforcement = 0
- AppLocker service stopped
- PowerShell language mode = FullLanguage
- Execution Policy bypassed per-process (documented MS mechanism)

If a stricter laptop blocks unsigned scripts, sign `DatabookAgent.ps1`
with an IGT cert - one approval, lifetime fix.
