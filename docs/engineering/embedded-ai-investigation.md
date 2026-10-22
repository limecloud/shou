# Investigation implementation contract

English | [简体中文](../zh-CN/engineering/embedded-ai-investigation.md)

## Inputs and outputs

Accept the user's explicit goal, current local scan, selected scope and selected provider. Read only bounded evidence allowed by the product disclosure. Do not send raw file contents, secrets or unrelated paths through implicit tools.

Output evidence, focused questions, independent rule suggestions, preserved paths, limitations and actual service usage. A suggestion is a disabled draft; creation, validation, preview, enablement, fresh scanning and confirmed cleanup remain distinct operations.

## State and routing

Use the defined running, waiting, complete, limited, cancelled and failed domain states. UI states such as unconfigured or stopping do not fabricate domain completion. Prefer deterministic local evidence, optional structured decisions and necessary main-model escalation. Respect per-service credential availability and user routing policy.

Persist question checkpoints and original connection references. Revalidate scope and expiry before continuation. Cancellation revokes subsequent requests and retains actual outcomes. HTTP redirects, retries, timeouts, payload limits and budgets must follow the explicit transport contract.

## Platform implementation

macOS desktop and CLI share `ShouAI` services with a pinned Swift SDK and bounded transport. Windows desktop and CLI will share independent .NET investigation services, with Windows-native credentials and local records. Product semantics and declarative rule output align through shared cases and [SYNC.md](../../SYNC.md).

## Verification

Use generated evidence and local fake providers for protocol, prefix, auth, cancellation, budgets, injection and scope tests. Add provider-specific live evidence only with authorization. Test questions, individual drafts, previews, offline cleanup and recovery through native UI separately. See [AI architecture](../architecture/embedded-ai.md) and [acceptance](embedded-ai-acceptance.md).
