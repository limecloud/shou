# Shou rule questionnaire

Use this reference when the user's request names a large directory but does not establish what can be removed. The goal is a short, evidence-driven conversation, not a generic cleanup checklist.

## Questions and answers to capture

| Topic | Ask | Acceptable evidence | If unknown |
| --- | --- | --- | --- |
| Ownership | Who owns the files and which exact root may be inspected? | User-selected path and registered workspace | Do not register or scan a broader parent |
| Purpose | What creates the files? | Tool/project name plus observed layout | Analysis only |
| Rebuild | Can the content be recreated locally or downloaded again? | User command, lockfile/manifest, or documented recovery path | Mark high risk and do not auto-select |
| Activity | Which projects, versions, sessions, or VMs are active? | User exclusion or explicit process/tool state | Exclude the target |
| Retention | Minimum size/age and permanent keep paths? | User-selected thresholds and patterns | Use no condition and require review |
| Scope | One exact child, a project pattern, or a workspace-wide pattern? | Relative pattern under an exact root | Never target the root itself |
| Action | Trash or permanent removal? | Explicit current request | Use Trash plan |

## How to interpret the supplied macOS roots

These are starting points for investigation, not universal deletion rules:

| Root | Default interpretation | Narrowing examples |
| --- | --- | --- |
| `Documents` | Personal and project data | A user-named generated export directory |
| `Library` | Mixed application state, caches, preferences, databases, and credentials | A known cache child or a verified application uninstall component |
| `.cache` | Mixed developer downloads and analysis caches | A named package manager or tool cache |
| `.codex` | Agent sessions, settings, credentials, and caches may coexist | A confirmed disposable download/cache child only |
| `.colima` | VM/container images, volumes, and runtime state | Discuss unused instances; a disk-image file or tool-native operation cannot be expressed by the directory-only rule format |
| `.nvm` | Node.js versions and toolchain files | Discuss unused versions; preserve active/default versions and report engine or native-adapter limits |
| `go` | Source, binaries, module cache, and build cache may coexist | `pkg/mod/cache` or a confirmed build-cache child |
| `.rustup` | Rust toolchains and metadata | Discuss unused toolchains; preserve active/default toolchains and report engine or native-adapter limits |
| `.local` | Application and tool data with no universal meaning | A named cache/generated child after inspection |
| `.cargo` | Registry archives, extracted sources, config, and credentials | Built-in Cargo archive/source rules with integrity evidence |

## Agent response shape

Keep the response structured so the user can approve the next decision:

1. **Observed:** exact root, child paths, bytes, timestamps, scan completeness, and rule matches.
2. **User says:** purpose, rebuild path, active exclusions, retention, and requested action.
3. **Proposed rule:** ID/version, root reference, relative patterns, markers, conditions, exclusions, risk, and limitations.
4. **Unknowns:** anything that prevents safe matching or execution.
5. **Next decision:** import/preview, enable, Trash plan, or stop and investigate.

Do not present a generated rule as proof that files are safe. A rule is a repeatable selection description; a fresh scan and current confirmation are still required.
