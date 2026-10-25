# System monitor

English | [简体中文](../zh-CN/product/system-monitor.md)

Monitoring is an independent read-only workspace task. It retains the top navigation and full-window teal-to-ice-blue background. Two rows of eight resource panels include readings and short trends above a full-width process list. No invented health score, temperature or energy reading appears.

## Metrics and accounting

| Metric | macOS | Windows |
| --- | --- | --- |
| CPU | Mach per-logical-core tick deltas, averaged for the machine | GetSystemTimes for one processor group; complete PDH logical-core averages across multiple groups; PDH per-core readings |
| GPU | Maximum readable IOAccelerator device utilization | PDH contributions grouped by physical engine; busiest engine, never a sum of unrelated engines |
| Memory | Physical total minus free and inactive; compressed pages, swap and pressure observed separately | Physical total minus available; compressed memory, swap and pressure remain unavailable when the supported API has no fact; commit is never substituted for swap |
| Disk | System-volume capacity/available space; IOBlockStorageDriver cumulative-byte deltas | System-volume capacity/available space; PDH PhysicalDisk raw cumulative-byte deltas excluding `_Total` |
| Network | Active numeric `en` interfaces, excluding loopback and tunnels | Active Ethernet/Wi-Fi; virtual adapters classified as Ethernet may be included |
| Battery | IOPS charge/power; readable AppleSmartBattery raw-capacity ratio and cycles | GetSystemPowerStatus charge/power; health/cycles unavailable without a reliable source |
| Temperature/fans | Fixed read-only AppleSMC requests and identified chip sensors; readable-sensor average, actual RPM and separate system thermal state | Supported read-only APIs provide no universal CPU/GPU temperature or fan source; unavailable, with no driver installation or elevation |
| Resource status | CPU or memory at 90% marks high usage; serious/critical Mac thermal state also marks high usage. Missing load, failure or pause is incomplete observation | Same load rule; this is not a hardware-health diagnosis |

Missing batteries, permissions, unsupported counters, unknown chips and invalid sensors remain missing. The UI displays `—` with nearby reasons; missing values never become zero. A measured zero load or fan RPM is valid. There is no fan-control or charging-write API.

## Sampling and lifetime

One serial sampler belongs to each window, normally with a two-second interval. The first observation establishes CPU/IO/process baselines. Counter regression, disk/interface-set changes, invalid monotonic intervals or gaps over thirty seconds invalidate affected rates and rebuild baselines. Pause/resume and failures reset baselines, including Windows PDH formatted deltas.

At most sixty samples remain in memory. Trends use actual time over the latest two minutes and break across missing samples or long gaps. No cleanup records or uploads are created. Failures retain the last graph/time with an explicit failure state. Leaving or closing the page stops sampling unless the user enabled the status/tray summary. Pause affects both surfaces. Canceled or disposed reads cannot update state late or overlap their replacements.

macOS retains the system distinction between closing a window and quitting. Windows normal window close retains application exit and removes the tray icon. Both release resources on exit without secretly blocking it or adding login startup.

## Processes and desktop entry points

Reads comprise PID, start time, bounded name, cumulative CPU time and resident memory. PID plus start time identifies an instance. Process CPU uses total machine logical-core capacity, normalized to 0–100%; resident memory includes shared pages and must not be summed as system usage.

Each process pass checks at most 4,096 processes with its own 0.6-second budget. Exit, denial or budget limits mark partial coverage. Search by name/PID, sort by CPU/memory, and display at most 100 matches with displayed/total counts and coverage. No command lines, environment, file contents, process termination or memory cleaning are exposed.

The opt-in status/tray menus show CPU/GPU, memory, disk read/write, network receive/send, battery, thermals/fans and three top CPU processes, with observation state/time. Commands open monitoring, pause/resume, disable the summary and quit normally. The Mac Dock also opens monitoring and offers pause/resume when the summary is enabled. Windows registers a monitor task where Jump Lists are supported. All surfaces share the same state and sampler. The Windows icon belongs to its window, is removed on close/language reload, and attempts recovery after Explorer restarts.

## Implementation and acceptance

Swift/C# Core own observations, rates and bounded history. Platform owns native reads; Swift Session/Windows Presentation own lifecycle; native UI owns presentation and scheduling. Strings come from the shared catalog and visuals reuse existing tokens.

Acceptance covers warmup, regression, long gaps, changed sources, complete processor groups, PID reuse, missing values, history bounds, pause, hiding, opt-in background use, failure, late results and disposal. Native sampling, WinUI compilation, actual desktop/menu/tray interaction, minimum size, themes and installation require separate evidence in [SYNC.md](../../SYNC.md). This follow-up does not move the published `v0.15.0` tag or change cleanup safety.
