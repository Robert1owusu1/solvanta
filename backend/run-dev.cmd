@echo off
rem ---------------------------------------------------------------------------
rem  Starts the backend even under PowerShell's default "Restricted" execution
rem  policy, which refuses to load run-dev.ps1 directly on this machine.
rem
rem      run-dev.cmd
rem
rem  Copy .env.example to .env.ps1 first if you want PostgreSQL persistence;
rem  without it the server runs on the in-memory store.
rem ---------------------------------------------------------------------------
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-dev.ps1" %*
