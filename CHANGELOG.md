# Changelog

## 1.1.1 (2026-10-27)

- Apply protected process names and configured game names to both GPU-memory and explicit-target enforcement passes.
- Stop startup when an explicitly selected configuration is missing, or a configuration file is unreadable or invalid.
- Validate the complete configuration before changing settings, including process-list types, intervals, regular expressions and unknown fields. An absent optional default file still uses built-in settings.
- Correct version reporting, which previously collided with the `-Version` switch.
- Add mocked protection and configuration regressions, repair Pester setup and limit CI repository permissions to read-only.
- Document preview-first operation, browser termination, Steam detection, ffmpeg protection and the limits of executable-path restoration.

Windows GPU counters, scheduled-task sessions and restoration still require validation on the target machine. See [README.md](README.md) for operating requirements.
