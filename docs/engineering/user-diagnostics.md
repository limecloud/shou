# User diagnostics and terminal support

English | [简体中文](../zh-CN/engineering/user-diagnostics.md)

macOS and Windows Settings → Support → Run Diagnostics and `shou diagnostics` share a read-only service. Reports support preview/copy in the app language or `--locale`, following the [current workspace](interface-design.md). [SYNC.md](../../SYNC.md) separates source, scoped checks and native acceptance. Windows has an independent C# Core, Win32 observations, Presentation and WinUI entry. Native system and UI evidence remains separate.

## Report scope

`format_version=1` includes observation time, app version, platform/architecture/numeric OS version, processor count, physical memory and home-volume capacity/free bytes.

| Check | Observation and limits |
| --- | --- |
| `disk_capacity` | Missing or invalid metadata stays unknown. Below 1 GiB or at most 10% free prompts attention without starting cleanup |
| `disk_access` | macOS opens its access sentinel without reading contents. Windows reports not applicable; each scan checks selected locations independently |
| `local_records` | Checks directory type, current owner, private permissions and no-follow ancestor handles. Does not create directories, enumerate contents, test write access or repair configuration |

Check states are `normal`, `attention`, `unknown`, `not_configured` and `not_applicable`. Any unknown observation produces `status=partial` and CLI exit `6`; otherwise the report is `complete`. This does not mean every check is normal, the disk is healthy or scans are complete. Unconfigured records remain distinct from failures.

Reports exclude personal absolute paths, usernames, hostnames, conversation text, file contents, credentials, process arguments and environment variables. Only modelled fields are exported, without free-form exceptions, networking, uploads, subprocesses or permission changes. Scan-specific failures, unknown activity and item outcomes remain owned by their results and history.

```sh
shou diagnostics --locale en
shou diagnostics --json
shou completion --shell bash
shou completion --shell zsh --json
```

JSON uses the [standard CLI envelope](../ai/agent-and-cli-contract.md). Diagnostics never opens business storage; missing records or a file at the configured location produce an observation while preserving existing state.

## Shell completion and verification

macOS `completion --shell bash|zsh` and Windows `completion --shell bash|zsh|powershell` generate static scripts from public discovery, including subcommands, options, enums and spaced filenames. JSON returns `shell` and `script`. It neither installs scripts nor edits profiles or opens records. Users load scripts through their shell and regenerate them after command upgrades. Completion never runs Shou, scans directory trees or initiates mutations; filenames use the shell's own facility. PowerShell reads literal syntax-tree elements without evaluating input. Unknown shells or arguments are rejected.

Generated diagnostic fixtures cover missing directories, file conflicts, links, nonprivate directories, cancellation, low capacity and unknown values, checking preserved bytes/mtime/permissions and privacy. Real Bash callbacks cover discovery consistency, leading locale options, enums, spaced paths and hostile arguments. Bash and available Zsh syntax are checked separately. The installed 0.15.0 helper passed seven actual macOS/Zsh 5.9 PTY/Tab-key checks, including spaced filenames and hostile literal text, without invoking Shou or evaluating input. Exact artifact hashes and original receipts are in [SYNC.md](../../SYNC.md#installed-zsh-completion-2026-10-26--已安装版-zsh-补全). Windows PowerShell terminal interaction and native diagnostic UI remain separate acceptance items.
