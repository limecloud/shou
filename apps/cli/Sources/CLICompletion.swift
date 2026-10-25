import ShouCore

/// Generate suggestions from the same public registry as help/discovery. The
/// scripts never invoke Shou, inspect its store or install shell integration.
enum CLICompletion {
    static func script(shell: String) throws -> String {
        guard ["bash", "zsh"].contains(shell) else { throw ShouError("invalid_argument", "Completion shell must be bash or zsh.") }
        let specifications=try CLICommandDiscovery.matching("")
        let globals=["--help", "--json", "--locale"]
        var contexts=[String: Set<String>](), values=[String: [String]]()
        contexts[""]=Set(globals + ["--version"])
        values["|--locale"]=["en", "zh-CN"]
        for specification in specifications {
            let words=specification.command.split(separator: " ").map(String.init)
            for index in words.indices {
                let prefix=words.prefix(index).joined(separator: " ")
                contexts[prefix, default: Set(globals)].insert(words[index])
            }
            let key=specification.command
            contexts[key, default: Set(globals)].formUnion((specification.required + specification.optional).map { "--" + $0 })
            for option in specification.required + specification.optional {
                let declared=specification.inputSchema?["properties"]?[option]?["enum"]?.array?.compactMap(\.string)
                let options: [String]
                if let declared, !declared.isEmpty { options=declared }
                else if option.hasPrefix("include-") { options=["true", "false"] }
                else if option == "mode" { options=["permanent", "trash"] }
                else if option == "scope" { options=["full", "cleanup"] }
                else if option == "shell" { options=["bash", "zsh"] }
                else { continue }
                values[key + "|--" + option]=options
            }
        }
        let valueTable=values.keys.sorted().map { key in
            "        \(quote(key))) shou_values=\(quote(values[key]!.joined(separator: " ")));;"
        }.joined(separator: "\n")
        let commandsTable=contexts.keys.sorted().map { key in
            "        \(quote(key))) shou_candidates=\(quote(contexts[key]!.sorted().joined(separator: " ")));;"
        }.joined(separator: "\n")
        if shell == "bash" {
            return #"""
            # Shou completion. Source explicitly; generating this file changes no shell settings.
            _shou() {
                local shou_current="${COMP_WORDS[COMP_CWORD]}" shou_previous="${COMP_WORDS[COMP_CWORD-1]}"
                local shou_context='' shou_word shou_values='' shou_candidates='' shou_skip=0 shou_index
                COMPREPLY=()
                for ((shou_index=1; shou_index<COMP_CWORD; shou_index++)); do
                    shou_word="${COMP_WORDS[shou_index]}"
                    if ((shou_skip)); then shou_skip=0; continue; fi
                    case "$shou_word" in
                        --json|--help|--version|-h) ;;
                        --*) shou_skip=1;;
                        *) shou_context="${shou_context:+$shou_context }$shou_word";;
                    esac
                done
                case "$shou_context|$shou_previous" in
            \#(valueTable)
                    *'|--locale') shou_values='en zh-CN';;
                esac
                if [[ -n "$shou_values" ]]; then
                    COMPREPLY=( $(compgen -W "$shou_values" -- "$shou_current") ); return
                fi
                if ((shou_skip)); then
                    case "$shou_previous" in
                        --file|--path|--directory|--output)
                            while IFS= read -r shou_word; do COMPREPLY+=("$shou_word"); done < <(compgen -f -- "$shou_current");;
                    esac
                    return
                fi
                case "$shou_context" in
            \#(commandsTable)
                esac
                COMPREPLY=( $(compgen -W "$shou_candidates" -- "$shou_current") )
            }
            complete -F _shou shou

            """#
        }
        return #"""
        #compdef shou
        # Source explicitly after compinit; generating this file changes no shell settings.
        _shou() {
            local shou_previous="${words[CURRENT-1]}" shou_context='' shou_word
            local shou_values='' shou_candidates='' shou_skip=0 shou_index
            local -a shou_suggestions
            for ((shou_index=2; shou_index<CURRENT; shou_index++)); do
                shou_word="${words[shou_index]}"
                if ((shou_skip)); then shou_skip=0; continue; fi
                case "$shou_word" in
                    --json|--help|--version|-h) ;;
                    --*) shou_skip=1;;
                    *) shou_context="${shou_context:+$shou_context }$shou_word";;
                esac
            done
            case "$shou_context|$shou_previous" in
        \#(valueTable)
                *'|--locale') shou_values='en zh-CN';;
            esac
            if [[ -n "$shou_values" ]]; then
                shou_suggestions=(${=shou_values}); compadd -- "${shou_suggestions[@]}"; return
            fi
            if ((shou_skip)); then
                case "$shou_previous" in
                    --file|--path|--directory|--output) _files;;
                esac
                return
            fi
            case "$shou_context" in
        \#(commandsTable)
            esac
            shou_suggestions=(${=shou_candidates})
            compadd -- "${shou_suggestions[@]}"
        }
        compdef _shou shou

        """#
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
