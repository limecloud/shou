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
        if Array(CommandLine.arguments.dropFirst()) == ["--builtin-performance-only"] {
            do {
                try await builtinCatalogBindingPreservesValidationAndIsolation()
                print("1/1 built-in binding validation, isolation and benchmark checks passed.")
            } catch { print("FAIL built-in binding: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--native-activity-only"] {
            do {
                try nativeUninstallEvidenceReadsOnlyExplicitContainerMetadata()
                try nativeApplicationActivitySkipsOnlyKernelVerifiedZombies()
                try await nativeApplicationActivityKeepsLiveHelpersBlocked()
                try await nativeApplicationActivityKeepsUnlinkedHelpersBlocked()
                try nativeReadWorkerCancellationStopsOwnedChild()
                try nativeReadWorkerTimeoutStopsOwnedChildWithoutEvidence()
                print("6/6 native activity, unlinked executable and read-worker cancellation tests passed; generated fixtures only.")
            } catch { print("FAIL native activity: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--operation-progress-only"] {
            do {
                try executionProgressKeepsBatchTotalsAndPartialBoundaries()
                try await privacyProgressTracksSourcesAndCommittedOutcomes()
                try await privacyProgressCancellationPreservesRemainingSources()
                try await followUpProgressPreservesDurableCancellationBoundary()
                try await followUpProgressCountsFailedOutcomeWithoutOverwriting()
                print("5/5 operation progress, partial batches, privacy transactions and cancellation tests passed; generated fixtures only.")
            } catch { print("FAIL operation progress: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--rule-scan-progress-only"] {
            do {
                try await ruleScanProgressDoesNotResetAcrossWorkerAndPersistenceStages()
                try await batchScanProgressKeepsCountsAndPercentagesAcrossLocationsAndFailure()
                try await batchScanProgressCancellationDoesNotReportCompletion()
                try await systemScanPreparationIsLinearAndReportsRootBeforeIdentity()
                try await systemScanPreparationCancellationPreventsRegistration()
                try await systemScanRegistersBeforeEvidenceAndReportsPartial()
                print("6/6 rule-scan progress, worker phases, multi-location totals, failure and cancellation checks passed; generated fixtures only.")
            } catch { print("FAIL rule-scan progress: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--privacy-only"] {
            do {
                try await privacyChromiumRangePreservesUnselectedRelationsAndReceipts()
                try await privacyCookiesRequireSeparateConsentAndUseLastAccessTime()
                try await privacyFirefoxAndSafariEpochsPreserveBookmarksAndDownloads()
                try await privacyRefusesRunningStaleExcludedAndUnsupportedSources()
                try await privacyTransactionsRollbackAndUnknownSchemasStayUnavailable()
                try await privacyIntegerTimeBoundsAndUnknownCascadesAreConservative()
                print("6/6 privacy range, consent, schema and transaction tests passed; generated databases only.")
            } catch { print("FAIL privacy: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--applications-only"] {
            do {
                try await applicationSummariesStreamOneInventoryAndKeepOwnershipConservative()
                try nativeApplicationSummaryMeasuresWithoutManifestsOrLinkTraversal()
                try await uninstallBatchUsesOneReceiptAndRestoresTwoApplications()
                try await uninstallBatchDefaultPermanentCannotRestoreAndSingleTrashRemainsCompatible()
                try await uninstallBatchPreflightsAllAppsAndRejectsConsentRunningStaleAndOverlaps()
                try await uninstallPermanentRechecksActivityAtJournalBoundary()
                try await uninstallReviewSeparatesPersonalDataAndDoesNotModifyFiles()
                try await uninstallReviewIncludesOnlyVerifiedGroupContainers()
                try await uninstallCompleteLoopRestoresIndependentComponentOrigins()
                try await uninstallRefusesChangedEvidenceRunningApplicationsAndExcludedData()
                try await uninstallRechecksActivityAtTheJournalBoundary()
                try await uninstallCoverageGapsRequireExplicitChoicesAndConsentCannotBeForged()
                try await uninstallParentSiblingChangesPreservePlansButNotTargetChanges()
                try nativeUninstallEvidenceReadsOnlyExplicitContainerMetadata()
                try nativeApplicationActivitySkipsOnlyKernelVerifiedZombies()
                try await nativeApplicationActivityKeepsLiveHelpersBlocked()
                try await nativeApplicationActivityKeepsUnlinkedHelpersBlocked()
                try await uninstallActivityFailuresKeepTheirCauseAndAllowRetryWithoutMutation()
                print("18/18 application summary, batch and legacy uninstall safety tests passed; only generated fixtures were moved, restored or permanently removed.")
            } catch { print("FAIL applications: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-performance-only"] {
            do {
                try storageBulkMetadataPreservesExactStatEvidence()
                try storageCatalogParentIDsPreserveNestedNamesAndTotals()
                try storageParallelDirectoryBenchmark()
                try await storageDirectoryWorkersObserveParentTaskCancellation()
                print("4/4 bulk storage metadata, catalog parent-ID equivalence, directory benchmark and worker cancellation tests passed; generated fixtures only.")
            } catch { print("FAIL storage performance: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--scan-access-only"] {
            do {
                try scanAccessPolicyProtectsExactBoundaries()
                try await scanAccessSkipsContainersAndPreservesAccessibleCoverage()
                try cliInstallationIsRepeatableAndPreservesConflicts()
                try cliInstallationPreservesSymbolicLinks()
                print("4/4 scan access boundaries, partial/authorized coverage, CLI installation and conflict preservation tests passed; generated fixtures only.")
            } catch { print("FAIL scan access: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-catalog-only"] {
            do {
                try await storageCatalogScansLaterSiblingsAndLoadsExactDirectories()
                try await storageCatalogAccountsHardLinksAndOpaqueLinks()
                try await storageCatalogMarksUnreadableDirectoriesWithoutHidingSiblings()
                try await storageCatalogCancellationNeverPublishesAScan()
                print("4/4 streaming storage catalog, sibling coverage, hard-link accounting, permissions and cancellation tests passed; generated fixtures only.")
            } catch { print("FAIL storage catalog: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-large-files-only"] {
            do {
                try await storageLargeFilesFilterSavedEvidenceWithoutRescanning()
                try await storageLargeFileIndexPreservesThresholdBoundariesAndLegacyCatalogs()
                try await storageLargeFilesPageGloballyWithBinaryPathTies()
                try await storageLargeFilesPreserveLegacyHardLinkAccounting()
                try await storageLargeFilesRejectInvalidFiltersCursorsAndCatalogs()
                try await storageLargeFilesBoundResultsAndHonorCancellation()
                try await storageLargeFilesReuseReviewedRemovalAndRejectChangedEvidence()
                print("7/7 large-file filtering, index boundaries, stable pagination, legacy/catalog parity, validation, cancellation and stale removal-plan tests passed; generated fixtures only.")
            } catch { print("FAIL storage large files: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-catalog-million-only"] {
            do {
                try storageCatalogSupportsMoreThanAMillionEntries()
                print("1/1 catalog test passed with 1,000,005 generated file rows beyond the old scan cap.")
            } catch { print("FAIL million-row catalog: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-progress-only"] {
            do {
                try progressPresentationUsesKnownWorkAndCompactPaths()
                try await storageWorkerReportsPostScanStagesAndExactLimit()
                try storageWorkerPagesLargeResultsWithoutChangingEvidence()
                try await storagePagedResultsRoundTripAndRejectCorruption()
                try await storageCancellationDoesNotPublishIncompletePages()
                try storageIndexCanCancelAndKeepsAccounting()
                print("6/6 storage progress, compact paths, paged transport, persistence and cancellation tests passed; generated fixtures only.")
            } catch { print("FAIL storage progress: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-removal-only"] {
            do {
                try await storageReviewRefreshesDirectoryChangesBeforeConfirmation()
                try await storageIncompleteReviewReportsCauseAndRemainsRetryable()
                try await storageNativeRemovalReportsManifestProgress()
                try await storageAnalysisProtectsRootsAndDetectsChanges()
                try await storageRemovalRechecksCurrentExclusionsAndNewDescendants()
                try await storageNativeLargeFileTrashRestoreAndPermanentRemoval(permanent: true)
                print("6/6 storage review, retry, progress, stale evidence, exclusions and native deletion tests passed; generated fixtures only.")
            } catch { print("FAIL storage removal: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--history-retention-only"] {
            do {
                try await historyRetentionPreservesRecoveryAndNeverRemovesTargetFiles()
                try await historyRetentionPreservesActiveRecordsAndRejectsStoreEscapes()
                try storageCoverageSeparatesSystemLocationsFromUserAccess()
                print("3/3 history retention, recovery protection and actionable coverage tests passed; generated fixtures only.")
            } catch { print("FAIL history retention: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-million-only"] {
            do {
                let started=Date()
                try await storagePagedResultsRoundTripAndRejectCorruption(count: 1_000_000)
                print("1/1 million-entry storage round-trip passed in \(Date().timeIntervalSince(started)) seconds; generated metadata only.")
            } catch { print("FAIL million-entry storage: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--discovery-only"] {
            do {
                try await projectDiscoveryFindsCollectionsWithoutRegistrationAndReusesPolicy()
                try await projectDiscoveryRespectsExplicitNestedScopeAndDisabledRules()
                try await projectDiscoveryCancellationStopsBeforeRegistration()
                try await enabledPersonalRulesJoinRepeatedCleanupWithoutReselecting()
                print("4/4 automatic discovery and repeated-cleanup tests passed; only generated fixtures were used.")
            } catch { print("FAIL automatic discovery: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-only"] {
            do {
                try storageSelectionPreservesSiblingsAndDeduplicates()
                try await storageAnalysisProtectsRootsAndDetectsChanges()
                try await storageRemovalRechecksCurrentExclusionsAndNewDescendants()
                try await storageNativeLargeFileTrashRestoreAndPermanentRemoval(permanent: true)
                print("4/4 storage tests passed; only generated fixtures were mutated.")
            } catch { print("FAIL storage tests: \(error)"); Foundation.exit(1) }
            return
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--history-interruption-child" {
            do { try await historyInterruptionChild(CommandLine.arguments[2]) }
            catch { Foundation.exit(1) }
            Foundation.exit(1)
        }
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
        if Array(CommandLine.arguments.dropFirst()) == ["--installed-caches-only"] {
            do {
                try await installedApplicationCachesUseNormalCleanupWithoutUninstalling()
                try await installedApplicationCachesKeepActivityAndIdentityGates()
                try await installedApplicationCachesRecheckAtEachMutationBoundary()
                try await installedApplicationCachesRespectStaticScopeAndDisabledRules()
                try await installedApplicationCachesRetainSharedProtectionAndNoFollowBoundaries()
                try await installedApplicationCachesReportInventoryGapsAndAmbiguousOwners()
                try await installedApplicationCachesKeepLegacyRecordsAndBindEvidenceDigests()
                print("7/7 installed-application cache discovery, ownership, activity, shared cleanup and compatibility tests passed; generated fixtures only.")
            } catch { print("FAIL installed application caches: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--mole-rules-only"] {
            do {
                try await moleRulesKeepProfilesGamesAndDeveloperState()
                try await moleRulesRetainProtectedContentsAndPlatformBoundaries()
                print("2/2 Mole path migration boundary and protection tests passed; generated fixtures only.")
            } catch { print("FAIL Mole rule coverage: \(error)"); Foundation.exit(1) }
            return
        }
        var cases: [(String, () async throws -> Void)] = [
            ("Execution progress preserves batch totals and partial boundaries", { try executionProgressKeepsBatchTotalsAndPartialBoundaries() }),
            ("Privacy progress follows committed source outcomes", { try await privacyProgressTracksSourcesAndCommittedOutcomes() }),
            ("Privacy progress cancellation preserves remaining sources", { try await privacyProgressCancellationPreservesRemainingSources() }),
            ("Installed application caches use ordinary cleanup and preserve applications", { try await installedApplicationCachesUseNormalCleanupWithoutUninstalling() }),
            ("Installed application cache activity and identity are revalidated", { try await installedApplicationCachesKeepActivityAndIdentityGates() }),
            ("Installed application caches recheck at each mutation boundary", { try await installedApplicationCachesRecheckAtEachMutationBoundary() }),
            ("Installed application caches preserve static scope and disabled rules", { try await installedApplicationCachesRespectStaticScopeAndDisabledRules() }),
            ("Installed application caches retain shared protection and no-follow boundaries", { try await installedApplicationCachesRetainSharedProtectionAndNoFollowBoundaries() }),
            ("Installed application cache discovery reports incomplete and ambiguous owners", { try await installedApplicationCachesReportInventoryGapsAndAmbiguousOwners() }),
            ("Installed application cache evidence preserves legacy digests", { try await installedApplicationCachesKeepLegacyRecordsAndBindEvidenceDigests() }),
            ("Disk access policy preserves exact protected boundaries", { try scanAccessPolicyProtectsExactBoundaries() }),
            ("Limited scan retains accessible sibling coverage", { try await scanAccessSkipsContainersAndPreservesAccessibleCoverage() }),
            ("CLI installation preserves arguments and conflicting entries", { try cliInstallationIsRepeatableAndPreservesConflicts() }),
            ("CLI installation preserves symbolic links", { try cliInstallationPreservesSymbolicLinks() }),
            ("Bulk metadata preserves exact stat evidence", { try storageBulkMetadataPreservesExactStatEvidence() }),
            ("Catalog parent IDs preserve nested names and totals", { try storageCatalogParentIDsPreserveNestedNamesAndTotals() }),
            ("Directory workers observe parent task cancellation", { try await storageDirectoryWorkersObserveParentTaskCancellation() }),
            ("Streaming storage catalog measures later siblings", { try await storageCatalogScansLaterSiblingsAndLoadsExactDirectories() }),
            ("Storage catalog deduplicates hard links without following symlinks", { try await storageCatalogAccountsHardLinksAndOpaqueLinks() }),
            ("Storage catalog exposes unreadable directory coverage", { try await storageCatalogMarksUnreadableDirectoriesWithoutHidingSiblings() }),
            ("Cancelled storage catalog is never published", { try await storageCatalogCancellationNeverPublishesAScan() }),
            ("Large-file filters reuse saved evidence without rescanning", { try await storageLargeFilesFilterSavedEvidenceWithoutRescanning() }),
            ("Large-file index preserves threshold boundaries and legacy catalogs", { try await storageLargeFileIndexPreservesThresholdBoundariesAndLegacyCatalogs() }),
            ("Large-file pagination keeps global binary path order", { try await storageLargeFilesPageGloballyWithBinaryPathTies() }),
            ("Large-file legacy and catalog hard-link accounting agree", { try await storageLargeFilesPreserveLegacyHardLinkAccounting() }),
            ("Large-file filters and cursors reject invalid evidence", { try await storageLargeFilesRejectInvalidFiltersCursorsAndCatalogs() }),
            ("Large-file result pages stay bounded and cancellable", { try await storageLargeFilesBoundResultsAndHonorCancellation() }),
            ("Large-file selections retain removal-plan revalidation", { try await storageLargeFilesReuseReviewedRemovalAndRejectChangedEvidence() }),
            ("Storage progress reports exact limit and post-scan stages", { try await storageWorkerReportsPostScanStagesAndExactLimit() }),
            ("Progress uses known work and compact paths", { try progressPresentationUsesKnownWorkAndCompactPaths() }),
            ("History retention preserves recovery and target files", { try await historyRetentionPreservesRecoveryAndNeverRemovesTargetFiles() }),
            ("History retention protects active records and store boundaries", { try await historyRetentionPreservesActiveRecordsAndRejectsStoreEscapes() }),
            ("Storage coverage distinguishes system and user access", { try storageCoverageSeparatesSystemLocationsFromUserAccess() }),
            ("Storage review refreshes directory changes before confirmation", { try await storageReviewRefreshesDirectoryChangesBeforeConfirmation() }),
            ("Storage incomplete review stays retryable", { try await storageIncompleteReviewReportsCauseAndRemainsRetryable() }),
            ("Storage native removal reports manifest progress", { try await storageNativeRemovalReportsManifestProgress() }),
            ("Paged read worker preserves evidence and cancels loading", { try storageWorkerPagesLargeResultsWithoutChangingEvidence() }),
            ("Large storage pages round-trip and reject corruption", { try await storagePagedResultsRoundTripAndRejectCorruption() }),
            ("Storage cancellation does not publish incomplete pages", { try await storageCancellationDoesNotPublishIncompletePages() }),
            ("Storage index cancels without changing accounting", { try storageIndexCanCancelAndKeepsAccounting() }),
            ("SHA-256 known vector", { try sha256KnownVector() }),
            ("Schema and round trip", { try ruleSchemaAndRoundTrip() }),
            ("Personal draft authoring uses the closed portable contract", { try personalDraftUsesClosedContractAndPortableFields() }),
            ("Exact folder authoring cannot broaden workspace scope", { try exactPersonalRuleSelectionCannotExpandItsScope() }),
            ("Personal draft preview explains conditions and stays disabled", { try await personalDraftPreviewExplainsConditionsAndPreservesDisabledState() }),
            ("Personal draft age explanations preserve decision boundaries", { try await personalDraftAgeExplanationUsesCandidateDecisionBoundary() }),
            ("Wildcard semantics", { try wildcardSemantics() }),
            ("Wildcard language equivalence", { try wildcardMatcherPreservesLanguage() }),
            ("Wildcard descendant-prefix soundness", { try wildcardPrefixReachabilityPreservesMatches() }),
            ("Windows full identity, SID ownership and legacy records", { try windowsIdentityPreservesFileIDOwnerAndLegacyRecords() }),
            ("Windows volume changes cannot use POSIX remount compatibility", { try await windowsVolumeChangesCannotUsePOSIXRemountCompatibility() }),
            ("Uncertain native mutations preserve observed paths and block replay", { try await uncertainNativeMutationsPreserveObservedPathsAndBlockReplay() }),
            ("Uncertain permanent removal persists intent and blocks replay", { try await uncertainPermanentRemovalPersistsIntentAndBlocksReplay() }),
            ("Canonical digest", { try canonicalDigestIndependentOfObjectKeyOrder() }),
            ("JSON envelope escaping", { try envelopeUsesStableKeysAndExplicitNull() }),
            ("UTC decision precision", { try utcTimestampsPreserveDecisionPrecision() }),
            ("Chinese desktop default and saved language", { try desktopLanguageDefaultsAndSavedChoice() }),
            ("Runtime localization switches in both directions", { try localizedResourcesSwitchWithoutProcessRestart() }),
            ("Privacy ranges preserve unselected relations and receipts", { try await privacyChromiumRangePreservesUnselectedRelationsAndReceipts() }),
            ("Privacy cookies require separate consent and use last access time", { try await privacyCookiesRequireSeparateConsentAndUseLastAccessTime() }),
            ("Privacy epochs preserve bookmarks and downloads", { try await privacyFirefoxAndSafariEpochsPreserveBookmarksAndDownloads() }),
            ("Privacy refuses running, stale, excluded and unsupported sources", { try await privacyRefusesRunningStaleExcludedAndUnsupportedSources() }),
            ("Privacy transactions roll back and unknown schemas stay unavailable", { try await privacyTransactionsRollbackAndUnknownSchemasStayUnavailable() }),
            ("Privacy integer time bounds, WAL and unknown cascades", { try await privacyIntegerTimeBoundsAndUnknownCascadesAreConservative() }),
            ("Application discovery validates before read and cancellation", { try await applicationCatalogValidatesBeforeReadAndHonorsCancellation() }),
            ("Application catalog preserves distinct paths and explicit scope", { try nativeApplicationCatalogPreservesDistinctPathsAndBoundsItsScope() }),
            ("Application catalog rejects unsafe metadata with explicit gaps", { try nativeApplicationCatalogRejectsUnsafeMetadataWithoutHidingCoverageGaps() }),
            ("File targets bind bounded content and preserve legacy manifests", { try fileTargetsRequireBoundedContentEvidenceAndKeepLegacyManifestsStable() }),
            ("Uninstall preview separates personal data without file mutation", { try await uninstallReviewSeparatesPersonalDataAndDoesNotModifyFiles() }),
            ("Application summaries stream one inventory and conservative ownership", { try await applicationSummariesStreamOneInventoryAndKeepOwnershipConservative() }),
            ("Native application summaries avoid manifests and link traversal", { try nativeApplicationSummaryMeasuresWithoutManifestsOrLinkTraversal() }),
            ("Application batch uses one receipt and restores two applications", { try await uninstallBatchUsesOneReceiptAndRestoresTwoApplications() }),
            ("Application batch permanent default cannot restore; single Trash remains compatible", { try await uninstallBatchDefaultPermanentCannotRestoreAndSingleTrashRemainsCompatible() }),
            ("Application batch preflights consent, activity, stale evidence and overlaps", { try await uninstallBatchPreflightsAllAppsAndRejectsConsentRunningStaleAndOverlaps() }),
            ("Permanent uninstall rechecks activity before mutation intent", { try await uninstallPermanentRechecksActivityAtJournalBoundary() }),
            ("Uninstall includes only verified shared group containers", { try await uninstallReviewIncludesOnlyVerifiedGroupContainers() }),
            ("Uninstall restores independent component origins", { try await uninstallCompleteLoopRestoresIndependentComponentOrigins() }),
            ("Uninstall refuses stale evidence, running apps, sharing and exclusions", { try await uninstallRefusesChangedEvidenceRunningApplicationsAndExcludedData() }),
            ("Uninstall rechecks activity before mutation intent", { try await uninstallRechecksActivityAtTheJournalBoundary() }),
            ("Uninstall coverage gaps and personal-data consent resist tampering", { try await uninstallCoverageGapsRequireExplicitChoicesAndConsentCannotBeForged() }),
            ("Uninstall parent siblings preserve identity without weakening target checks", { try await uninstallParentSiblingChangesPreservePlansButNotTargetChanges() }),
            ("Native uninstall activity and explicit container metadata", { try nativeUninstallEvidenceReadsOnlyExplicitContainerMetadata() }),
            ("Native application activity skips only kernel-verified zombies", { try nativeApplicationActivitySkipsOnlyKernelVerifiedZombies() }),
            ("Native application activity preserves live helper protection", { try await nativeApplicationActivityKeepsLiveHelpersBlocked() }),
            ("Native application activity preserves unlinked helper protection", { try await nativeApplicationActivityKeepsUnlinkedHelpersBlocked() }),
            ("Uninstall activity failures preserve their cause and allow a clean retry", { try await uninstallActivityFailuresKeepTheirCauseAndAllowRetryWithoutMutation() }),
            ("Startup discovery validates before read and cancellation", { try await startupInventoryValidatesBeforeReadingAndHonorsCancellation() }),
            ("Startup control requires explicit capability and action", { try await startupControlRequiresPlatformCapabilityAndForwardsExplicitAction() }),
            ("Launchctl state parsing stays bounded and explicit", { try launchctlStateParsersKeepOnlyDocumentedStates() }),
            ("Native startup control refuses system and out-of-scope definitions", { try nativeStartupControlRefusesSystemAndOutOfScopeDefinitions() }),
            ("Startup definitions keep state unknown and omit credentials", { try nativeStartupInventoryKeepsStateUnknownAndOmitsSecrets() }),
            ("Startup discovery rejects links, special and invalid definitions", { try nativeStartupInventoryRejectsUnsafeAndInvalidDefinitions() }),
            ("Startup discovery retains explicit budget gaps", { try nativeStartupInventoryReportsBudgetGapsWithoutLosingValidItems() }),
            ("Explicit platform-scoped known locations", { try knownLocationsAreExplicitAndPlatformScoped() }),
            ("Automatic project discovery reuses scope and exclusions", { try await projectDiscoveryFindsCollectionsWithoutRegistrationAndReusesPolicy() }),
            ("Project discovery respects explicit nested policy", { try await projectDiscoveryRespectsExplicitNestedScopeAndDisabledRules() }),
            ("Project discovery cancels before registration", { try await projectDiscoveryCancellationStopsBeforeRegistration() }),
            ("Enabled personal rules join repeated cleanup", { try await enabledPersonalRulesJoinRepeatedCleanupWithoutReselecting() }),
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
            ("Rule-scan progress remains cumulative across worker phases", { try await ruleScanProgressDoesNotResetAcrossWorkerAndPersistenceStages() }),
            ("Batch scan progress remains cumulative across locations and failure", { try await batchScanProgressKeepsCountsAndPercentagesAcrossLocationsAndFailure() }),
            ("Batch scan cancellation does not invent completion", { try await batchScanProgressCancellationDoesNotReportCompletion() }),
            ("Preparation cancellation prevents root registration", { try await systemScanPreparationCancellationPreventsRegistration() }),
            ("Fixed app rules retain personal data", { try await fixedApplicationRulesPreserveUserDataAndSecrets() }),
            ("Known location configuration reuse", { try await knownLocationRegistrationReusesConfiguration() }),
            ("Batch evidence and partial results", { try await systemScanRegistersBeforeEvidenceAndReportsPartial() }),
            ("Application activity policy and revalidation", { try await applicationActivityBlocksAndRechecksExecution() }),
            ("Expanded cache and user-data boundaries", { try await expandedCatalogKeepsCacheAndUserDataBoundaries() }),
            ("Expanded application secret protection", { try await expandedApplicationCacheSecretsRemainProtected() }),
            ("Mole cache migration preserves profiles and developer state", { try await moleRulesKeepProfilesGamesAndDeveloperState() }),
            ("Mole declarations retain protection and platform boundaries", { try await moleRulesRetainProtectedContentsAndPlatformBoundaries() }),
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
            ("Built-in binding validation, isolation and benchmark", { try await builtinCatalogBindingPreservesValidationAndIsolation() }),
            ("Built-in protected descendants", { try await builtinRulesPreserveProtectedDescendants() }),
            ("Storage selection preserves siblings and deduplicates", { try storageSelectionPreservesSiblingsAndDeduplicates() }),
            ("Storage analysis separates read scope and stale removal", { try await storageAnalysisProtectsRootsAndDetectsChanges() }),
            ("Storage removal rechecks exclusions and new descendants", { try await storageRemovalRechecksCurrentExclusionsAndNewDescendants() }),
            ("Native space analysis large-file Trash restore and permanent removal", { try await storageNativeLargeFileTrashRestoreAndPermanentRemoval(permanent: CommandLine.arguments.contains("--native-trash-purge")) }),
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
            ("Global exclusions protect current/future roots and reject forged plans", { try await globalExclusionsProtectAllRootsAndRejectForgedPlans() }),
            ("Project exclusions remain literal and workspace-scoped", { try await projectExclusionsStayLiteralAndScopedToTheirWorkspace() }),
            ("Global exclusion storage preserves legacy and downgrade boundaries", { try await globalExclusionStorageRetainsLegacyAndDowngradeBoundaries() }),
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
            ("Rule revisions stay disabled and invalidate old evidence", { try await revisedRuleStaysDisabledAndInvalidatesOldEvidence() }),
            ("Journal failure prevents mutation", { try await journalFailurePreventsMutation() }),
            ("History inspection preserves receipts and verifies conflict and restore", { try await historyInspectionPreservesRecordsAndDetectsConflictChangesAndRestore() }),
            ("History inspection blocks changed and bounded evidence", { try await historyInspectionBlocksChangedAndBudgetLimitedEvidence() }),
            ("Per-item journal boundaries survive write failure", { try await perItemJournalFailuresNeverLookLikeSkippedWork() }),
            ("Follow-up cancellation preserves unstarted items and completed receipts", { try await followUpCancellationPreservesUnstartedItemsAndCompletedReceipts() }),
            ("Follow-up eligibility stays isolated by execution", { try await followUpEligibilityIsIsolatedByExecution() }),
            ("Follow-up progress preserves durable cancellation boundaries", { try await followUpProgressPreservesDurableCancellationBoundary() }),
            ("Follow-up progress counts failed outcomes without overwriting", { try await followUpProgressCountsFailedOutcomeWithoutOverwriting() }),
            ("Unfinished restore is never retried by inspection", { try await unfinishedRestoreIsObservedWithoutRetryingOrRewriting() }),
            ("Process exit after move preserves intent and rejects replay", { try await processExitAfterMovingRetainsIntentAndCannotReplay() }),
            ("Directory replacement refusal", { try await replacementDirectoryIsNotProcessed() }),
            ("Stored plans do not grant authority", { try await persistedPlanCannotBypassCurrentPolicy() }),
            ("Confirmation and partial-scan gates", { try await wrongConfirmationAndPartialScansCannotExecute() }),
            ("Store protection within workspace", { try await protectedStoreCannotBecomeCleanupTarget() }),
            ("Workspace removal preserves files", { try await workspaceRemovalPreservesFilesAndHistory() }),
            ("Workspace root remount refreshes binding", { try await workspaceRootRemountRefreshesBinding() })
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
            cases.append(("Native file Trash and conflict-safe restoration", { try await nativeFileTargetTrashAndConflictSafeRestore() }))
            cases.append(("Native uninstall and independent restoration of generated components", { try await uninstallCompleteLoopRestoresIndependentComponentOrigins(nativeTrash: true) }))
            cases.append(("Native Trash cancellation after intent completes one item and restores", { try await nativeTrashCancellationAfterIntentFinishesOneItemAndRestores() }))
            if includeNativePurge { cases.append(("Native permanent plan purges only its bound fixture target", { try await nativePermanentPlanPurgesOnlyBoundTarget() })) }
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
