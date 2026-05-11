# IGT DxDatabook Chat Search — User Setup Guide

A web chat that lets you search the IGT DxDatabook in plain English
("0.1uF 50V 0402 cap", "USB hub IC working at 3.3V", "datasheet for 42-1438-01E").

You need to do this **once**, in about 2 minutes. After that, just open the
web page when you want to search.

---

## How it works (10-second version)

- The **web page** runs in your browser:
  <https://everi-elect-hardware.github.io/databook-search/>
- A small **PowerShell agent** runs on YOUR PC at `http://localhost:5005`.
- The web page talks to the agent. The agent talks to DxDatabook using
  your Windows login (read-only).
- Nothing leaves your PC unless you opt into the optional AI features.

---

## Step 1 — Start the agent

1. Go to the shared launcher folder:
   ```
   Z:\LIBRARY\MentorGraphics\DatabookAgent\
   ```
2. **Right-click** `Start-DatabookAgent.ps1` → **Run with PowerShell**.
3. A blue PowerShell window opens with text like:
   ```
   [INFO] DatabookAgent listening at http://localhost:5005/
   [INFO] Live schema: 34 tables discovered with IGTPartNo column.
   ```
4. **Leave that window open.** Closing it stops the agent.

> **Tip:** Pin the launcher to your taskbar or copy a shortcut to your
> desktop so you can start it with one click each morning.

---

## Step 2 — Open the search page

In any browser, go to:
<https://everi-elect-hardware.github.io/databook-search/>

Look at the top-right of the page:

| Indicator | Meaning |
|---|---|
| **Agent: ok** (green) | The agent is running — you're good to go |
| **Agent: not running** (red) | Step 1 wasn't done, or the window was closed |

If it's red, go back to Step 1.

---

## Step 3 (optional) — Enable AI features

Without this step, the search still works — it just uses pattern matching.
Adding a GitHub token unlocks:

- Plain-English understanding ("USB hub IC working at 3.3V" → narrowed results)
- Datasheet hints with likely manufacturer part numbers
- Conceptual answers ("what is the clamping voltage of ...")

### How to get a token

1. Open <https://github.com/settings/personal-access-tokens>.
2. Click **Generate new token** → **Fine-grained token**.
3. Settings:
   - **Token name:** `DxDatabook Agent`
   - **Expiration:** 90 days (or your max)
   - **Repository access:** Public Repositories (read-only) is fine
   - **Permissions → Account → Models:** **Read-only** *(this is the important one)*
4. Click **Generate token**. Copy the token (starts with `github_pat_...`).

### Paste the token into the agent

1. Press `Win+R`, type this, hit Enter:
   ```
   %LOCALAPPDATA%\DatabookAgent
   ```
2. If a file called `.env` already exists, open it in Notepad.
   If not, right-click `.env.example` → Copy → paste into the same folder
   and rename the copy to `.env`.
3. Open `.env` and set the line:
   ```
   GITHUB_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   ```
   Replace the placeholder with your real token. Save and close.
4. **Restart the agent**: close the PowerShell window from Step 1 and
   run `Start-DatabookAgent.ps1` again.

In the agent window you should now see:
```
[INFO] LLM enabled (model=openai/gpt-4o-mini token=github_...)
```

---

## How to use it

Just type natural-language questions in the chat box. Examples:

| Type this | What you get |
|---|---|
| `0.1uF 50V 0402 cap` | All matching capacitors |
| `USB hub IC working at 3.3V` | Narrowed list of USB hub controller ICs |
| `4.7k 1% 0603 resistor` | Matching resistors |
| `datasheet for 42-1438-01E` | The IGT row + a Google search link for the manufacturer datasheet |
| `what is the clamping voltage of 48017191W` | A short prose answer using context from previous searches |
| `TVS diode SOT-23-6` | All TVS arrays in SOT-23-6 |

**Chat history is saved** — your previous conversations live in the
left sidebar. Click **+ New Chat** to start a fresh session.

---

## Common issues

### Red "Agent: not running" pill

- The PowerShell window from Step 1 was closed → run it again.
- Something else is using port 5005 → close other dev tools and retry.
- Your firewall blocked the listener → say "yes / allow" when Windows asks.

### "ExecutionPolicy" error when launching

The launcher uses `-ExecutionPolicy Bypass` internally so this should not
happen. If it does, AppLocker may be restricting your account — contact IT
or Eduard Kliger.

### "LLM: error — 401" pill

Your GitHub token has expired or doesn't have the **Models: Read-only**
permission. Regenerate it (Step 3) and paste the new one into `.env`.

### "LLM: error — Unable to connect to the remote server"

Corporate firewall blocked outbound HTTPS to GitHub Models at that moment.
The search itself still works (rule-based mode). Try again in a few seconds
or restart the agent.

### I never get a "datasheet hint" box

The hint requires either (a) a working GitHub token, or (b) you typed
something with the word `datasheet` / `data sheet` / `specs`. The agent
will produce a Google search link as a fallback even when AI is unavailable.

---

## Updating

Run `Start-DatabookAgent.ps1` from the shared folder again. It
automatically pulls the newest agent files into `%LOCALAPPDATA%\DatabookAgent\`
before launching. Your `.env` is never overwritten.

---

## Stopping

Close the blue PowerShell window. That's it.

---

## Privacy / security

- The agent listens only on `localhost` (not on your network).
- It connects to DxDatabook using **your** Windows credentials,
  read-only, SELECT statements only.
- It only accepts requests from:
  `https://everi-elect-hardware.github.io`, `http://localhost`,
  `http://127.0.0.1`.
- Your GitHub token (if you add one) never leaves your PC except in
  outbound calls to `models.github.ai`.
- No telemetry. No logs are uploaded anywhere.

---

## Contact

Eduard Kliger — Hardware Engineering
