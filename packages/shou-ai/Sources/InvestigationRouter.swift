import Foundation
import ShouCore

struct InvestigationRouting: Codable, Sendable {
    var queue: [String] = ["."]
    var visited: Set<String> = []
    var current: String?
    var category: String?
    var answer: String?
    var notes: [String] = []
    var escalated=false
}

/// A bounded cleanup workflow: fixed choices and local templates precede generation.
enum InvestigationRouter {
    static func run(_ evidence: InvestigationEvidence) async throws -> Bool {
        var checkpoint=await evidence.value()
        var route=checkpoint.routing ?? InvestigationRouting()
        let chinese=checkpoint.locale == "zh-CN"
        func text(_ en: String, _ zh: String) -> String { chinese ? zh : en }
        if checkpoint.state.goal == .space {
            let page=try await evidence.directory(.init(path: ".", offset: 0))
            let rows=page["children"]?.array ?? []
            let lines=rows.prefix(10).compactMap { row -> String? in
                guard let path=row["path"]?.string else { return nil }
                return path + ": " + String(Int64(row["allocated_bytes"]?.numeric ?? 0)) + text(" allocated bytes", " 分配字节")
            }
            _ = try await finish(evidence, summary: text("Largest measured entries (saved metadata; no model request):\n", "占用最大的已测量项目（保存的元数据；未调用模型）：\n") + lines.joined(separator: "\n"))
            return true
        }
        guard checkpoint.state.connection.decision != nil else {
            throw ShouError("invalid_ai_connection", "Configure a structured decision provider or explicitly choose the main-model-only strategy.")
        }
        while route.visited.count < 8, route.current != nil || !route.queue.isEmpty {
            try await evidence.checkBudget()
            let path=route.current ?? route.queue.removeFirst()
            if route.current == nil && route.visited.contains(path) { continue }
            route.current=path
            let page=try await evidence.directory(.init(path: path, offset: 0))
            let children=(page["children"]?.array ?? []).filter { $0["kind"]?.string == "directory" }
            checkpoint=await evidence.value()
            let facts: JSONValue = .object(["directory": page,
                "user_retention_statements": .array((checkpoint.retention ?? []).map(JSONValue.string)),
                "current_answer": route.answer.map(JSONValue.string) ?? .null])
            if route.category == nil {
                let category=try await evidence.decide(path: path, state: facts, criteria: [
                    "generated": "A generated build/cache directory; this is a hypothesis requiring explicit rebuild and retention evidence before a draft.",
                    "dependencies": "Downloaded dependencies or environments that may be needed offline; require explicit retention evidence.",
                    "personal": "User-authored content, source, configuration, databases or backups; retain it.",
                    "mixed": "Contains multiple different purposes; inspect bounded child directories before deciding.",
                    "unknown": "Metadata does not establish a reliable purpose; gather evidence or ask the user."
                ])
                route.category=category.verdict
                route.notes.append(path + ": " + categoryName(category.verdict, chinese: chinese))
            }
            switch route.category {
            case "generated", "dependencies":
                if path == "." && checkpoint.state.scope == "." {
                    // A selected root cannot become a cleanup rule.
                    route.queue += children.prefix(4).compactMap { $0["path"]?.string }
                } else {
                    if (checkpoint.retention ?? []).isEmpty && route.answer == nil && checkpoint.questionCount < 3 {
                        try await ask(evidence, route: route, question: text("Can '", "目录「") + path + text("' be fully regenerated? State how, and what must remain (including offline dependencies).", "」能否完整重建？请说明重建方式以及必须保留的内容（包括离线依赖）。"), chinese: chinese)
                        return true
                    }
                    let input=AdviceInput(path: path,
                        name: text("Reviewed generated folder", "已审阅的生成目录"),
                        explanation: text("Metadata and your retention statements support reviewing this exact folder. Preview checks the current files; no content was read.", "根据目录元数据和你的保留说明，此精确目录可进入规则审阅。预览会检查当前文件；调查未读取正文。"),
                        rebuildNote: (checkpoint.retention ?? []).isEmpty ? text("Rebuildability and retention conditions are not established; ask the user before creating a draft.", "重建与保留条件尚未确认；生成草稿前必须询问用户。") : (checkpoint.retention ?? []).joined(separator: "\n"),
                        limitations: [text("Keep source, configuration, personal data and required offline dependencies. A folder name alone is not proof of rebuildability.", "保留源码、配置、个人数据及所需离线依赖。目录名本身不能证明可重建。")], minimumAgeDays: nil)
                    let result=try await evidence.propose(input)
                    if result["decision"]?.string == "needs_information" && route.answer == nil && checkpoint.questionCount < 3 {
                        route.current=path
                        try await ask(evidence, route: route, question: text("Can '", "目录「") + path + text("' be fully regenerated? State how, and what must remain (including offline dependencies).", "」能否完整重建？请说明重建方式以及必须保留的内容（包括离线依赖）。"), chinese: chinese)
                        return true
                    }
                    if result["decision"]?.string == "needs_information" {
                        route.notes.append(text("Rebuild evidence is still missing; no draft created.", "仍缺少重建证据；未生成草稿。"))
                    }
                    if result["decision"]?.string == "retain" { route.notes.append(path + ": " + text("Retained according to the evidence and your conditions.", "根据证据和你的条件保留。")) }
                }
            case "mixed":
                route.queue += children.prefix(4).compactMap { $0["path"]?.string }
            case "personal": break
            default:
                if route.answer == nil && !children.isEmpty && path.split(separator: "/").count < 2 {
                    route.queue += children.prefix(4).compactMap { $0["path"]?.string }
                } else if route.answer == nil && checkpoint.questionCount < 3 {
                    try await ask(evidence, route: route, question: text("What is '", "目录「") + path + text("' used for, and what must be retained?", "」用于什么？哪些内容必须保留？"), chinese: chinese)
                    return true
                } else if checkpoint.state.connection.usesMainModel {
                    try await evidence.setRouting(route)
                    try await evidence.escalate(text("The folder's purpose or retention conditions need open-ended understanding after bounded metadata and user clarification.", "有界元数据和用户补充仍不足以表达目录用途或保留条件，需要主模型理解。"))
                    return false
                } else {
                    route.notes.append(text("Open-ended understanding needs a main model connection. Existing facts are retained; configure one for a new investigation.", "开放式理解需要配置主模型。已有事实已保留；配置后可新建调查。"))
                }
            }
            route.visited.insert(path); route.current=nil; route.category=nil; route.answer=nil
            route.queue=Array(route.queue.filter { !route.visited.contains($0) }.prefix(12))
            try await evidence.setRouting(route)
        }
        let limited = !route.queue.isEmpty
        let summary=route.notes.joined(separator: "\n") + "\n" + text("Suggestions are disabled drafts requiring preview. Retained or unknown content has no cleanup authorization.", "建议均为需要预览的禁用草稿。保留项和未知内容没有获得清理授权。")
        _ = try await finish(evidence, summary: summary, limited: limited)
        return true
    }

