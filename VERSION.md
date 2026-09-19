# Version notes

## 0.1.0

First tagged release.

- 18 known Task Scheduler result codes, 7 deterministic rules, no AI/LLM,
  no network calls, read-only.
- `Status` is one of `SUCCESS`, `INFO`, `FAILED`, `UNKNOWN`. The
  `0x41300`-`0x41306` task-state/info codes (ready/running/disabled/
  not-yet-run/no-more-runs/not-scheduled/terminated-by-user) are reported
  as `INFO`, not `FAILED` — none of them mean the last run actually failed.
  The "Check first" troubleshooting hints are only shown for `FAILED`, so
  they never appear alongside a non-failure status.
- `-TaskPath` parameter added. Task names are only unique within a Task
  Scheduler folder; if `-TaskName` matches tasks in more than one folder,
  the script lists the matches and stops instead of guessing.
- `WorkingDirectory` existence is checked the same way as the executable
  path: `%VAR%`-style environment variables are expanded first, and an
  environment variable this machine cannot resolve is reported as
  indeterminate rather than assumed missing.
- UNC paths (`\\server\share\...`) are excluded from existence checks, so
  the script never attempts a network call while checking path existence.
  This does not extend to mapped network drives (e.g. `Z:\...`), which are
  indistinguishable from local paths to this script.
- Dogfooded against several real scheduled tasks on a Windows machine,
  covering success, failure (known and unknown result codes), and
  info-status cases.

No versioning scheme beyond this is committed to yet; this is not a
packaged/distributed tool, just a script you clone or download and run.
