# Model integration decisions

English | [简体中文](../zh-CN/engineering/agent-core-selection.md)

The macOS implementation pins Swift AI SDK `0.20.0` in SwiftPM. Keep SDK types inside `ShouAI`; domain evidence, safety, plans and execution remain SDK-independent. macOS 14 deployment behavior and each real provider require explicit validation.

Required capabilities include Responses, Chat Completions, Messages, custom API roots, bounded tool calls, question pause/resume, cancellation, credential revocation and usage budgets. Test with local synthetic providers before authorized live calls. Report actual request, tool and token usage without inventing missing metrics.

Windows uses an independent .NET investigation service, with matching product states and safety semantics. Select and pin its model library during that feature's implementation. No specific .NET model SDK is selected by this document.

Follow the [AI architecture](../architecture/embedded-ai.md), [implementation boundary](embedded-ai-implementation.md), [acceptance](embedded-ai-acceptance.md) and [Windows plan](windows-native-plan.md).
