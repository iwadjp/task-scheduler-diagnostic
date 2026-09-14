# Task Scheduler Diagnostic (bounded prototype)

A single PowerShell script that collects the information you'd normally gather
by hand across Task Scheduler's GUI, Properties dialog, and Event Viewer, and
checks it against a small set of known result codes and deterministic rules.

This is a **bounded prototype**, not a product. No installer, no GUI, no
background service, no telemetry, no network calls.

## What it does

Given a scheduled task name, it collects:

- Last run result and task state
- Principal (logon type, run level, user)
- Action (executable, arguments, working directory)
- Triggers
- The relevant Task Scheduler Operational event log entries, if that log is enabled

...and checks that information against ~18 known Task Scheduler result codes
and 7 deterministic rules (logon-type dependency, missing/nonexistent working
directory, nonexistent executable path, RunLevel/UAC mismatch, disabled task,
future-only triggers, disabled event log). It prints a short, structured
summary: what likely went wrong, what to check first, and the evidence behind
that conclusion.

No AI/LLM is used. Every conclusion comes from an explicit rule match; if
nothing matches, it says so instead of guessing.

## Why

A task that fails silently under the Task Scheduler service (but runs fine
when you run the same command by hand) normally means: open Task Scheduler,
find the task, read a cryptic "Last Run Result" code, open Properties to check
the logon/run-level settings, open the Actions tab to eyeball the paths, then
go dig through Event Viewer (which is often disabled by default and has to be
turned on first). This script collects and cross-checks all of that in one
command.

## Requirements

- Windows with PowerShell 5.1 or later
- `Get-ScheduledTask` / `Get-ScheduledTaskInfo` (built into Windows; no
  modules to install)
- Reading some tasks (e.g. tasks owned by another account, or system tasks)
  may require an elevated ("Run as Administrator") PowerShell session
- Reading the Task Scheduler Operational event log requires that log to be
  enabled; if it isn't, the script tells you the exact command to enable it
  instead of changing anything itself

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\diagnose-task.ps1 -TaskName "<Scheduled Task Name>"
```

Running it with no `-TaskName` prints usage instead of doing anything:

```powershell
.\diagnose-task.ps1
```

```
Usage:
  powershell -ExecutionPolicy Bypass -File .\diagnose-task.ps1 -TaskName "<Scheduled Task Name>"

Example:
  .\diagnose-task.ps1 -TaskName "MyBackupTask"

Tip: run 'Get-ScheduledTask | Select-Object TaskName' to list task names on this machine.
```

## Example: failed task

```powershell
.\diagnose-task.ps1 -TaskName "MyBackupTask"
```

```
Task:
MyBackupTask

Status:
FAILED

Last result:
2147946720 (0x800710E0)

Likely issue:
The operator or administrator has refused the request.

Relevant configuration:
LogonType = Interactive; RunLevel = Limited; UserId = someuser

Check first:
- This task may require an interactive user session (see LogonType below); it can also
  occur when a policy or the account's session state prevented the task from starting.
- LogonType = Interactive: this task is configured to run only while the specified user
  (someuser) has an active interactive logon session. If the machine was logged out, locked
  past a policy limit, or the user was not signed in at the scheduled time, the task will
  not run or will fail immediately.

Evidence:
- LastTaskResult = 2147946720 (0x800710E0)
- Principal: LogonType=Interactive, RunLevel=Limited, UserId=someuser
- Action: Execute='powershell.exe', Arguments='-NoProfile -File C:\Scripts\backup.ps1', WorkingDirectory='C:\Scripts'
- Task State: Ready
- Event Viewer log 'Microsoft-Windows-TaskScheduler/Operational' is currently DISABLED.
  To enable it (requires admin PowerShell): wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true
```

This example is based on a real dogfood run (task name, paths, and username
generalized): a task that only runs while its owning account is interactively
logged on failed silently under the scheduler with `0x800710E0`. The script
surfaces the logon-type dependency directly, instead of requiring a search
for what that code means.

## Example: successful task

```powershell
.\diagnose-task.ps1 -TaskName "MyUpdaterTask"
```

```
Task:
MyUpdaterTask

Status:
SUCCESS

Last result:
0 (0x00000000)

Likely issue:
The operation completed successfully.

Relevant configuration:
LogonType = Interactive; RunLevel = Limited; UserId = someuser

Evidence:
- LastTaskResult = 0 (0x00000000)
- Principal: LogonType=Interactive, RunLevel=Limited, UserId=someuser
- Action: Execute='%localappdata%\Vendor\Updater.exe', Arguments='', WorkingDirectory=''
- Task State: Ready
- Event Viewer log 'Microsoft-Windows-TaskScheduler/Operational' is currently DISABLED.
  To enable it (requires admin PowerShell): wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true
```

Successful tasks are reported cleanly, with no spurious "Check first" warnings
even when the executable path uses an environment variable (e.g.
`%localappdata%\...`) — that path is expanded before being checked for
existence, and the logon/working-directory/exe-path/RunLevel hints are only
shown for tasks that did not succeed.

## What it checks

**Known result codes (~18, intentionally small — not a general HRESULT dictionary):**
`0x0`, `0x1`, `0x2`, `0x10`, `0x41300`–`0x41306` (task state codes),
`0x8004131F` (already running), `0x800704DD` (no logon session),
`0x80070005` (access denied), `0x8007010B` (bad working directory),
`0x80070002` / `0x80070003` (bad executable/script path),
`0x800710E0` (operator/administrator refused the request),
`0xC000013A` (terminated by Ctrl+C-like signal).

**Deterministic rules (7):**
1. Known result code lookup
2. `LogonType = Interactive` dependency warning
3. Working directory not set / does not exist
4. Executable path does not exist (after environment-variable expansion)
5. `RunLevel = Highest` combined with `LogonType = Interactive` (possible UAC mismatch)
6. Task is Disabled
7. All triggers are in the future and the task has never run

Any result code or situation outside this list is reported as
`"No known rule matched"` / `"No rule-based explanation available"` rather
than a guess.

## Limitations

- This does **not** diagnose every possible Task Scheduler failure. The
  known-code table and rule set are intentionally small.
- Unknown result codes are reported as unknown, not guessed at.
- If the Task Scheduler Operational event log is disabled on the machine, no
  event-log evidence is available; the script prints the exact command to
  enable it but does not run it for you.
- The event-log task-name match is a simple substring match against the most
  recent 5 log entries, not a timestamp-correlated match against the specific
  failed run.
- The "Check first" hints (e.g. LogonType, RunLevel) are phrased as
  hypotheses ("may require", "can also occur"), not confirmed root causes.
- Environment-dependent problems (network drives, per-machine account setup,
  etc.) can still require manual investigation beyond what this script surfaces.

## Privacy

This script is entirely local and read-only. It makes no network requests,
sends no data anywhere, and does not modify any task, service, registry key,
or event log setting. It only reads Task Scheduler configuration and (if
already enabled) the Task Scheduler Operational event log on the machine it
runs on.
