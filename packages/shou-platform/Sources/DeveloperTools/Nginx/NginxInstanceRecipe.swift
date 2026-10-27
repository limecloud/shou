import Foundation
import ShouCore
#if os(macOS)
import Darwin

struct NginxInstanceRecipe: DeveloperInstanceRecipeAdapting {
    let toolID="nginx", executableName="nginx"
    func resolve(_ context: DeveloperInstanceRecipeContext) -> DeveloperInstanceConfiguration? {
        var arguments=Array(context.arguments.dropFirst())
        if let title=context.arguments.first, title.hasPrefix("nginx: master process ") {
            let prefix="nginx: master process " + context.executable + " "
            guard title.hasPrefix(prefix), let parsed=parseTitle(String(title.dropFirst(prefix.count))) else { return nil }
            for index in stride(from: 0, to: parsed.count, by: 2) where parsed[index] != "-g" {
                guard !parsed[index+1].contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "\\" }) else { return nil }
            }
            arguments=parsed
        }
        guard arguments.count >= 4, arguments.count % 2 == 0 else { return nil }
        var options=[String:String]()
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard ["-p","-c","-e","-g"].contains(arguments[index]), options[arguments[index]] == nil else { return nil }
            options[arguments[index]]=arguments[index+1]
        }
        guard let config=options["-c"], config.hasPrefix("/"), let prefix=options["-p"], prefix.hasPrefix("/") else { return nil }
        var pidFile: String?
        if let global=options["-g"] {
            let directives=global.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard directives.allSatisfy({ $0.isEmpty || $0 == "daemon off" || $0 == "daemon on" || $0.hasPrefix("pid /") || $0.hasPrefix("error_log /") }) else { return nil }
            pidFile=directives.first { $0.hasPrefix("pid /") }.map { String($0.dropFirst(4)) }
        }
        return .init(arguments: arguments, path: config, pidFile: pidFile, log: options["-e"])
    }
    private func parseTitle(_ text: String) -> [String]? {
        guard let regex=try? NSRegularExpression(pattern: "(?:^| )(-[pceg]) ") else { return nil }
        let range=NSRange(text.startIndex..., in: text), matches=regex.matches(in: text, range: range)
        guard (2...4).contains(matches.count), matches.first?.range.location == 0 else { return nil }
        var result=[String]()
        for (index,match) in matches.enumerated() {
            let start=match.range.location + match.range.length, end=index+1 < matches.count ? matches[index+1].range.location : range.length
            guard let key=Range(match.range(at: 1), in: text), let value=Range(NSRange(location: start, length: end-start), in: text) else { return nil }
            result += [String(text[key]),String(text[value])]
        }
        return result
    }
}

#endif
