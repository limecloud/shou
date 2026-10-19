import Foundation
import ShouCore
import ShouPlatform

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}
func expect(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition { throw CheckFailure(description: "\(file):\(line): expectation failed") }
}
func require<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { throw CheckFailure(description: "\(file):\(line): required value missing") }
    return value
}
func expectThrows<T>(_ body: () throws -> T, file: StaticString = #filePath, line: UInt = #line) throws {
    do { _ = try body() } catch is ShouError { return }
    throw CheckFailure(description: "\(file):\(line): expected ShouError")
}
func expectThrows<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async throws {
    do { _ = try await body() } catch is ShouError { return }
    throw CheckFailure(description: "\(file):\(line): expected ShouError")
}

@main enum TestRunner {
    static func main() async {
        if let status=NativeReadWorker.runIfRequested(Array(CommandLine.arguments.dropFirst())) { Foundation.exit(status) }
        if Array(CommandLine.arguments.dropFirst()) == ["--native-large-trash-only"] {
            do {
                try await nativeLargeTargetTrashAndRestore()
                print("1/1 native large-target tests passed; generated fixtures were restored before local cleanup; no purge.")
            } catch {
                print("FAIL native large-target Trash and restoration: \(error)")
                Foundation.exit(1)
            }
            return
        }
        var cases: [(String, () async throws -> Void)] = [
            ("SHA-256 known vector", { try sha256KnownVector() }),
            ("Schema and round trip", { try ruleSchemaAndRoundTrip() }),
            ("Wildcard semantics", { try wildcardSemantics() }),
            ("Wildcard language equivalence", { try wildcardMatcherPreservesLanguage() }),
            ("Wildcard descendant-prefix soundness", { try wildcardPrefixReachabilityPreservesMatches() }),
            ("Canonical digest", { try canonicalDigestIndependentOfObjectKeyOrder() }),
            ("JSON envelope escaping", { try envelopeUsesStableKeysAndExplicitNull() }),
            ("UTC decision precision", { try utcTimestampsPreserveDecisionPrecision() }),
            ("Chinese desktop default and saved language", { try desktopLanguageDefaultsAndSavedChoice() }),
            ("Runtime localization switches in both directions", { try localizedResourcesSwitchWithoutProcessRestart() }),
            ("Explicit platform-scoped known locations", { try knownLocationsAreExplicitAndPlatformScoped() }),
            ("Native location availability uses directory metadata", { try nativeAvailabilityDistinguishesDirectoriesWithoutFollowingLinks() }),
            ("Native root identity requires search without enumeration", { try nativeRootIdentityNeedsOnlySearchAccess() }),
            ("Read worker preserves direct evidence without a store", { try nativeReadWorkerMatchesDirectEvidenceWithoutOpeningStore() }),
            ("Read worker accepts snake-case protocol fields", { try nativeReadWorkerAcceptsSnakeCaseWireRequest() }),
            ("Read worker cancellation terminates only its child", { try nativeReadWorkerCancellationStopsOwnedChild() }),
            ("Read worker wall timeout returns no evidence", { try nativeReadWorkerTimeoutStopsOwnedChildWithoutEvidence() }),
            ("Read worker failures and malformed responses stay blocked", { try nativeReadWorkerRejectsFailureMalformedAndForeignResponses() }),
            ("Read worker caps live children and recovers capacity", { try nativeReadWorkerCapsConcurrentChildrenAndRecoversCapacity() }),
            ("Known location registration probes only its requested root", { try await knownLocationRegistrationUsesOnlyRequestedRoot() }),
            ("Batch preparation probes once and reports its root", { try await systemScanPreparationIsLinearAndReportsRootBeforeIdentity() }),
            ("Preparation cancellation prevents root registration", { try await systemScanPreparationCancellationPreventsRegistration() }),
            ("Fixed app rules retain personal data", { try await fixedApplicationRulesPreserveUserDataAndSecrets() }),
            ("Known location configuration reuse", { try await knownLocationRegistrationReusesConfiguration() }),
            ("Batch evidence and partial results", { try await systemScanRegistersBeforeEvidenceAndReportsPartial() }),
            ("Application activity policy and revalidation", { try await applicationActivityBlocksAndRechecksExecution() }),
            ("Expanded cache and user-data boundaries", { try await expandedCatalogKeepsCacheAndUserDataBoundaries() }),
            ("Expanded application secret protection", { try await expandedApplicationCacheSecretsRemainProtected() }),
            ("Declarative application activity metadata", { try applicationActivityFollowsDeclarativeCatalogMetadata() }),
            ("Generated Rust requires trusted rule facts", { try await generatedRustSourcesRequireTrustedRulesAndFacts() }),
            ("Generated Rust retains authored sources", { try await generatedRustSourcesPreserveAuthoredFilesAndRequireLayout() }),
            ("Artifacts block tracked and active content", { try await generatedArtifactsBlockTrackedContentActiveBuildsAndUnknownFacts() }),
            ("Artifact changes immediately before moving preserve files", { try await artifactFactsChangingImmediatelyBeforeMovePreserveFiles() }),
            ("Binary-only Rust still checks activity and ownership", { try await binaryOnlyRustTargetsStillRequireActivityAndOwnershipFacts() }),
            ("Project build activity stays scoped; Cargo remains global", { try await projectScopedActivityDoesNotBlockUnrelatedRustOrSwiftProjects() }),
            ("Native build activity verifies current-process scope", { try nativeBuildActivityScopesCurrentProcessToItsWorkingDirectory() }),
            ("Artifact exceptions retain hard protections", { try await generatedArtifactExceptionsNeverBypassHardProtections() }),
            ("Generated Swift stays inside verified products", { try await generatedSwiftSourcesStayInsideVerifiedProducts() }),
            ("Cargo sources require exact per-crate evidence", { try await extractedCargoSourcesRequirePerCrateEvidenceAndExactHome() }),
            ("First scan built-in discovery and cleanup", { try await builtinDiscoveryWorksWithoutImport() }),
            ("Built-in disable invalidates evidence", { try await disablingBuiltinInvalidatesPlan() }),
            ("Built-in scope, namespace and presets", { try await builtinCatalogScopeAndNamespace() }),
            ("Built-in protected descendants", { try await builtinRulesPreserveProtectedDescendants() }),
            ("Storage and treemap accounting", { try storageAccountingAndTreemapConserveArea() }),
            ("Non-overlapping cleanup overview", { try await cleanupOverviewDoesNotDoubleCount() }),
            ("Unified review evidence and eligibility", { try await commonReviewGroupsEvidenceWithoutGrantingAuthority() }),
            ("Disabled imports and non-executable previews", { try await importIsDisabledAndPreviewCannotExecute() }),
            ("Trash and restore loop; replay refusal", { try await completeTrashRestoreLoopAndRepeatRefusal() }),
            ("Trash root comparison allows only directory ctime", { try trashRootComparisonAllowsOnlyDirectoryCTime() }),
            ("Verified Trash root ctime drift still restores", { try await trashRootCTimeChangeRestoresThroughBothVerificationLayers() }),
            ("Trash root ctime exception never authorizes cleanup", { try await trashRootCTimeExceptionNeverAuthorizesPlanExecution() }),
            ("Changed Trash metadata, identity and descendants stay blocked", { try await changedTrashMetadataIdentityAndDescendantsStillRefuseRestore() }),
            ("Full descendant manifest invalidation", { try await fullManifestDetectsDescendantChange() }),
            ("Configuration invalidation", { try await exclusionChangesInvalidatePlan() }),
            ("Protected descendants", { try await protectedDescendantBlocksParent() }),
            ("Opaque links preserve external targets", { try await internalLinkDoesNotTraverseOrPurgeOutside() }),
            ("Ancestor link refusal", { try ancestorLinksRefused() }),
            ("Explicit resource budget", { try budgetInterruptionExplicitlyPartial() }),
            ("Scan budgets survive planning; tampered budgets cannot execute", { try await scanBudgetsSurvivePlanningAndRejectTamperedEvidence() }),
            ("Partial root complete target cleanup and restore", { try await completeTargetInPartialRootCanExecuteAndRestore() }),
            ("Legacy and boundary coverage stay blocked", { try await absentOrUnrelatedCoverageCannotAuthorizeTarget() }),
            ("Execution reproduces target coverage", { try await lostExecutionCoverageRefusesPreviouslyValidPlan() }),
            ("Coverage does not bypass target changes", { try await changedTargetWithCoverageStillRefusesExecution() }),
            ("Selective discovery prunes protected trees", { try selectiveDiscoveryPrunesProtectedTreesWithinBudget() }),
            ("Selective fixed patterns skip unreachable subtrees", { try fixedSelectivePatternsAvoidUnreachableSubtrees() }),
            ("Selective targets retain manifests and markers", { try await matchedSelectiveTargetsRetainFullManifestsAndMarkers() }),
            ("Selective cleanup and restore use measured evidence", { try await selectiveEngineEvidencePlansOnlyMeasuredTargetsAndRestores() }),
            ("Native read-only artifact and retained archive facts", { try nativeArtifactFactsVerifyRetainedCargoSources() }),
            ("Cross-process mutation lock", { try crossProcessLockCannotBeAcquiredTwice() }),
            ("Restore conflict and Trash expansion", { try await restoreNeverOverwritesAndTrashExpansionBlocksPurge() }),
            ("Immutable rule versions", { try await identicalImportIsIdempotentAndMutationConflicts() }),
            ("Journal failure prevents mutation", { try await journalFailurePreventsMutation() }),
            ("Directory replacement refusal", { try await replacementDirectoryIsNotProcessed() }),
            ("Stored plans do not grant authority", { try await persistedPlanCannotBypassCurrentPolicy() }),
            ("Confirmation and partial-scan gates", { try await wrongConfirmationAndPartialScansCannotExecute() }),
            ("Store protection within workspace", { try await protectedStoreCannotBecomeCleanupTarget() }),
            ("Workspace removal preserves files", { try await workspaceRemovalPreservesFilesAndHistory() })
        ]
        for pattern in ["/tmp/cache", "../target", "**/../target", "**/foo**", "**/*", "*", "**", "a//target", "~/**/target", "${HOME}/target", "C:/target", "a\\target", "$(id)/target"] {
            cases.append(("Reject pattern \(pattern)", { try rejectsUnsafePatterns(pattern) }))
        }
        for field in ["shell", "schema_version", "action", "scope", "conditions"] {
            cases.append(("Reject contract field \(field)", { try rejectsContractViolations(field) }))
        }
        var failures=0
        let includeNativePurge=CommandLine.arguments.contains("--native-trash-purge")
        if CommandLine.arguments.contains("--native-trash") || includeNativePurge {
            let title=includeNativePurge ? "Complete catalog with native Trash, restoration, and explicit permanent removal" : "Complete catalog with native Trash and restoration"
            cases.append((title, { try await nativeCatalogCleanupAndRestore(includePurge: includeNativePurge) }))
        }
        for (name, run) in cases {
            do { try await run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(cases.count-failures)/\(cases.count) tests passed; all file mutations used isolated temporary fixtures.")
        if failures > 0 { Foundation.exit(1) }
    }
}