    private static func categoryName(_ value: String, chinese: Bool) -> String {
        if !chinese { return ["generated": "generated content hypothesis", "dependencies": "dependency hypothesis", "personal": "retain authored or personal content", "mixed": "mixed purposes", "unknown": "purpose unknown"][value] ?? "purpose unknown" }
        return ["generated": "生成内容假设", "dependencies": "依赖内容假设", "personal": "保留创作或个人内容", "mixed": "用途混合", "unknown": "用途未知"][value] ?? "用途未知"
    }
    private static func ask(_ evidence: InvestigationEvidence, route: InvestigationRouting, question: String, chinese: Bool) async throws {
        try await evidence.setRouting(route)
        let checkpoint=await evidence.value()
        let id=Codec.id("question")
        let choices=chinese ? ["保留此目录，不生成清理规则", "需要补充重建方式和保留条件"] : ["Retain this folder; do not create a cleanup rule", "I need to describe rebuild and retention conditions"]
        _ = try await evidence.finish(summary: route.notes.joined(separator: "\n"),
            questions: [AIQuestion(id: id, text: question, choices: choices)], pending: [id], messages: checkpoint.messages, limited: false)
    }
    private static func finish(_ evidence: InvestigationEvidence, summary: String, limited: Bool = false) async throws -> AIInvestigation {
        let checkpoint=await evidence.value()
        return try await evidence.finish(summary: summary, questions: [], pending: [], messages: checkpoint.messages, limited: limited)
    }
}
