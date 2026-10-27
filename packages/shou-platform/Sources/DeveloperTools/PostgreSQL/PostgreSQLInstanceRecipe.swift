import Foundation
import ShouCore
#if os(macOS)
import Darwin

struct PostgreSQLInstanceRecipe: DeveloperInstanceRecipeAdapting {
    let toolID="postgresql", executableName="postgres"
    func resolve(_ context: DeveloperInstanceRecipeContext) -> DeveloperInstanceConfiguration? {
        let arguments=Array(context.arguments.dropFirst())
        guard arguments.count == 2, arguments[0] == "-D", arguments[1].hasPrefix("/") else { return nil }
        return .init(arguments: arguments, path: arguments[1] + "/postgresql.conf", pidFile: arguments[1] + "/postmaster.pid", log: arguments[1] + "/pg.log")
    }
}

#endif
