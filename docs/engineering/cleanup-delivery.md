# Daily cleanup delivery requirements

English | [简体中文](../zh-CN/engineering/cleanup-delivery.md)

| Work item | Required behavior | Platform status |
| --- | --- | --- |
| N01 | Compile bounded root work; keep filesystem evidence equivalent | macOS source; native verification required |
| N02 | Expiry/quota collection with protected active and recovery references | macOS source; failure cases required |
| N03 | Fixed owner-tool operations with local context and bounded output | macOS source; generated tool fixtures |
| N04 | Owner closure, refreshed affected scope and explicit retry | Per-platform capability; unknown activity blocks |
| N05 | Orphan cleanup requires verified owner absence and separate data consent | macOS source; explicit supported associations |
| N06 | Native Windows scanning and cleanup | Planned under the Windows implementation stages |
| N07 | Independent reusable personal rules from investigation | macOS source; quality and UI acceptance separate |
| N08 | Version, documents, resources and distribution match the verified revision | Release-specific evidence |
| N09 | Large immutable receipt manifests and reference protection | macOS source; interrupted-write acceptance required |

Implement and verify each item as a vertical slice. Performance optimizations must preserve selection, protection, manifests, receipts and cancellation. Reusable rules never remove the need for current evidence or confirmation.

Windows follows the [native plan](windows-native-plan.md). Record feature and safety alignment in [SYNC.md](../../SYNC.md). Executed checks belong in a revision-specific verification report, not in a permanent product-support claim.
