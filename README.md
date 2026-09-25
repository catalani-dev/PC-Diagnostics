# PC Diagnostics

**English** · [Italiano](README.it.md)

A single-file, read-only diagnostic tool for Windows PCs. Run it as administrator, pick an analysis, and a few minutes later you get a plain-language report, in English and Italian, that says what is wrong with the computer and what to do about it. It also creates a ZIP with all the raw data for a technician.

It is built for help desks and IT support. The person at the PC only has to run it and send back the ZIP. The report is written so that non-experts can read it too.

## Highlights

- **One file, nothing to install.** `PC-Diagnostics.bat` is a batch/PowerShell hybrid that runs on the Windows PowerShell already built into Windows.
- **Windows 7 SP1 to Windows 11** (Windows PowerShell 2.0 to 5.1). Newer commands are used only when they exist. Otherwise the tool falls back to WMI, the registry and classic command-line tools.
- **Read-only.** It does not change settings, drivers, registry keys or system files (see [What it changes and what it does not](#what-it-changes-and-what-it-does-not)).
- **Verdicts, not just data.** Every area gets a traffic-light result. When the data is not enough for a reliable judgement, the result is 🔵 *Uncertain* instead of a guess.
- **Explains crashes.** Blue-screen codes are translated into plain language with a probable cause (disk, memory, driver, graphics, power…) and the time of the crash relative to startup or wake-up.
- **Reports in two languages**, as HTML (opens in any browser, printable) and Markdown.

## What it checks

| Area | What is collected |
|---|---|
| Computer | Model, serial number, CPU, graphics, RAM, BIOS version and age, Windows edition and build, install date, last boot, Secure Boot, domain or workgroup, previous Windows versions. On HP computers, the relevant BIOS settings. |
| Disk / SSD | Health status, SMART failure prediction, temperature, wear, power-on hours, uncorrected read/write errors, free space, file system "dirty" flag, TRIM, Intel RST/VMD controller. Disk and NTFS errors from the event logs, attributed to the system disk or to other disks (USB sticks, memory cards). |
| Memory (RAM) | Installed modules, Windows Memory Diagnostic results, hardware memory errors (WHEA), low-memory events. |
| Crashes | Blue screens and abrupt shutdowns with decoded bug-check codes, shutdowns forced with the power button, crashes at startup, at wake-up or during sleep, mains power lost just before a crash, minidumps and live kernel reports, Windows Error Reporting, crash dump configuration problems, startup repair logs. |
| Programs, services, devices | Application crashes (most frequent programs), service failures, stopped automatic services, failed scheduled tasks, devices with errors in Device Manager, graphics driver timeouts (TDR), WHEA hardware errors. |
| Power and battery | Battery health (full charge capacity compared with design capacity), switches between mains and battery, maximum processor state of the power plan, Fast Startup, Windows battery report and energy report. |
| Performance and temperatures | CPU usage, frequency and BIOS-imposed limit, RAM use, disk activity, thermal zone temperatures and heat throttling, sampled every 5 seconds. Processes using the most memory. |
| Network | Adapters (IP, gateway, DNS), router and Internet reachability (ping and TCP port 443), name resolution, proxy settings, Wi-Fi, TCP/IP, DNS and DHCP errors in the logs. |
| Security | Antivirus products and definitions (Security Center, Microsoft Defender), Windows Firewall profiles (Group Policy aware) and third-party firewalls, BitLocker, TPM, pending restart, failed sign-in attempts by type. |
| Updates and software | Installed Windows updates, failed updates that are still missing, days since the last update, Windows Update service state, recently installed programs, startup programs. |

Event logs are analysed over the **last 60 days**, or from the start of the log when it covers a shorter period. In that case the report states the real period.

## Requirements

- Windows 7 SP1, 8, 8.1, 10 or 11
- Windows PowerShell 2.0 or later (built into all these versions)
- An **administrator** account: many logs and hardware counters can only be read with elevation

## Quick start

1. Download `PC-Diagnostics.bat` from the [latest release](../../releases/latest), or open the file in this repository and click **Download raw file**.
2. If Windows blocks the file because it came from the Internet: right-click it > **Properties** > tick **Unblock** > **OK**.
3. Right-click `PC-Diagnostics.bat` > **Run as administrator**.
4. Confirm the detected operating system with **Enter**, or choose another one.
5. Choose the analysis and press **Enter**:

   | Analysis | Duration | What it does |
   |---|---|---|
   | **Normal** | about 5 minutes | All the standard checks. |
   | **Stress** | about 12 minutes | Standard checks plus the processor at 100% for 10 minutes, to test cooling and power supply. Save your work and connect the charger first. Asks for confirmation (Y/N). |
   | **DeepScan** | up to 20 minutes | Standard checks plus a read-only check of the Windows system files (`sfc /verifyonly`) and of the disk file system (`chkdsk` without repair options). |

   Menu keys: **↑ / ↓** move · **number keys** select · **Enter** confirm · **Esc** exit.

6. At the end the console shows a summary and the results folder opens. Double-click `REPORT_EN.html` (or `REPORT_IT.html`) to read the report.

The window can be minimised while the analysis runs. The computer does not go to sleep until the end, and a click inside the window does not pause the program.

### Which operating system to choose

| Choice | Methods used |
|---|---|
| Windows 7 | Compatible methods only (WMI, registry, classic commands). Works with PowerShell 2.0. It can also be chosen on newer systems to force compatibility mode. |
| Windows 8 / 8.1 | Compatible methods plus the newer Windows 8 commands when they are available. |
| Windows 10 / 11 | All checks, including the disk health counters and the Defender status, which need the newer commands. |

## Output

The results are saved on the Desktop of the signed-in user, even when the administrator rights come from a different account. If the Desktop is not writable, they go to `C:\PC-Diagnosis`.

```text
PC-Diagnosis_<COMPUTER>_<yyyyMMdd_HHmmss>\
├── REPORT_EN.html / REPORT_IT.html        the report (double-click to open it in the browser)
├── REPORT_EN.md   / REPORT_IT.md          the same report in Markdown
├── run_log.txt                            execution log
├── data\                                  raw data: CSV files, event logs (.evtx), crash dumps,
│                                          error reports, battery and energy reports, sfc/chkdsk output
└── PC-Diagnosis_<COMPUTER>_<...>.zip      everything above, ready to send to support
```

The report has 13 sections: summary, what to do, the computer, disk and space, memory, crashes and unexpected restarts, programs/services/devices, power and battery, performance and temperatures, network, security, updates and software, limits of the analysis.

| Report | Console | Meaning |
|---|---|---|
| 🟢 OK | `OK` | No problem found. |
| 🟡 Check | `CHECK` | Something to keep an eye on. |
| 🔴 Problem | `PROBLEM` | Needs fixing. |
| 🔵 Uncertain | `UNSURE` | The data is not enough for a reliable judgement. The details explain why and what to verify. |
| ⚪ Not assessed | `N/A` | The information is not available on this computer. |

> [!WARNING]
> The report and the ZIP contain identifying and sensitive information: computer name, serial number, IP addresses, installed software, event logs and crash dumps (which can contain fragments of memory). Share them only with the people who support the computer.

## Command line and unattended use

From a Command Prompt opened as administrator, pass the analysis as the first argument to skip the menus:

```bat
PC-Diagnostics.bat normal|stress|deepscan [win7|win8|win10|win11] [quick]
```

| Argument | Meaning |
|---|---|
| `normal`, `stress`, `deepscan` | Analysis to run. Required for unattended mode. |
| `win7`, `win8`, `win10`, `win11` | Profile to use. The default is the detected system. `win7` forces the compatible methods on any version. |
| `quick` | Short test run: 15-second sampling and no energy report. |

Optional environment variables:

| Variable | Effect |
|---|---|
| `DIAG_OUT` | Folder where the results folder is created (tried before the Desktop). |
| `DIAG_SAMPLE` | Length of the performance sampling in seconds (default 120, or 600 in Stress). Ignored with `quick`. |
| `DIAG_SKIPENERGY=1` | Skips the 60-second energy report. |

Examples:

```bat
PC-Diagnostics.bat deepscan
PC-Diagnostics.bat normal win7
set DIAG_OUT=D:\Diagnostics
PC-Diagnostics.bat normal
```

In unattended mode nothing is asked: **Stress starts without confirmation**, and the results folder is not opened at the end. When the script runs as SYSTEM, for example from a remote management tool, set `DIAG_OUT` so that the results end up in a known folder.

## What it changes and what it does not

The tool does not change settings, drivers, services, registry keys or system files, and it never repairs anything: `chkdsk` runs without `/f` and `sfc` with `/verifyonly`. When a repair is needed, the report says which command to run.

While it runs, it only:

- writes the results folder (plus temporary files in `%TEMP%`, deleted at the end);
- stops the computer and the screen from going to sleep, and disables QuickEdit in its own console window so that a click cannot pause the program; both are restored at the end;
- runs `powercfg /energy` (a 60-second trace) and `powercfg /batteryreport`;
- in Stress mode, loads every processor thread for 10 minutes.

Network traffic is limited to the connectivity test: two pings to the default gateway and two to `1.1.1.1`, a DNS lookup of `www.microsoft.com`, and a connection attempt on TCP port 443 (HTTPS) to `www.microsoft.com` or `1.1.1.1`. **No data is sent anywhere:** the results stay on the computer until you share them.

`-ExecutionPolicy Bypass` applies only to the PowerShell process started by the script. The system execution policy is not changed, and a policy set by Group Policy still takes precedence.

## How it works

`PC-Diagnostics.bat` is a batch/PowerShell polyglot. `cmd.exe` ignores the first line, while PowerShell reads it as the start of a comment block that hides the batch commands. The batch part starts Windows PowerShell (the 64-bit version through `Sysnative`, even when the script is started from a 32-bit process), which reads the same file and runs the PowerShell code. The whole tool stays in one plain-text file that can be read before running it.

Some antivirus products are suspicious of scripts that start PowerShell this way. The code is all in the file: read it before running it.

## Limitations

- The checks are automatic and based on what Windows records. They show where to look, but they do not replace a physical inspection or the manufacturer's hardware tests.
- Temperatures and some disk counters depend on what the hardware exposes. Many computers do not report the real processor temperature to Windows, and a high reading that never changes is reported as uncertain.
- Without Stress, temperatures are measured under little load and have limited significance.
- A read-only `chkdsk` of the volume in use can report errors that are not real. The report marks them as uncertain unless other evidence confirms them.
- The output of some Windows tools (`sfc`, `chkdsk`, `fsutil`) is recognised in English and Italian. With other display languages these results may appear as uncertain or not available.

## Contributing

Issues and pull requests are welcome. Before changing the script:

- The code must parse and run on **Windows PowerShell 2.0 / .NET 3.5**: no `-in`/`-notin`, `-shl`/`-shr`, `[ordered]`, `[pscustomobject]`, `::new()`, `Where-Object Name` short syntax, `-File`/`-Directory`/`-Raw` or .NET 4 APIs. Newer cmdlets are used only after checking that they exist (function `Has`).
- The code runs inside a script block: do not use `$script:` variables, and do not reuse the variable names read by the helper functions (`$raw`, `$out`, `$log`, `$R`, `$Verdicts`, `$Actions`) inside the steps.
- Save the file as **UTF-8 without BOM** with **CRLF** line endings, otherwise the batch header stops working. The repository's `.gitattributes` keeps Git from converting it.
- The tool must stay read-only.
- Test on as many Windows versions as possible, at least with `PC-Diagnostics.bat normal quick`.

When you report a problem, attach `run_log.txt` from the results folder, after checking it for anything you do not want to share.

## License

Released under the [MIT License](LICENSE).

The software is provided "as is", without warranty of any kind. Stress mode keeps the processor at full load for 10 minutes: use it only on computers you are responsible for, with open work saved.
