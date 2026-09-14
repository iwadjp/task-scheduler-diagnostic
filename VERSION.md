# Version notes

## 0.1.0 (2026-09-14)

Initial bounded-prototype release.

- 18 known Task Scheduler result codes, 7 deterministic rules
- No AI/LLM, no network calls, read-only
- Dogfooded against 4 real scheduled tasks on a Windows machine (1 known
  failure, 2 successes, 1 unknown-code failure); two bugs found and fixed
  during that dogfood (hex string-vs-int comparison, unexpanded
  environment-variable path check) — see project history for details.

No versioning scheme beyond this is committed to yet; this is not a
packaged/distributed tool, just a script you clone or download and run.
