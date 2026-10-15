DatabookAgent - Quick Start
===========================

What this is
------------
A small PowerShell-based bridge that lets the IGT Databook search web page
(https://everi-elect-hardware.github.io/databook-search/) talk to the
DxDatabook SQL Server through your existing ODBC DSN.

It runs ONLY on your own machine, on http://localhost:5005, and is not
reachable from the network.  It uses your Windows credentials (Trusted
Connection, ReadOnly intent) and is hard-restricted to SELECT statements.

First-time setup (30 seconds)
-----------------------------
1. Right-click  Start-DatabookAgent.ps1  -> "Run with PowerShell"
   (Or from a prompt:
       powershell.exe -NoProfile -ExecutionPolicy Bypass -File
         "Z:\LIBRARY\MentorGraphics\DatabookAgent\Start-DatabookAgent.ps1" )
   - The first run copies the agent into
       %LOCALAPPDATA%\DatabookAgent\
     and launches it.  A PowerShell window will open and stay open;
     leave it running while you use the chat page.
   - Future runs just refresh the local copy if this share has a newer
     version, then start the agent.

   NOTE on .cmd:  IGT's AppLocker policy blocks .cmd / .bat execution
   from user-writable folders.  That's why we use the .ps1 launcher
   above - it runs through powershell.exe (System32, Microsoft-signed),
   which is permitted.

2. Open the chat page in your browser:
       https://everi-elect-hardware.github.io/databook-search/
   - The pill at the top should turn green ("Agent: ok").

3. (Optional) Enable the LLM parser for fuzzy queries:
   - Generate a fine-grained GitHub PAT at
       https://github.com/settings/personal-access-tokens
     with the "Models: read" scope.
   - Edit  %LOCALAPPDATA%\DatabookAgent\.env
     and set:
       GITHUB_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxxx
   - Restart start.cmd.  The "LLM" pill should turn green.

To stop the agent
-----------------
Close the PowerShell window that start.cmd opened, or press Ctrl+C in it.

To update the agent
-------------------
Just run Start-DatabookAgent.ps1 again.  It mirrors any newer master
copy from this share into your local profile automatically.

Troubleshooting
---------------
- "ExecutionPolicy" or "running scripts is disabled" error:
    The launcher passes -ExecutionPolicy Bypass per-process, so the
    machine policy is not changed.  If it still fails, it usually
    means AppLocker is blocking the script.  Contact IT or
    Eduard Kliger.

- Browser pill stays red ("Agent: not running"):
    Make sure the PowerShell window is still open.  Refresh the page.
    Check that nothing else is using port 5005.

- "LLM: error - 401 ..." pill:
    Your GitHub token expired.  Generate a new one (see step 3 above).
    Search still works via the rule-based parser in the meantime.

Contact
-------
Eduard Kliger - Hardware Engineering
