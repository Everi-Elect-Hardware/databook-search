# IGT DxDatabook Chat Search — Complete User Guide

A web chat that lets you search the IGT DxDatabook in plain English
("0.1uF 50V 0402 cap", "USB hub IC working at 3.3V", "datasheet for
42-1438-01E").

You set this up **once**, in about 2 minutes. After that you just open
the web page when you want to search.

This document contains everything you need — no other instructions to read.

---

## 1. How it works (10 seconds)

- The **web page** runs in your browser at
  https://everi-elect-hardware.github.io/databook-search/
- A small **PowerShell agent** runs on YOUR PC at
  http://localhost:5005
- The web page talks to the agent. The agent talks to DxDatabook using
  your Windows login (read-only). Nothing leaves your PC unless you
  opt into the optional AI features in Section 4.

---

## 2. Prerequisites (already true on every IGT engineering laptop)

- Windows 10 or 11
- Windows PowerShell 5.1 (built in)
- A working `DxDatabook` ODBC DSN (System or User DSN, Trusted
  Connection, ApplicationIntent=ReadOnly). If `Get-OdbcDsn -Name DxDatabook`
  in PowerShell returns nothing, contact IT or the Mentor Graphics admin.
- Network access to https://everi-elect-hardware.github.io
  (standard internet — already allowed).

You do **NOT** need: admin rights, Python, Node.js, Docker, or any
new software install.

---

## 3. First-time setup — start the agent (do this once)

Step 1. Open this folder in File Explorer:
```
Z:\LIBRARY\MentorGraphics\DatabookAgent\
```

Step 2. **Right-click `Start-DatabookAgent.ps1`** and choose
**"Run with PowerShell"**.

Step 3. A blue PowerShell window opens with text similar to:
```
[INFO] DatabookAgent listening at http://localhost:5005/
[INFO] DSN=DxDatabook  MaxRows=200  CmdTimeout=10s
[INFO] Live schema: 34 tables discovered with IGTPartNo column.
[INFO] Press Ctrl+C to stop.
```
**Leave that window open** while you use the search page. Closing it
stops the agent.

Step 4. Open this URL in any browser:
```
https://everi-elect-hardware.github.io/databook-search/
```
Look at the top-right of the page:

| Indicator | Meaning |
|---|---|
| **Agent: ok** (green) | The agent is running — you're good to go |
| **Agent: not running** (red) | The PowerShell window isn't open — go back to Step 2 |

Step 5 (one-time convenience). Pin a shortcut to your taskbar or
desktop so you can start the agent with one click each morning:
- Right-click `Start-DatabookAgent.ps1` in
  `Z:\LIBRARY\MentorGraphics\DatabookAgent\` → **Send to → Desktop
  (create shortcut)**.

That's it for basic search. The rest of this guide is optional.

---

## 4. Optional — enable the AI features (recommended)

Without this section the search still works using pattern matching:
you can search by package, value, tolerance, voltage, part number,
keyword. With AI enabled you also get:

- Plain-English understanding ("USB hub IC working at 3.3V" → narrowed
  to 3 rows instead of 280)
- Datasheet hints with likely manufacturer part numbers
- Conceptual answers ("what is the clamping voltage of 48017191W")

It uses GitHub Models (gpt-4o-mini). You authenticate with a personal
access token (PAT) that lives only on your PC.

### 4.1 Generate your token

1. In a browser, go to
   https://github.com/settings/personal-access-tokens
2. Click **Generate new token** → **Fine-grained token**.
3. Fill in:
   - **Token name:** `DxDatabook Agent`
   - **Expiration:** 90 days (or your account's maximum)
   - **Repository access:** "Public Repositories (read-only)" is fine
   - **Permissions** → expand **Account permissions** → find **Models**
     → set it to **Read-only**
4. Click **Generate token** (button at the bottom).
5. Copy the token. It starts with `github_pat_` and is shown only once.
   Paste it temporarily into Notepad.

### 4.2 Paste the token into the agent

1. Press `Win + R`, type the following exactly, and press Enter:
   ```
   %LOCALAPPDATA%\DatabookAgent
   ```
   File Explorer opens to that folder.
2. If a file called `.env` already exists, open it in Notepad. If not,
   right-click `.env.example` → **Copy** → paste into the same folder
   → rename the copy from `.env.example - Copy` to `.env`.
3. Open `.env` in Notepad. Find the line that starts with `GITHUB_TOKEN=`
   and change it to:
   ```
   GITHUB_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   ```
   (use your real token). Save the file and close Notepad.
4. **Restart the agent**: close the blue PowerShell window from
   Section 3 Step 3, then right-click `Start-DatabookAgent.ps1`
   again → **Run with PowerShell**.

In the new agent window you should now see:
```
[INFO] LLM enabled (model=openai/gpt-4o-mini token=github_...)
```

Reload the search page. The token is now in use.

---

## 5. How to search

Type any of the following in the chat box on the web page:

| You type | What you get |
|---|---|
| `0.1uF 50V 0402 cap` | All matching ceramic capacitors |
| `4.7k 1% 0603 resistor` | All matching resistors |
| `TVS diode SOT-23-6` | All TVS arrays in SOT-23-6 package |
| `USB hub IC working at 3.3V` | USB hub controller ICs narrowed by voltage |
| `STM32 in QFP` | Microprocessors with the STM32 substring in a QFP package |
| `47464894` *(any bare IGT part number)* | The full row plus a datasheet hint |
| `datasheet for 42-1438-01E` | The row plus a Google search link for the manufacturer datasheet |
| `what is the clamping voltage of 48017191W` | A short prose answer using context from previous searches |
| `all USB connectors` | Universal scan across every component family |

### Chat history & sidebar

- Every conversation is saved automatically (in your browser only).
- The left sidebar shows the last 50 chats — click any to reopen.
- Click **+ New Chat** to start a fresh session.
- Hover a chat in the sidebar to delete it.

### Refine vs fresh

- By default each message is a **fresh** search.
- After you get results, the chip "Refine on top" appears — turn it on
  to AND your new term into the previous query.

---

## 6. Daily routine

1. Run `Start-DatabookAgent.ps1` (or click your desktop shortcut).
2. Open https://everi-elect-hardware.github.io/databook-search/
3. Search.
4. At end of day close the blue PowerShell window. That stops the agent.

---

## 7. Troubleshooting

### Top-right pill says "Agent: not running" (red)

- The blue PowerShell window was closed. Run the launcher again.
- Something else is using TCP port 5005. Close other dev tools, restart
  the launcher.
- Windows Firewall blocked the listener. When it asks the first time,
  click **Allow access**.

### Launching gives "ExecutionPolicy" or "running scripts is disabled"

The launcher passes `-ExecutionPolicy Bypass` per process so this
should not happen. If it does, AppLocker is blocking your account.
Contact IT or Eduard Kliger.

### Launching does nothing / window flashes and closes

Open PowerShell manually and run:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "Z:\LIBRARY\MentorGraphics\DatabookAgent\Start-DatabookAgent.ps1"
```
The error will stay on screen.

### Top-right LLM pill says "LLM: error — 401" or "403"

Your GitHub token expired or is missing the **Models: Read-only**
permission. Repeat Section 4 to generate a new token and paste it
into `.env`, then restart the agent.

### Top-right LLM pill says "LLM: error — Unable to connect to the remote server"

Corporate firewall blocked the outbound HTTPS call to GitHub Models at
that moment. The search itself still works in rule-based mode. Try
again in a few seconds or restart the agent. This is intermittent on
the IGT network.

### "No matches in DxDatabook for that query"

- For broad searches, add a distinctive token (manufacturer letters,
  value with unit, or a package code).
- For datasheet queries, make sure you typed the FULL IGT part number
  including any dash or trailing letter (e.g. `42-1438-01E`,
  `32908891W`).
- The agent always tries the LLM first, then falls back to rules. If
  the bottom of the answer says `parsed by: rules-fallback` the LLM
  was blocked at that moment — see the previous troubleshooting item.

### Datasheet hint box is missing

The hint requires that your message contains one of: `datasheet`,
`data sheet`, `datsheet`, `specs`, `spec sheet`. Even without AI, the
agent will produce a Google search link built from the row description.

### Search returns way too many rows

Add more distinctive words. "usb hub ic 3.3v" filters down to 3 rows;
"usb" alone returns 280+. Every additional word post-filters the rows
so they all must contain it.

---

## 8. Updating the agent

Just run `Start-DatabookAgent.ps1` from the shared folder again.

The launcher automatically:
- Mirrors the newest agent files from
  `Z:\LIBRARY\MentorGraphics\DatabookAgent\` into
  `%LOCALAPPDATA%\DatabookAgent\` (only when the source is newer).
- Then starts the local copy.

Your `.env` (with your token) is **never overwritten**.

---

## 9. Stopping & uninstalling

To stop: close the blue PowerShell window.

To uninstall completely: delete the folder `%LOCALAPPDATA%\DatabookAgent\`.
You may also revoke your token at
https://github.com/settings/personal-access-tokens.

The Z drive copy is shared and should not be touched.

---

## 10. Privacy & security

- The agent listens only on `localhost` (not on your network or the
  internet). Nobody else can reach it from another PC.
- It connects to DxDatabook using **your** Windows credentials,
  read-only (`ApplicationIntent=ReadOnly`), SELECT statements only.
  Multi-statement batches, INSERT/UPDATE/DELETE, and DDL are blocked
  by the agent before reaching SQL Server.
- The web page allowed origins are restricted to:
  `https://everi-elect-hardware.github.io`, `http://localhost`,
  `http://127.0.0.1`.
- Your GitHub token (if you provided one) is stored only in
  `%LOCALAPPDATA%\DatabookAgent\.env` on your PC. It is sent only to
  `https://models.github.ai`. It is never written to disk anywhere
  else and never transmitted to IGT systems.
- No telemetry. No usage logs are uploaded anywhere. The agent's log
  is shown in the blue PowerShell window only.

---

## 11. Quick reference (print this)

| Action | What to do |
|---|---|
| Start the agent | Right-click `Z:\LIBRARY\MentorGraphics\DatabookAgent\Start-DatabookAgent.ps1` → Run with PowerShell |
| Open the search page | https://everi-elect-hardware.github.io/databook-search/ |
| Add GitHub token | Edit `%LOCALAPPDATA%\DatabookAgent\.env`, set `GITHUB_TOKEN=github_pat_...`, restart agent |
| Stop the agent | Close the blue PowerShell window |
| Update the agent | Run the launcher again from the Z drive |
| Uninstall | Delete `%LOCALAPPDATA%\DatabookAgent\` |

---

## 12. Contact

Eduard Kliger — Hardware Engineering
