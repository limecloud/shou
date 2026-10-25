using Shou.Windows.Core;

namespace Shou.Windows.Cli;

// Only the command registry supplies commands and option names. No generated
// script evaluates user input, queries storage or launches Shou.
internal static class CommandCompletion
{
    internal static string Script(string shell)
    {
        if (shell is not ("bash" or "zsh" or "powershell")) throw new ShouException("invalid_argument", "Choose bash, zsh or powershell completion.");
        var contexts = new SortedDictionary<string, SortedSet<string>>(StringComparer.Ordinal);
        var values = new SortedDictionary<string, string[]>(StringComparer.Ordinal);
        SortedSet<string> Context(string name)
        {
            if (!contexts.TryGetValue(name, out var items)) contexts[name] = items = new(["--help", "--json", "--locale"], StringComparer.Ordinal);
            return items;
        }
        Context("").Add("--version");
        foreach (var spec in CommandDiscovery.Matching(""))
        {
            var words = spec.Command.Split(' ');
            for (var index = 0; index < words.Length; index++) Context(string.Join(' ', words.Take(index))).Add(words[index]);
            foreach (var option in spec.Required.Concat(spec.Optional))
            {
                Context(spec.Command).Add("--" + option);
                var choices = option switch
                {
                    "shell" => new[] { "bash", "zsh", "powershell" }, "mode" => ["permanent", "trash"],
                    "allow-network" => ["true"],
                    "range" => ["last-hour", "last-day", "last-seven-days", "all-time"],
                    "sort" => ["name", "registered-size"], "action" => ["enable", "disable"],
                    _ when option.StartsWith("include-", StringComparison.Ordinal) || option == "allow-installer-data-changes" => ["true", "false"],
                    _ => Array.Empty<string>()
                };
                if (choices.Length > 0) values[spec.Command + "|--" + option] = choices;
            }
        }
        if (shell == "powershell") return PowerShell(contexts, values);
        var valueTable = string.Join('\n', values.Select(item => $"        {Quote(item.Key)}) shou_values={Quote(string.Join(' ', item.Value))};;"));
        var commandsTable = string.Join('\n', contexts.Select(item => $"        {Quote(item.Key)}) shou_candidates={Quote(string.Join(' ', item.Value))};;"));
        if (shell == "bash") return $$"""
            # Shou completion. Source explicitly; generation changes no shell settings.
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
            {{valueTable}}
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
            {{commandsTable}}
                esac
                COMPREPLY=( $(compgen -W "$shou_candidates" -- "$shou_current") )
            }
            complete -F _shou shou

            """;
        return $$"""
            #compdef shou
            # Source explicitly after compinit; generation changes no shell settings.
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
            {{valueTable}}
                    *'|--locale') shou_values='en zh-CN';;
                esac
                if [[ -n "$shou_values" ]]; then
                    shou_suggestions=(${=shou_values}); compadd -- "${shou_suggestions[@]}"; return
                fi
                if ((shou_skip)); then
                    case "$shou_previous" in --file|--path|--directory|--output) _files;; esac
                    return
                fi
                case "$shou_context" in
            {{commandsTable}}
                esac
                shou_suggestions=(${=shou_candidates}); compadd -- "${shou_suggestions[@]}"
            }
            compdef _shou shou

            """;
    }

    private static string PowerShell(SortedDictionary<string, SortedSet<string>> contexts, SortedDictionary<string, string[]> values)
    {
        static string Array(IEnumerable<string> items) => "@(" + string.Join(",", items.Select(PsQuote)) + ")";
        var commands = string.Join('\n', contexts.Select(item => $"        {PsQuote(item.Key)} = {Array(item.Value)}"));
        var options = string.Join('\n', values.Select(item => $"        {PsQuote(item.Key)} = {Array(item.Value)}"));
        return $$"""
            # Shou completion. Dot-source explicitly; generation changes no profiles.
            Register-ArgumentCompleter -Native -CommandName shou,shou.exe -ScriptBlock {
                param($wordToComplete, $commandAst, $cursorPosition)
                $shouCommands = @{
            {{commands}}
                }
                $shouOptions = @{
            {{options}}
                }
                $shouContext = @(); $shouSkip = $false; $shouPrevious = ''
                foreach ($shouElement in @($commandAst.CommandElements | Select-Object -Skip 1)) {
                    if ($shouElement.Extent.StartOffset -ge $cursorPosition) { break }
                    if ($wordToComplete.Length -gt 0 -and $shouElement.Extent.EndOffset -ge $cursorPosition) { break }
                    if ($shouElement -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $shouWord = $shouElement.Value }
                    elseif ($shouElement -is [System.Management.Automation.Language.CommandParameterAst] -and $null -eq $shouElement.Argument) { $shouWord = $shouElement.Extent.Text }
                    else { return }
                    $shouPrevious = $shouWord
                    if ($shouSkip) { $shouSkip = $false; continue }
                    if ($shouWord -in @('--json','--help','--version','-h')) { continue }
                    if ($shouWord.StartsWith('--')) { $shouSkip = $true; continue }
                    $shouContext += $shouWord
                }
                $shouKey = $shouContext -join ' '
                $shouCandidates = if ($shouPrevious -eq '--locale') { @('en','zh-CN') }
                    elseif ($shouOptions.ContainsKey("$shouKey|$shouPrevious")) { $shouOptions["$shouKey|$shouPrevious"] }
                    elseif ($shouSkip) { @() } else { $shouCommands[$shouKey] }
                foreach ($shouValue in $shouCandidates) {
                    if ($shouValue.StartsWith($wordToComplete, [System.StringComparison]::OrdinalIgnoreCase)) {
                        [System.Management.Automation.CompletionResult]::new($shouValue, $shouValue, 'ParameterValue', $shouValue)
                    }
                }
            }

            """;
    }

    private static string Quote(string value) => "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";
    private static string PsQuote(string value) => "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";
}
