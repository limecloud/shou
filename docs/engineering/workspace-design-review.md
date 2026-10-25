# Workspace design reference review

English | [简体中文](../zh-CN/engineering/workspace-design-review.md)

Reviewed on 2026-10-25. The supplied public demonstration was downloaded at 1920 × 1080, duration 55.68 seconds; 46 timestamps and on-screen text were extracted. Original media, frames, OCR and source metadata remain ignored local research artifacts, separate from Shou branding and release assets. Observed video content does not independently verify actual deletion scope, performance or application compatibility.

## Observed journeys

| Time | What the demonstration shows | Relevance to Shou |
| --- | --- | --- |
| 00–09 s | Opening and an application-icon wall with a compatibility claim | Shou needs its own evidence for compatibility claims |
| 09–19 s | Scan progress, size/path, expandable full-width categories, recommendations, selection and permanent cleanup | Organize results by purpose with nearby rebuild consequences |
| 19–23 s | Execution and a distinct completion state | Separate scan evidence, execution and recorded results |
| 23–35 s | Application list, inline bundle/data selection, ready/review groups, separate personal data and uninstall completion | Aggregate related files around an object while keeping data impact explicit |
| 35–41 s | Maintenance start/progress/result; captions mention Start, Search, icon and DNS caches | Adapt feedback structure without promising these system capabilities |
| 41–45 s | Large treemap, folder list, breadcrumbs and volume occupancy | Give the map meaningful area and preserve clear navigation/units |
| 45–48 s | CPU, GPU, memory, free space, network, battery and process cards | Separate monitoring capability, not an excuse for a nonfunctional dashboard |
| 49–53 s | Compact tray panel with keep-awake and screen-cleaning entries | A persistent panel is a different task requiring its own product decision |

Updates and Startup entries are visible, but their actual update/control journeys are not demonstrated. Maintenance footage does not verify authorization, cancellation or failures.

## Layout and interaction

A few top-level destinations replace a persistent navigation column. Cleanup results use a focused composition: categories summarize first, then reveal exact paths. Applications occupy complete rows with aligned icon, name, secondary facts and size. Related data expands below the original row, avoiding repeated navigation. A stable footer updates the selected count and capacity and keeps the next action obvious.

The spacious impression comes from hierarchy, horizontal room, quiet separators and consistent alignment. Dark surfaces and per-feature themes add atmosphere, but Shou need not reproduce warm palettes, planetary motion or artwork. Oversized decoration, tiny path text, unexplained health scores and exact-looking freed-space claims should not become Shou requirements.

## Shou decisions

Adopt grouped top navigation, broad categories, object lists, inline associations and a selection footer. Use Shou's cool neutral surfaces, teal accent and native symbols. Group applications and project outputs within one workspace while retaining shared deterministic rules and evidence. Keep shared caches independent. Explicit manual review explains complete-directory impact, and cleanup continues to default to permanent removal.

The [interface specification](interface-design.md) owns implementation guidance; [Apps & Projects](../product/apps-and-projects.md) owns semantics. This review explains decisions and does not replace product contracts or acceptance evidence.
