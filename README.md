# Databook Search Tool

Standalone project (split out of `75809910 CCB\databook-search`) providing:

1. **Free-text search of DxDatabook** — chat-style UI, searches every
   component table (Resistor, Capacitor, Diode, IC, IC-Digital, Connector,
   etc.) live via SQL. Type a part number, value, package, or description
   fragment.
2. **Altium / Agile `501-xxxxx-xx` matching** — click **"501 Match"** in the
   header, enter a full or partial Agile number (or MPN/description), and it
   matches against a static Altium library export, then cross-references each
   hit into DxDatabook to show the corresponding IGT part number(s).

## Architecture

```
[ Browser - site/index.html ] --localhost:5005--> [ agent/DatabookAgent.ps1 ] --ODBC--> [ DxDatabook SQL ]
                                                              |
                                                              +--> reads data/*.csv for 501 matching
```

Browser only ever talks to `http://localhost:5005`. SQL is read-only
(every query runs inside `BEGIN TRAN...ROLLBACK`) and the agent binds to
localhost only.

## Run it

```powershell
cd agent
.\Start-DatabookAgent.ps1
```

Then open `site\index.html` in a browser. The status pill turns green when
the agent is reachable.

## Endpoints

- `GET  /health` — agent status
- `GET  /tables` / `GET /columns?table=X` — curated schema introspection
- `POST /search` — structured filter search
- `POST /chat` — free-text search (NL parser + universal keyword scan across
  every DxDatabook table)
- `GET/POST /match501` — Altium 501-xxxxx-xx matching
  - `GET /match501?code=501-00559-00`
  - `POST /match501 {"code":"501-00559-00"}`

## Keeping the 501-match data current

The `data/` folder holds static CSV snapshots (not live SQL). Refresh them
with:

```powershell
.\refresh-data.ps1
```

See `data/README.md` for details.
