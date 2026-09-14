#Requires -Version 5.1
<#
.SYNOPSIS
  One-shot diagnostic snapshot for a Windows Scheduled Task (bounded prototype, read-only).

.DESCRIPTION
  Collects task definition, last-run result, principal/logon context, and (if available)
  the Task Scheduler Operational event log for one task, then applies a small set of
  deterministic rule checks to surface a likely cause. No LLM/AI is used. No system
  state is changed by this script (it only reads).

.PARAMETER TaskName
  The Scheduled Task name (as shown in Task Scheduler / Get-ScheduledTask), e.g.
  "MyBackupTask".

.EXAMPLE
  .\diagnose-task.ps1 -TaskName "MyBackupTask"
#>

param(
    [string]$TaskName
)

if (-not $TaskName) {
    Write-Output "Usage:"
    Write-Output "  powershell -ExecutionPolicy Bypass -File .\diagnose-task.ps1 -TaskName ""<Scheduled Task Name>"""
    Write-Output ""
    Write-Output "Example:"
    Write-Output "  .\diagnose-task.ps1 -TaskName ""MyBackupTask"""
    Write-Output ""
    Write-Output "Tip: run 'Get-ScheduledTask | Select-Object TaskName' to list task names on this machine."
    exit 1
}

# ---------------------------------------------------------------------------
# Known HRESULT / Task Scheduler result codes (small, curated set — not a
# general HRESULT dictionary). Each entry is only included because it is a
# documented / commonly-cited Task Scheduler result code.
# ---------------------------------------------------------------------------
$KnownResultCodes = @{
    '0x0'        = 'The operation completed successfully.'
    '0x1'        = 'Incorrect function called or unknown function called.'
    '0x2'        = 'File not found.'
    '0x10'       = 'The environment is incorrect.'
    '0x41300'    = 'Task is ready to run at its next scheduled time.'
    '0x41301'    = 'Task is currently running.'
    '0x41302'    = 'Task is disabled.'
    '0x41303'    = 'Task has not yet run.'
    '0x41304'    = 'There are no more runs scheduled for this task.'
    '0x41306'    = 'Task was terminated by the user.'
    '0x8004131F' = 'An instance of this task is already running.'
    '0x800704DD' = 'The service is not available (logon session does not exist / user not logged on).'
    '0x80070005' = 'Access is denied.'
    '0x8007010B' = 'The directory name is invalid (bad working directory).'
    '0x80070002' = 'The system cannot find the file specified (bad executable/script path).'
    '0x80070003' = 'The system cannot find the path specified.'
    '0x800710E0' = 'The operator or administrator has refused the request.'
    '0xC000013A' = 'The application terminated as a result of a CTRL+C or similar.'
}

function ConvertTo-HresultHex {
    param([Parameter(Mandatory = $true)][long]$Value)
    # LastTaskResult comes back as an unsigned/decimal DWORD; normalize to 0xHHHHHHHH.
    $u = [uint32]([int64]$Value -band 0xFFFFFFFF)
    return ('0x{0:X8}' -f $u)
}

