# Data snapshots

These CSVs are static exports used only for Altium/Agile `501-xxxxx-xx`
matching (the `/match501` endpoint). They are NOT used for the main chat
search, which queries live DxDatabook SQL via ODBC.

- `Altium_Combined.csv` — Altium library export (CMP_ID, Comment, Description, ...).
  The `Comment` column holds the Agile `501-xxxxx-xx` number or MPN.
- `Unified_Library.csv` — merged PADS+Altium+Databook view (not yet wired into
  matching, kept here for future use).

## Refreshing

Re-copy the latest exports from the source project whenever the Altium
library changes:

```powershell
.\refresh-data.ps1
```

This overwrites both CSVs from
`75809910 CCB\databook-export\`. Restart the agent afterwards — it caches
the CSVs in memory on first request.
