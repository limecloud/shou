# Cleanup AI architecture

English | [简体中文](../zh-CN/architecture/embedded-ai.md)

Status: macOS has a Swift investigation implementation. Windows uses the same product contract with an independent .NET implementation, currently planned.

## Ownership

```mermaid
flowchart TB
    MacUI[macOS contextual UI] --> Swift[Swift investigation service]
    MacCLI[Swift CLI] --> Swift
    WinUI[WinUI Presentation - planned] --> Dotnet[.NET investigation service - planned]
    WinCLI[.NET CLI - planned] --> Dotnet
    Contract[Evidence, states and rule contracts] --> Swift
    Contract --> Dotnet
    Swift --> MacCredentials[macOS credential adapter]
    Dotnet --> WinCredentials[Windows credential adapter - planned]
    Swift --> Routing[Local handling and selected services]
    Dotnet --> Routing
    Routing --> Draft[Disabled independent rule drafts]
    Draft --> Parser[Deterministic rule validation]
    Parser --> Preview[Independent preview and explicit enablement]
    Preview --> Scan[Fresh scan and confirmed cleanup]
```

The investigation service owns goals, bounded evidence, questions, routing, budgets and checkpoints. Core owns rules and cleanup safety; Platform owns credentials, local records and system facts. SDK types do not enter Core. Each platform's UI and CLI share its investigation service directly.

## Routing flow

```mermaid
flowchart TD
    Entry[Explicit contextual launch] --> Gate{AI enabled and connection authorized?}
    Gate -->|No| Settings[Explain required configuration without a request]
    Gate -->|Yes| Scope[Bind goal, selected scope and evidence budget]
    Scope --> Local{Deterministic local result sufficient?}
    Local -->|Yes| Result[Report evidence and actual zero-service usage]
    Local -->|No| Policy{Decision service enabled by policy?}
    Policy -->|Yes| Decision[Ask configured structured decision service]
    Decision --> Sufficient{Sufficient and within scope?}
    Sufficient -->|Yes| Result
    Sufficient -->|No| Main[Use configured main model if authorized]
    Policy -->|No| Main
    Main --> Missing{Missing user intent?}
    Missing -->|Yes| Questions[Save questions and wait]
    Questions --> Scope
    Missing -->|No| Result
    Result --> Draft[Create separate disabled suggestions]
```

Jev is the current optional structured-decision adapter. Main-only routing must not call it. Unavailable disabled-service credentials cannot block an authorized main-only path. Do not silently move evidence between providers. Explain escalation and record actual usage per service.

## Investigation sequence

```mermaid
sequenceDiagram
    actor User
    participant UI as Native UI or CLI
    participant Service as Platform investigation service
    participant Evidence as Bounded local evidence
    participant Provider as Selected model service
    participant Store as Private checkpoints
    User->>UI: Select goal, scope and connection
    UI->>Service: Start with authorization and cancellation
    Service->>Evidence: Read allowed metadata
    Evidence-->>Service: Bounded facts and limitations
    Service->>Provider: Send disclosed evidence if needed
    Provider-->>Service: Tool request, question or proposal
    alt User intent needed
        Service->>Store: Save waiting checkpoint
        Service-->>UI: Focused questions
        User->>UI: Answer or cancel
        UI->>Service: Continue original scope and connection
    else Sufficient evidence
        Service-->>UI: Independent suggestions and usage
    end
    UI->>Service: Import selected suggestion as disabled rule
    Service-->>UI: Rule ID for independent preview
```

## State and cancellation

Domain states are `running`, `waiting`, `complete`, `limited`, `cancelled` and `failed`. UI additionally represents off, unconfigured, ready, stopping and stale. Unknown or incomplete evidence cannot become a confident cleanup decision.

Save the original scope, goal, connection identity, expiry, questions, answers and observed usage. Continue only after revalidation. An interrupted running record does not imply a resumable waiting record. Cancellation revokes subsequent transport and tool work, preserves completed evidence and records the actual terminal state.

## Connections and transport

Configure protocol, API root, model and credential reference independently. macOS supports Responses, Chat Completions and Messages with its pinned adapter; the .NET service must establish its own equivalent evidence. Remote endpoints require HTTPS; loopback HTTP serves generated fixtures. Credentials stay in private local or native credential storage. Apply request/response limits, deadlines, redirect policy and budgets explicitly.

Saving or editing configuration does not send a network request. A separate test action states its destination and effect. Deletion removes a connection from active choices while retaining investigation references; restoration and credential behavior are validated independently. Machine output and diagnostics redact secrets.

## Rule closure

```mermaid
flowchart LR
    Suggestion[Independent suggestion] --> Import[Disabled draft]
    Import --> Validate[Closed parser]
    Validate --> Preview[Read-only exact-scope preview]
    Preview --> Enable[Explicit enablement]
    Enable --> Scan[Fresh scan]
    Scan --> Select[User-adjustable selection]
    Select --> Confirm[Exact action confirmation]
    Confirm --> Execute[Existing deterministic executor]
    Execute --> Verify[Receipt and remaining-scope verification]
```

A model never owns deletion authority. Protected paths, exclusions, active applications, incomplete targets, expired evidence and journal failures remain enforced by deterministic services. Imported content and project metadata are untrusted input.

## Verification

Use generated fixtures for protocol, scope, credential isolation, provider substitution, revocation, questions, budget limits, injection, independent drafts and offline cleanup. Validate native interaction and actual model quality separately. Windows source, pure .NET tests, native APIs, UI and signed distribution have separate gates in the [implementation plan](../engineering/windows-native-plan.md). See [product journeys](../product/embedded-ai.md) and [acceptance](../engineering/embedded-ai-acceptance.md).
