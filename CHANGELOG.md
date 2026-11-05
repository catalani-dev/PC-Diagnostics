# Changelog

## 1.2.0

Found by checking a real report from a notebook with modern standby (S0 Low Power Idle) that did not wake up and was switched off by holding the power button, and that had also turned off twice with a flat battery.

### Fixed
- **Failed wake-ups from modern standby are no longer reported as power problems.** A Kernel-Power 41 with `ConnectedStandbyInProgress = true` was reported as "sudden shutdown during sleep: power loss, flat battery…" and triggered the advice "check the battery and the charger". It is now classified as *Failed wake-up from modern standby* (the screen stays black when the power button is pressed and the computer is switched off by hand). These cases no longer count towards the power-supply advice or the shutdowns forced with the power button (a long press is handled by the firmware and Windows often does not record it). A computer whose last battery reading was on battery at 10% or less is reported as a flat battery instead.
- **Power-offs with a flat battery are recognised.** A power-off without a blue screen whose last battery reading was on battery at 10% or less is classified as *Flat battery* instead of "sudden shutdown: power loss, flat battery, freeze or forced shutdown". It gets its own action, which also reports the critical battery action and level of the active power plan, and no longer counts towards the generic power-supply advice or towards "crashes happen mostly at startup or wake-up".

### Added
- Section 6 has a *Last battery reading* column on computers with a battery: charge, charger connected or not, and time of the reading before each crash.
- The standby in progress is confirmed with `CsEntryScenarioInstanceIdV2`: entry into standby (Kernel-Power 506 with the same id), missing exit (no 507 before the next boot) and the 566 that ended its first session. The report shows when the standby began and that it never ended.
- New action for failed wake-ups: update the BIOS and the chipset, graphics and Wi-Fi drivers from the manufacturer, try Win+Ctrl+Shift+B on a black screen, check `powercfg /sleepstudy`. On computers with modern standby the sleep study of the last 14 days is saved as `data\sleepstudy.html`.
- Section 8 shows the number of failed wake-ups from modern standby on computers that use it.
- `crashes.csv`: new columns for modern standby (in progress, scenario id, start, entry reason, exit logged, end of the first session), lid state, long power-button press, and the last battery reading before each crash (charge, time of the reading and charger connected).
- New data file `firmware_boot_times.csv`: firmware boot time of each startup (Kernel-Boot 30 `LoadOSImageStart`, boot type from Kernel-Boot 27), its ratio to the median of the period, and the ones at least 1.8 times the median marked as slow.

## 1.1.0

Fixes found by checking a real report against 16 months of event logs from a desktop PC with Fast Startup and hybrid sleep.

### Fixed
- **Event log queries no longer lose events.** An event whose text Windows cannot format (for example an unresolvable `%%` insert in a Service Control Manager event on Windows 10) stopped the whole query: older events were silently dropped, service errors were undercounted and the System log was wrongly reported as "not readable", turning Disk, RAM and Drivers into *Uncertain*. Events are now read with `EventLogReader`: such events are kept (their data stands in for the text) and only real read failures mark a log as incomplete.
- **Kernel-Power 41 events are classified correctly.** `SleepInProgress` is a power state, not a yes/no flag: the value 6 (shutdown) was reported as "during sleep or wake-up" and triggered the advice "crashes happen mostly at startup or wake-up". Shutdowns with Fast Startup whose saved session could not be resumed at the next power-on (`BootAppStatus`, Kernel-Boot 29/20) are now reported apart and not counted as crashes; the other events are labelled while running, during sleep, during shutdown or failed resume.
- **Crash times are shown as a window.** The time in event 6008 is only a periodic stamp (often the start of the session), not the crash time. The report now shows the window between the last sign of life (6008 stamp, last System or Application event) and the next startup, and says "within 5 minutes of startup" only when the whole session was that short.
- **Wake-up times.** Kernel-Power 107 carries the time the computer went to sleep, so it is no longer used as a wake-up time; Power-Troubleshooter 1 and the exit from Modern Standby (Kernel-Power 507) are used instead.
- Power-button presses that started a sleep or a normal shutdown are no longer reported as forced power-offs.
- A blue screen while Windows is shutting down is reported as such, not as "during use".
- On desktops, "flat battery" is no longer listed as a possible cause.
- **ZIP archive:** a file briefly locked by antivirus or cloud sync no longer makes the archive hang for many minutes or come out incomplete: Compress-Archive is retried, and the Windows zip folder fallback waits for locked files and, if one stays locked, leaves out only that file and records it in the `run_log.txt` inside the archive.

### Added
- **Sleeps interrupted and resumed from disk.** With hybrid sleep, a power loss while asleep leaves no crash event: Windows resumes from the hibernation file. These cases are now detected (Power-Troubleshooter 1 / Kernel-Boot 27; intended hibernation and the hibernate-after timer are excluded), listed in section 6 and counted in the Crashes verdict, with a power-supply action. One that ended with a power-on shortly before the diagnosis is marked, since the PC is often unplugged to bring it in for service.
- **Live kernel reports decoded.** Stop code and parameter are read from the dump header or from the WER report, so reports already moved by WER are counted too. USB enumeration failures (0x144 / 0x3003) get a *USB devices* verdict and the last unrecognised USB device is shown; graphics timeouts are recognised by stop code.
- New data files: `sleep_resumed_from_disk.csv`, `live_kernel_reports.csv`; more columns in `crashes.csv` (phase, boot status, last sign of life and its source, time bounds).
- `run_log.txt` lists separately the queries that failed and the events whose text could not be formatted.

## 1.0.0

First public release.
