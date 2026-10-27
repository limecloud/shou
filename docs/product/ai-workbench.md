# AI Workbench

English | [简体中文](../zh-CN/product/ai-workbench.md)

AI Workbench separately organizes Claude Code/Desktop, Codex, Gemini CLI, Grok Build, OpenCode, OpenClaw, Hermes, Pi, MiniMax Code, Kimi, Oh My Pi, Copilot CLI and other cataloged AI software. It is distinct from developer runtimes/servers and from Shou's optional AI rule investigation.

The current implementation provides catalog browsing, read-only installation discovery, multiple-copy/source/version presentation, favorites and the shared package review service. Details preserve actual locations. File discovery does not establish runtime health; missing source, version or uninstall adapters retain an observation and official guide.

The [tool contract](developer-tools.md) governs package operations. This module does not read or modify provider credentials, OAuth sessions, conversation content or usage records. Provider switching, local proxies/failover, MCP, Skills, prompts, sessions and usage are outstanding capabilities; catalog cards and favorites do not imply their implementation.

Future configuration management requires per-tool/version field adapters, read-only format discovery and an exact change review. Preserve unrelated plugins, hooks, MCP, comments and settings. Platform credential facilities must keep secrets out of diagnostics, discovery reports and screenshots. Software removal, configuration changes, skill synchronization and conversation deletion require separate authority.

## Local configuration and extension inventory

Claude Code, Claude Desktop, Codex, Gemini CLI and OpenCode details include Configuration & Extensions. Fixed user locations are inspected for provider configuration, MCP declarations, global instructions and direct skill directories containing `SKILL.md`. Missing and unreadable locations remain distinct. Only declaration names are presented; commands, arguments, environment values, keys and instruction bodies are excluded. JSON must be an object and files are bounded to 256 KiB. TOML inspection summarizes supported simple table declarations, not a complete parse. Directories are bounded to 256 entries. Configuration and skills are never executed or sent to a model.

macOS uses bounded no-follow reads; Windows uses native pinned paths and metadata reads. Linked/reparse or unsafe content remains unavailable. Finder reveal and Windows folder opening let users manage files with their own editor. Shou does not overwrite configuration or grant provider switching, MCP activation or skill synchronization authority.

Only default user locations are covered. Custom roots, project settings, linked skills, activation and runtime health remain unverified. Global instruction presence does not prove activation, and configuration inventory remains separate from software installation. Full provider switching, proxy/failover, sessions and usage remain unimplemented.

## Shared tool interaction

AI Workbench shares the grouped tool rail, persistent details, source filter pills and version/path table with Developer Tools. Verified background services receive source-specific immediate switches that wait for observed results. Installations are not adopted across sources. Configuration & Extensions remains a separate tab; read-only discovery does not fabricate provider, MCP or Skills switches. Windows control gates and macOS scope follow the [service contract](developer-tools.md#service-capsule-switches).