function Get-KnownCodeExplanation {
    param([string]$HexCode)
    $target = [uint32]$HexCode
    foreach ($key in $KnownResultCodes.Keys) {
        if ([uint32]$key -eq $target) {
            return $KnownResultCodes[$key]
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Collect
# ---------------------------------------------------------------------------
$evidence = New-Object System.Collections.Generic.List[string]
$checkFirst = New-Object System.Collections.Generic.List[string]
$likelyIssues = New-Object System.Collections.Generic.List[string]

try {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
} catch {
    $msg = $_.Exception.Message
    Write-Output "Task:`n$TaskName`n"
    Write-Output "Status:`nNOT FOUND OR NOT ACCESSIBLE"
    if ($msg -match 'Access is denied|denied') {
        Write-Output "`nLikely issue:`nAccess was denied while querying this task. Some tasks (e.g. those registered under a different account, or system tasks) require running this script from an elevated (Run as Administrator) PowerShell session."
    } else {
        Write-Output "`nLikely issue:`nNo scheduled task with this exact name was found on this machine. Task names are case-sensitive-ish and must match exactly (folders in Task Scheduler are not included automatically)."
        Write-Output "`nCheck first:`n- Run 'Get-ScheduledTask | Select-Object TaskName' to list available task names."
    }
    Write-Output "`nEvidence:`n- Get-ScheduledTask error: $msg"
    exit 1
}

try {
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
} catch {
    $info = $null
    $evidence.Add("Get-ScheduledTaskInfo failed: $($_.Exception.Message)")
}

$principal = $task.Principal
$action = $task.Actions | Select-Object -First 1
$triggers = $task.Triggers

$lastResultRaw = if ($info) { $info.LastTaskResult } else { $null }
$lastResultHex = if ($null -ne $lastResultRaw) { ConvertTo-HresultHex -Value $lastResultRaw } else { 'N/A' }
$lastResultKnown = if ($lastResultHex -ne 'N/A') { Get-KnownCodeExplanation -HexCode $lastResultHex } else { $null }

$logonType = if ($principal) { $principal.LogonType } else { 'N/A' }
$runLevel = if ($principal) { $principal.RunLevel } else { 'N/A' }
$userId = if ($principal) { $principal.UserId } else { 'N/A' }
$exe = if ($action) { $action.Execute } else { 'N/A' }
$args = if ($action -and $action.Arguments) { $action.Arguments } else { '' }
$workDir = if ($action -and $action.WorkingDirectory) { $action.WorkingDirectory } else { $null }

$evidence.Add("LastTaskResult = $lastResultRaw ($lastResultHex)")
$evidence.Add("Principal: LogonType=$logonType, RunLevel=$runLevel, UserId=$userId")
$evidence.Add("Action: Execute='$exe', Arguments='$args', WorkingDirectory='$workDir'")
$evidence.Add("Task State: $($task.State)")

# ---------------------------------------------------------------------------
# Event log (best-effort, never fatal)
# ---------------------------------------------------------------------------
$eventLogNote = $null
try {
    $log = Get-WinEvent -ListLog 'Microsoft-Windows-TaskScheduler/Operational' -ErrorAction Stop
    if (-not $log.IsEnabled) {
        $eventLogNote = "Event Viewer log 'Microsoft-Windows-TaskScheduler/Operational' is currently DISABLED. To enable it (requires admin PowerShell): wevtutil sl Microsoft-Windows-TaskScheduler/Operational /e:true"
    } else {
        try {
            $events = Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 5 -ErrorAction Stop |
                Where-Object { $_.Message -match [regex]::Escape($TaskName) }
            if ($events) {
                foreach ($e in $events) {
                    $evidence.Add("EventLog [$($e.TimeCreated)] Id=$($e.Id): $($e.Message.Split("`n")[0])")
                }
            } else {
                $eventLogNote = "Event log is enabled but no recent entries matched task name '$TaskName' in the last 5 records checked."
            }
        } catch {
            $eventLogNote = "Event log is enabled but could not be read: $($_.Exception.Message)"
        }
    }
} catch {
    $eventLogNote = "Could not query the Task Scheduler Operational log (may require admin rights or the log may not exist): $($_.Exception.Message)"
}
if ($eventLogNote) { $evidence.Add($eventLogNote) }

# ---------------------------------------------------------------------------
# Deterministic rule checks (no LLM). Each rule only fires on an explicit
# condition match; anything not matched is left unstated rather than guessed.
# ---------------------------------------------------------------------------

# Rule: known result code
if ($lastResultKnown) {
    $likelyIssues.Add($lastResultKnown)
    if ($lastResultHex -eq '0x800710E0') {
        $checkFirst.Add("This task may require an interactive user session (see LogonType below); it can also occur when a policy or the account's session state prevented the task from starting.")
    }
} elseif ($lastResultHex -ne 'N/A' -and $lastResultHex -ne '0x0') {
    $likelyIssues.Add("Result code $lastResultHex is not in this prototype's known-code list (kept intentionally small). No rule-based explanation available.")
}

# Rules below are diagnostic hints for a task that did NOT succeed. For a task that already
# succeeded (status SUCCESS), surfacing these as "check first" items would be noise/false alarm,
# so they are only added when the task is not a confirmed success.
$taskAlreadySucceeded = ($lastResultRaw -eq 0)

# Rule: LogonType Interactive
if ($logonType -eq 'Interactive' -and -not $taskAlreadySucceeded) {
    $checkFirst.Add("LogonType = Interactive: this task is configured to run only while the specified user ($userId) has an active interactive logon session. If the machine was logged out, locked past a policy limit, or the user was not signed in at the scheduled time, the task will not run or will fail immediately.")
}

# Rule: working directory missing / not set
if (-not $taskAlreadySucceeded) {
    if (-not $workDir) {
        $checkFirst.Add("Working directory is not set on the task action. If the script/executable relies on relative paths, this can cause file-not-found failures.")
    } elseif (-not (Test-Path $workDir)) {
        $checkFirst.Add("Working directory '$workDir' does not currently exist on this machine.")
    }
}

# Rule: executable path existence (best-effort; skip for bare command names resolvable via PATH)
# Environment variables (%VAR%) are expanded first, since Test-Path does not expand them
# and an un-expanded check would falsely report an existing file as missing.
$exeExpanded = if ($exe) { [System.Environment]::ExpandEnvironmentVariables($exe) } else { $exe }
if (-not $taskAlreadySucceeded -and $exeExpanded -and ($exeExpanded -match '[\\/]') -and (-not (Test-Path $exeExpanded))) {
    $checkFirst.Add("Executable path '$exe' (resolved: '$exeExpanded') does not currently exist on this machine.")
}

# Rule: RunLevel HighestAvailable but principal is a standard/limited context
if (-not $taskAlreadySucceeded -and $runLevel -eq 'Highest' -and $logonType -eq 'Interactive') {
    $checkFirst.Add("RunLevel = Highest combined with an Interactive logon type means the task needs UAC elevation available at run time; if the interactive session was not elevated, the task may silently fail.")
}

# Rule: task disabled
if ($task.State -eq 'Disabled') {
    $likelyIssues.Add("The task itself is currently Disabled in Task Scheduler.")
}

# Rule: trigger never fired / all triggers in the future
if ($triggers -and $info) {
    $allFuture = $true
    foreach ($trg in $triggers) {
        if ($trg.StartBoundary) {
            try {
                $start = [datetime]$trg.StartBoundary
                if ($start -le (Get-Date)) { $allFuture = $false }
            } catch { $allFuture = $false }
        } else {
            $allFuture = $false
        }
    }
    if ($allFuture -and (-not $info.LastRunTime -or $info.LastRunTime -eq [datetime]'1999-11-30')) {
        $checkFirst.Add("All triggers have start boundaries in the future and the task has no recorded last run — it may simply not have fired yet.")
    }
}

if ($likelyIssues.Count -eq 0) {
    $likelyIssues.Add("No known rule matched. Manual investigation is required (this prototype's rule set is intentionally small).")
}

# ---------------------------------------------------------------------------
# Output (short, structured; no raw log dump)
# ---------------------------------------------------------------------------
$status = if ($lastResultRaw -eq 0) { 'SUCCESS' } elseif ($null -eq $lastResultRaw) { 'UNKNOWN' } else { 'FAILED' }

Write-Output "Task:`n$TaskName`n"
Write-Output "Status:`n$status`n"
Write-Output "Last result:`n$lastResultRaw ($lastResultHex)`n"
Write-Output "Likely issue:`n$($likelyIssues -join '; ')`n"
Write-Output "Relevant configuration:`nLogonType = $logonType; RunLevel = $runLevel; UserId = $userId`n"
if ($checkFirst.Count -gt 0) {
    Write-Output "Check first:"
    $checkFirst | ForEach-Object { Write-Output "- $_" }
    Write-Output ""
}
Write-Output "Evidence:"
$evidence | ForEach-Object { Write-Output "- $_" }
