# MySQL instance and database administration

[简体中文](../zh-CN/product/mysql-administration.md) | English

Status: macOS working-tree implementation, 2026-10-27. Actual engine, installation and UI evidence are recorded separately in the task review (local evidence: `output/reviews/developer-tools-2026-10-26/REPORT.md`) and instance-registration review (local evidence: `output/reviews/mysql-instance-management-2026-10-27/REPORT.md`). The Windows database adapter is not implemented; no Windows testing is performed in this round at the user's request. This does not establish parity for all developer tools.

## Tasks and identity

MySQL has dedicated Service, Version Management, Databases & Accounts, Configuration File, Logs, Slow Query Log and Instance Groups tasks. Installation copies, runtime instances and database accounts are separate objects. Processes retain the [per-software lifecycle contract](../engineering/developer-tool-adapters.md); Swift `MySQLAdministration` and `MySQLAdminOperating` own database tasks instead of generic installation commands.

The selected installation/configuration path is visible. Connections use local TCP 127.0.0.1 or an explicit Unix socket and the installation's adjacent mysql/mysqldump clients. The connected server's UUID, version, port, data directory and authenticated account are observed and rechecked before changes. Reused ports or changed instances invalidate operations. Isolated client configuration, HOME and login-file paths prevent personal defaults from changing the selected destination.

## Databases and accounts

- Read schema names, character sets and exact User/Host/authentication-plugin identities without reading business tables. Insufficient mysql.user privileges preserve schema results and disable account tasks rather than inventing an empty account list.
- Creating a database and creating an account are separate reviews. New accounts are localhost-only with privileges on one selected schema, no existing username reuse, password replacement, global privileges or GRANT OPTION. GRANT patterns and partial_revokes are handled separately so underscores cannot widen the schema scope.
- Password changes use the authenticated session and exact User/Host. New credentials verify the resulting account; unverified outcomes require inspection without automatic retry. No authentication-bypass recovery mode or automatic server stop is added.
- Local notes belong to Shou and are keyed by server UUID/schema. MySQL does not supply plaintext passwords. Credentials remain in session memory and private temporary client configuration; operation records contain neither credentials nor SQL text.

Mutations use an in-memory, two-minute, single-use review. After identity/state checks, a secret-free intent precedes SQL dispatch and an outcome follows. Multiple SQL statements are not one transaction. Failure can leave completed changes and requires reconnection/inspection, without automatic compensation, replay or changes to another account.

## Configuration and logs

The editor displays the exact selected .cnf source and can explicitly select another file. Links, special files and multiple hard links are rejected. Writes require a current-user writable file without elevation/permission changes, recheck source identity/content, journal hashes, write through the bound handle and read back. External changes block saving; atomic compare-and-swap with external writers ignoring advisory locks is not promised. Configuration plaintext is not copied to ordinary records. Saving does not validate MySQL syntax or restart the server.

The selected file's mysqld port/socket/datadir/log options are hints; includes and command-line overrides need separate verification. Error and slow logs are separate, explicitly selectable, and limited to 200 lines/64 KiB. Missing configuration, unreadable files and genuinely empty logs differ. No automatic slow-log enabling or log clearing is added. Shou startup output remains separate and never substitutes for a missing business log. When configuration loads in the background, the current log task reloads after completion.

## Backups and independent instances

Selected non-system schemas export to a user-chosen local directory. mysqldump streams into exclusively created private .sql.partial files without shell commands, whole-backup buffering or overwrites. Successful exit, nonempty output, flush and server identity checks precede .sql publication. Per-schema results retain successes and failed .partial files. Single-transaction/quick does not guarantee consistent nontransactional tables; runtime exports are not described as restore-verified backups. Database import/deletion is not provided.

Instance groups initialize new private configuration/data/port/socket paths using the selected installation. Secure initialization sets root's initial password, binds loopback and leaves the instance stopped without migration, reuse or login registration. Initialization SQL uses unlinked private stdin, leaving no named password file. Failure retains data for inspection without automatic deletion/reinitialization. Registered instances use exact lifecycle controls; groups are independent databases rather than startup bundles.

The group page displays verified state, PID, inline switches and restart through the existing service controller and its current observations, preflight and outcomes. The management menu opens this group's database, configuration, error/slow logs and separate startup output, and can copy its socket path. Unknown or stale observations cannot authorize control; failures retain their reason and log entry point.

### Registration changes

`MySQLInstanceRegistry` owns rename, refresh-registration and unregister use cases through a small platform interface. A two-minute single-use review binds the group record, program/data-directory identity, exact configuration, port and socket. Execution holds the same record lease, rechecks the observation, journals intent before updating registration and records the outcome without automatic replay.

These changes require the exact independent instance to be verified stopped. Another running instance using an explicit different configuration does not block this group; ambiguous runtime identity does. Configuration edits invalidate the previous recipe. Review Updated Configuration on the group page shows the new port and binds the next start to the new file. This flow is limited to Shou-created groups with one explicit `[mysqld]` section, loopback binding and the original data/PID/log/socket paths. Includes and duplicate/ambiguous settings are rejected. It neither changes data directories nor starts the server, and does not prove complete MySQL syntax validity.

Unregister disables the group and its saved stopped recipe while preserving databases, configuration and logs; it does not free disk space. Running instances must first stop. A registration whose generated data directory is already absent may be removed after checking that no matching instance is running. If started externally again, its real process remains discoverable. Batch control and installation/data-directory migration are not implemented.

Re-registration accepts complete explicit names for the generated connection/path settings and `slow-query-log`, `long-query-time`, `max-connections`, `innodb-buffer-pool-size`, `character-set-server`, `collation-server`, `sql-mode` and `default-time-zone`. Other options, plugin loading, loose/skip aliases and abbreviations are rejected so they cannot override reviewed listening scope or paths. Underscores normalize to hyphens before duplicate checks; both log paths remain bound to this group. The raw editor can still save other configuration, but saving does not grant start-registration eligibility.

## Remaining parity gaps

Stopped-instance recipes bind configuration identity. Independent groups now have an explicit re-registration flow; arbitrary external instances edited while stopped still lack this flow. Saving configuration does not establish that the next start works. Existing instances with group/world-writable working directories display the specific permission gap and retain running facts without restart permission; personal directory permissions are never changed automatically.

MacPorts, additional version lines, automatic phpMyAdmin site deployment, forgotten-password maintenance recovery, group installation/data-directory migration, batch control and other products' dedicated tasks are not complete. Existing Homebrew listings do not prove all-source support. MySQL tasks must not be applied to MariaDB, PostgreSQL, Redis or other products; follow the [adapter design](../engineering/developer-tool-adapters.md) with separate implementations and evidence.
