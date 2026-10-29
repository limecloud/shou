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
        #if DEBUG && os(macOS)
        if Array(CommandLine.arguments.dropFirst()) == ["--authorization-only"] {
            do {
                try await nativeSystemAuthorizationProtocolFixtures()
                print("Authorization session reuse, lost-response non-replay, frame/scope rejection and staged Trash fixtures passed; no native administrator prompt was opened.")
            } catch { print("FAIL authorization: \(error)"); Foundation.exit(1) }
            return
        }
        #endif
        if Array(CommandLine.arguments.dropFirst()) == ["--system-monitor-only"] {
            do {
                try monitorRatesRequireFreshStableCounters()
                try monitorHandlesGroupsReuseMissingDataAndBoundsHistory()
                try await monitorSessionRejectsLateResultsAndStopsWhenHidden()
                try await nativeMonitorReadsWithoutMutation()
                print("4/4 system monitor rate, identity, lifecycle and read-only native checks passed.")
            } catch { print("FAIL system monitor: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--application-updates-only"] {
            do {
                try applicationUpdatesCompareOnlyVerifiedNumericVersions()
                try applicationUpdatesBindCatalogIdentityAndSystemVariants()
                try await applicationUpdatesRejectChangedAppsAndKeepFailedChecksUnknown()
                try await applicationUpdatesTransportBoundsAndSanitizesFailures()
                print("4/4 application update catalog identity, numeric versions, platform variants, stale observations and bounded transport checks passed.")
            } catch { print("FAIL application updates: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-comparison-only"] {
            do {
                try await storageComparisonMergesWideDirectoriesAndBoundsRanking()
                try await storageComparisonRetainsUnknownCoverageAndRejectsReplacedRoots()
                try await storageComparisonBoundsHistoryAndHonorsCancellation()
                try await storageComparisonUsesNativeAllocatedAccounting()
                print("4/4 storage comparison identity, coverage, bounded merge, history and native accounting checks passed.")
            } catch { print("FAIL storage comparison: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--diagnostics-only"] {
            do {
                try diagnosticsDistinguishesUnknownAndLowCapacity()
                try nativeDiagnosticsPreservesRecordsAndExcludesPrivateData()
                try await nativeDiagnosticsHonorsCancellation()
                print("3/3 diagnostic capacity, privacy, no-write and cancellation checks passed.")
            } catch { print("FAIL diagnostics: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--ai-safety-only"] {
            do {
                try aiInvestigationPreservesConnectionAndPhysicalSelectionBoundaries()
                try await aiDecisionProvidersAreReplaceableAndRevokedCredentialsCannotSend()
                try aiLocalCredentialsRemainPrivateAndIndependent()
                print("3/3 AI connection, scope, provider substitution, request revocation and private local credential checks passed; generated fixtures only.")
            } catch { print("FAIL AI boundaries: \(error)"); Foundation.exit(1) }
            return
        }
        if let status=NativeReadWorker.runIfRequested(Array(CommandLine.arguments.dropFirst())) { Foundation.exit(status) }
        if Array(CommandLine.arguments.dropFirst()) == ["--receipt-journal-only"] {
            do {
                try await largeReceiptJournalRetainsRecoveryWithoutRewritingManifests()
                try await largeReceiptJournalFailuresPreserveDurableMutationIntent()
                print("2/2 large journal dependency, recovery, retention and interrupted-intent checks passed.")
            } catch { print("FAIL large receipt journal: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--native-cleanup-concurrency-only"] {
            do {
                try await nativeCleanupConcurrencyPreservesRealFilesystemEvidence()
                print("1/1 native cleanup concurrency evidence-parity check passed.")
            } catch { print("FAIL native cleanup concurrency: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--application-orphans-only"] {
            do {
                try await applicationOrphansRequireAbsenceConsentAndReuseDeletionJournals()
                try await applicationOrphansRespectUnknownOwnersExclusionsAndChangedContents()
                print("2/2 orphan absence, consent, exclusion, stale selection, permanent deletion and Trash recovery checks passed.")
            } catch { print("FAIL application leftovers: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--rule-opportunities-only"] {
            do {
                try await agentRuleLoopMeasuresAdditionalCoverageAndPersistsReuse()
                print("1/1 agent discovery, draft benefit, explicit enablement and persisted reuse checks passed.")
            } catch { print("FAIL agent rule loop: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--personal-rules-only"] {
            do {
                try personalDraftUsesClosedContractAndPortableFields()
                try exactPersonalRuleSelectionCannotExpandItsScope()
                try await personalRuleRevisionsPreserveBindingsAndRejectStaleSaves()
                try await personalDraftPreviewExplainsConditionsAndPreservesDisabledState()
                try await personalDraftAgeExplanationUsesCandidateDecisionBoundary()
                print("5/5 personal rule authoring, immutable revisions, stale saves and preview checks passed; isolated fixtures only.")
            } catch { print("FAIL personal rule authoring: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--tool-cleanup-only"] {
            do {
                try await toolCleanupUsesFixedOwnerOperationsAndVerifiesOutcomes()
                try await toolCleanupRejectsRemoteStaleAndUnknownOutcomes()
                try await toolCleanupExpiresDuringOwnerPreview()
                try nativeToolAdapterBoundsRealFixtureProcesses()
                print("4/4 tool cleanup, executable binding, expiry and native bounded-process checks passed; generated tools only.")
            } catch { print("FAIL tool cleanup: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--mysql-administration-only"] {
            do {
                try await mysqlAdminUsesExactHostAndSingleUseSecretFreeReviews()
                try await mysqlAdminRejectsStaleServersExistingAccountsAndUnjournaledChanges()
                try await mysqlAdminKeepsPartialOutcomesAndRejectsSystemBackups()
                try mysqlConfigurationRejectsChangesLinksAndKeepsSourceScope()
                try await mysqlInstanceRegistrationBindsReviewsAndRequiresDurableIntent()
                let native=try await mysqlNativeAdministrationUsesGeneratedActualEngine()
                print("5/5 MySQL administration contract/file/registration checks passed. Actual generated MySQL engine: \(native ? "passed" : "SKIPPED (SHOU_TEST_MYSQL_BIN not set)").")
            } catch { print("FAIL MySQL administration: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--developer-configuration-only"] {
            do {
                try developerConfigurationFilesPreserveIdentityAndSoftwarePaths()
                try developerConfigurationAdaptersDiscoverSoftwareScopesWithoutExecutingPrograms()
                try developerConfigurationFormatsPreserveExactFilesAndRejectUnknownWrites()
                try await developerLogsRequireExactSingleUseReviewsAndPreserveOpenFileIdentity()
                print("4/4 developer configuration and permanent log-cleanup scope, identity and secret-free journal checks passed; generated fixtures only.")
            } catch { print("FAIL developer configuration: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--developer-tools-only"] {
            do {
                try developerCatalogCoversCategoriesWithoutInventingSources()
                try await developerToolsRequireFrozenSingleUsePlansAndJournalResults()
                try await developerToolsRejectIdentityDriftExpiryAndUnrecordedMutation()
                try await developerToolsDoNotTreatManagerCompletionAsSuccess()
                try await nativeDeveloperToolsUseGeneratedExactInstallAndUninstall()
                try developerDiscoveryPreservesMultipleCopiesWithoutExecutingThem()
                try aiWorkspaceSummarizesNamesWithoutExposingPrivateValues()
                try await developerServiceSwitchesBindSourcesAndVerifyJournaledOutcomes()
                try await nativeDeveloperServicesPreserveLoginRegistrationUsingGeneratedManager()
                try await developerServiceRestartRequiresVerifiedStopBeforeStart()
                try await developerServicesLoadOnlySelectedToolsWithoutDiscardingOtherObservations()
                try await nativeDeveloperInstancesSeparateAndRestartGeneratedDatabases()
                try await nativeDeveloperLaunchdRestartsGeneratedKeepAliveWithoutRegistrationChanges()
                try developerConfigurationFilesPreserveIdentityAndSoftwarePaths()
                try developerConfigurationAdaptersDiscoverSoftwareScopesWithoutExecutingPrograms()
                try developerConfigurationFormatsPreserveExactFilesAndRejectUnknownWrites()
                try await developerLogsRequireExactSingleUseReviewsAndPreserveOpenFileIdentity()
                try await developerPackageUninstallRejectsRunningGeneratedImagesAndAmbiguousPaths()
                print("18/18 developer catalog, scoped loading, authorization, multi-instance isolation, generated KeepAlive restart, configuration, permanent log cleanup, uninstall activity and private AI checks passed; generated fixtures only.")
            } catch { print("FAIL developer tools: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--package-updates-only"] {
            do {
                try await packageUpdatesFreezeExactSelectionsAndVerifyInstalledVersions()
                try await packageUpdatesRecognizeFrozenTargetsReachedByDependencies()
                try await packageUpdatesRejectStaleChangedPinnedAndUnknownSelections()
                try await packageUpdatesRejectMalformedIdentitiesAndPreserveGlobalMiseRanges()
                try await packageUpdatesInterruptedOrUnverifiedInstallsRemainUnknown()
                try nativePackageUpdatesUseOnlyGlobalExactGeneratedCommands()
                print("6/6 package update scope, frozen identity, interruption and generated native-command checks passed.")
            } catch { print("FAIL package updates: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--application-closing-only"] {
            do {
                try await applicationClosingVerifiesIdentityAndReportsRemainingOwners()
                print("1/1 application-close identity, confirmation, single use, settings, remaining-process and no-file-mutation checks passed.")
            } catch { print("FAIL application closing: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--record-retention-only"] {
            do {
                try await recordRetentionProtectsActivePlansAndRecoveryWithZeroQuota()
                try await recordRetentionPreservesDependenciesAndRejectsChangedRecords()
                try await historySummariesPageAndInvalidateWithoutChangingRecoveryEvidence()
                print("3/3 derived-record retention, reference protection and history-summary checks passed.")
            } catch { print("FAIL record retention: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--permanent-removal-only"] {
            do {
                try nativePermanentRemovalReportsProgressForDeepDirectories()
                try nativePermanentRemovalRejectsReplacedCachedDirectories()
                try nativePermanentRemovalPreservesNewUnplannedFiles()
                try await permanentRemovalContinuesPastPermissionFailuresAndLaterTargets()
                try nativePermanentRemovalHandlesNestedAndRetainedHardLinks()
                try await permanentRuleBatchHandlesHardLinksAcrossTargets()
                try await permanentStorageBatchHandlesSharedFilesAndDirectories()
                try permanentRemovalStillRejectsExternallyChangedHardLinks()
                try permanentRemovalContextRejectsUnrelatedMetadataChanges()
                try await permanentBatchRefusesExternalChangeAfterItsOwnUnlink()
                try await trashFollowUpPurgesHardLinksAcrossRecordedTargets()
                print("11/11 native permanent-removal checks passed; generated fixtures only.")
            } catch { print("FAIL permanent removal: \(error)"); Foundation.exit(1) }
            return
        }
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
                try await uninstallContainerWorkersCancelAndTimeoutWithoutBlockingReview()
                try nativeApplicationActivitySkipsOnlyKernelVerifiedZombies()
                try await nativeApplicationActivityKeepsLiveHelpersBlocked()
                try await nativeApplicationActivityKeepsUnlinkedHelpersBlocked()
                try nativeReadWorkerCancellationStopsOwnedChild()
                try nativeReadWorkerTimeoutStopsOwnedChildWithoutEvidence()
                print("7/7 native activity, unlinked executable and read-worker cancellation tests passed; generated fixtures only.")
            } catch { print("FAIL native activity: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--operation-progress-only"] {
            do {
                try executionProgressKeepsBatchTotalsAndPartialBoundaries()
                try executionProgressRejectsLateStageAndEntryCallbacks()
                try await privacyProgressTracksSourcesAndCommittedOutcomes()
                try await privacyProgressCancellationPreservesRemainingSources()
                try await followUpProgressPreservesDurableCancellationBoundary()
                try await followUpProgressCountsFailedOutcomeWithoutOverwriting()
                print("6/6 operation progress, late callbacks, partial batches, privacy transactions and cancellation tests passed; generated fixtures only.")
            } catch { print("FAIL operation progress: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--rule-scan-progress-only"] {
            do {
                try await cleanupScanUsesBoundedWorkersAndPreservesSerialResults()
                try await systemScanHonorsPlatformReadConcurrency()
                try await workerBackedSystemScanBoundsConcurrentReadsWithoutLosingRoots()
                try await ruleScanProgressDoesNotResetAcrossWorkerAndPersistenceStages()
                try await batchScanProgressKeepsCountsAndPercentagesAcrossLocationsAndFailure()
                try await batchScanProgressCancellationDoesNotReportCompletion()
                try await systemScanPreparationIsLinearAndReportsRootBeforeIdentity()
                try await systemScanPreparationCancellationPreventsRegistration()
                try await systemScanRegistersBeforeEvidenceAndReportsPartial()
                print("9/9 cleanup concurrency, platform capacity, isolated workers, progress, multi-location totals, failure and cancellation checks passed; generated fixtures only.")
            } catch { print("FAIL rule-scan progress: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--privacy-discovery-only"] {
            do {
                try await privacyDiscoveryPermissionFailureKeepsAccessibleSources()
                try await privacyDiscoveryRejectsLinkedRootsAndPreservesLimitsAndCancellation()
                print("2/2 privacy discovery permission, no-follow, limit and cancellation tests passed; generated fixtures only.")
            } catch { print("FAIL privacy discovery: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--privacy-only"] {
            do {
                try await privacyDiscoveryPermissionFailureKeepsAccessibleSources()
                try await privacyDiscoveryRejectsLinkedRootsAndPreservesLimitsAndCancellation()
                try await privacyChromiumRangePreservesUnselectedRelationsAndReceipts()
                try await privacyCookiesRequireSeparateConsentAndUseLastAccessTime()
                try await privacyFirefoxAndSafariEpochsPreserveBookmarksAndDownloads()
                try await privacyRefusesRunningStaleExcludedAndUnsupportedSources()
                try await privacyTransactionsRollbackAndUnknownSchemasStayUnavailable()
                try await privacyIntegerTimeBoundsAndUnknownCascadesAreConservative()
                try await privacyChangedMiddleSourceDoesNotBlockIndependentSources()
                print("9/9 privacy discovery, range, consent, schema, platform policy, access lease and transaction tests passed; generated databases only.")
            } catch { print("FAIL privacy: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--applications-only"] {
            do {
                try await applicationCatalogValidatesBeforeReadAndHonorsCancellation()
                try nativeApplicationCatalogPreservesDistinctPathsAndBoundsItsScope()
                try nativeApplicationCatalogRejectsUnsafeMetadataWithoutHidingCoverageGaps()
                try nativeApplicationCatalogSupportsNestedSingleSegmentAndLinkedApplications()
                try await uninstallMissingMetadataKeepsAssociationsAndRestoresBundle()
                try await uninstallHardLinkedBundleUsesTrashAndPreservesExternalContent()
                try await uninstallUserInstalledAppleAppsAndSingleSegmentIdentifiers()
                try await applicationSummariesStreamOneInventoryAndKeepOwnershipConservative()
                try nativeApplicationSummaryMeasuresWithoutManifestsOrLinkTraversal()
                try await uninstallBatchUsesOneReceiptAndRestoresTwoApplications()
                try await uninstallBatchDefaultPermanentCannotRestoreAndSingleTrashRemainsCompatible()
                try await uninstallBatchContinuesIndependentItemsAndRejectsInvalidScopes()
                try await uninstallPermanentRechecksActivityAtJournalBoundary()
                try await uninstallReviewSeparatesPersonalDataAndDoesNotModifyFiles()
                try await uninstallReviewIncludesOnlyVerifiedGroupContainers()
                try await uninstallCompleteLoopRestoresIndependentComponentOrigins()
                try await uninstallRefusesChangedEvidenceRunningApplicationsAndExcludedData()
                try await uninstallRechecksActivityAtTheJournalBoundary()
                try await uninstallCoverageGapsRequireExplicitChoicesAndConsentCannotBeForged()
                try await uninstallParentSiblingChangesPreservePlansButNotTargetChanges()
                try nativeUninstallEvidenceReadsOnlyExplicitContainerMetadata()
                try await uninstallContainerWorkersCancelAndTimeoutWithoutBlockingReview()
                try nativeApplicationActivitySkipsOnlyKernelVerifiedZombies()
                try await nativeApplicationActivityKeepsLiveHelpersBlocked()
                try await nativeApplicationActivityKeepsUnlinkedHelpersBlocked()
                try await uninstallActivityFailuresKeepTheirCauseAndAllowRetryWithoutMutation()
                try await administratorUninstallRequiresNativeTrashAndKeepsDataOnCancellation()
                try await nativeApplicationTrashUsesRecyclerAndVerifiesFixtureOutcomes()
                try await nativeApplicationTrashRejectsLinksStaleAndForeignOwnerManifests()
                print("29/29 application catalog, summary, authorization, batch and legacy uninstall safety tests passed; only generated fixtures were moved, restored or permanently removed.")
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
                try await storageCatalogFullFailureNeverReplacesPreviousAnalysis()
                try storageCatalogPreparesPrivateFilesAfterExistingFileRefusal()
                try await storageCatalogScansLaterSiblingsAndLoadsExactDirectories()
                try await storageCatalogAccountsHardLinksAndOpaqueLinks()
                try await storageCatalogMarksUnreadableDirectoriesWithoutHidingSiblings()
                try await storageCatalogCancellationNeverPublishesAScan()
                print("6/6 streaming storage catalog, storage exhaustion, private files, directory paging, sibling coverage, hard links, permissions and cancellation tests passed; generated fixtures only.")
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
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-cleanup-performance-only"] {
            do { try await storageCleanupPipelineBenchmark() }
            catch { print("FAIL storage cleanup benchmark: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-manifests-only"] {
            do {
                try await storageManifestPagesVerifyCorruptionAndRetention()
                try await storageManifestInterruptedPublicationAndLegacyPlans()
                try await permanentVerificationCancellationDoesNotRemoveFiles()
                print("3/3 bounded manifest pages, corruption, publication, retention, legacy and cancellation checks passed; generated fixtures only.")
            } catch { print("FAIL storage manifests: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-removal-only"] {
            do {
                try await storageReviewRefreshesDirectoryChangesBeforeConfirmation()
                try await storageIncompleteReviewReportsCauseAndRemainsRetryable()
                try await storageBatchReviewSkipsIncompleteTargetsAndExecutesCompleteSiblings()
                try await storageBatchReviewAllExcludedTargetsProducesNoPlanOrMutation()
                try await storageBatchReviewSkipsDisappearedTargets()
                try await storageBatchReviewDoesNotSkipStaleObjectsOrCancellation()
                try await storageNativeRemovalReportsManifestProgress()
                try await storageAnalysisProtectsRootsAndDetectsChanges()
                try await storageRemovalRechecksCurrentExclusionsAndNewDescendants()
                try await storageNativeLargeFileTrashRestoreAndPermanentRemoval(permanent: true)
                print("10/10 storage review, batch skips, retry, progress, stale evidence, exclusions and native deletion tests passed; generated fixtures only.")
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
                try await commonReviewSeparatesUserCachesAndCrossProjectArtifacts()
                try await projectDiscoveryFindsAdditionalCollectionsAndToolchains()
                try await projectArtifactRulesRequireExactLocalMarkers()
                try await additionalProjectSourcesStayInsideVerifiedGeneratedLayouts()
                try await additionalProjectArtifactsBlockAuthoredAndProtectedContent()
                try await projectArtifactActivityIsScopedAndUnknownFactsRemainBlocked()
                try await browserAutomationCachesRequireGlobalActivityFactsAndProtectSource()
                print("11/11 discovery, project/cache boundaries, category grouping and repeated-cleanup tests passed; only generated fixtures were used.")
            } catch { print("FAIL automatic discovery: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--cleanup-discovery-only"] {
            do {
                try selectiveDiscoveryPrunesProtectedTreesWithinBudget()
                try fixedSelectivePatternsAvoidUnreachableSubtrees()
                try await matchedSelectiveTargetsRetainFullManifestsAndMarkers()
                try await selectiveEngineEvidencePlansOnlyMeasuredTargetsAndRestores()
                try await selectiveDiscoverySharesFiniteBudgetAcrossLargeAndLaterProjects()
                try await selectiveFairDiscoveryPreservesRulesMarkersAndExclusions()
                try await selectiveDiscoveryRejectsReplacedTargetsAndMarkers()
                try selectiveDiscoveryCancellationKeepsPartialTargetsUnauthorized()
                try await isolatedCleanupDiscoveryKeepsLaterProjectsWithinSharedBudget()
                try await selectiveDiscoveryFindsTargetsAndMarkersInWideDirectories()
                try await cleanupPlanRechecksOnlySelectedPolicyAndReportsChangedSafety()
                try await manualCleanupSelectionPreparesFreshScopeAndPermanentlyRemovesOnlyFixture()
                try await manualCleanupSelectionKeepsExclusionsPreviewAndChangedManifestGates()
                print("13/13 cleanup discovery, manual selection, fresh scope, permanent removal and safety checks passed; generated fixtures only.")
            } catch { print("FAIL bounded cleanup discovery: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--cleanup-refinement-only"] {
            do {
                try await commonReviewRefinesOnlyOneTargetAndRetainsOriginalEvidence()
                try await commonReviewRefinementRejectsStaleEvidenceAndSupportsRepeatedPartialScans()
                print("2/2 cleanup refinement projection, retained selection, stale evidence and repeated-target checks passed; generated fixtures only.")
            } catch { print("FAIL cleanup refinement: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--cleanup-target-only"] {
            do {
                try await cleanupTargetRescanCompletesOnlyOriginalTargetAndExecutes()
                try await cleanupTargetRescanRejectsPreviewCompleteAndChangedConfiguration()
                try await cleanupTargetRescanRejectsReplacedBindingsAndMissingMarkers()
                try await cleanupTargetRescanRechecksSourceGitAndBuildActivity()
                try await cleanupTargetRescanProtectsLimitsCancellationAndMidScanChanges()
                try await cleanupTargetRescanRejectsChangesDuringMeasurement()
                try await cleanupTargetRescanRetainsCanonicalGeneratedSourceRules()
                try await isolatedCleanupTargetRescanMatchesNativeNarrowEvidence()
                print("8/8 cleanup target scope, policy, cancellation, changed evidence, isolated-worker and Trash/restore checks passed; generated fixtures only.")
            } catch { print("FAIL cleanup target scan: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-presentation-million-only"] {
            do { try await storagePresentationReadsMillionRowCatalog() }
            catch { print("FAIL million-row presentation: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-presentation-only"] {
            do {
                try await storagePresentationReusesSnapshotAndPreservesAccounting()
                try await storageNestedMapIsBoundedAndPreservesParentArea()
                try storageSelectionPreservesSiblingsAndDeduplicates()
                print("3/3 storage presentation, context and selection tests passed.")
            } catch { print("FAIL storage presentation: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-only"] {
            do {
                try storageCatalogProtectionExemptsOnlyDisposableFiles()
                try await storageCatalogCleanupAllowsReferencedAndCurrentIndexes()
                try await storageCatalogTrashCleanupPreservesRestoreAndRechecksChanges()
                try storageSelectionPreservesSiblingsAndDeduplicates()
                try await storageAnalysisProtectsRootsAndDetectsChanges()
                try await storageRemovalRechecksCurrentExclusionsAndNewDescendants()
                try await storageNativeLargeFileTrashRestoreAndPermanentRemoval(permanent: true)
                print("7/7 storage tests passed; only generated fixtures were mutated.")
            } catch { print("FAIL storage tests: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-browsing-only"] {
            do {
                try await storageBrowsingSelectionSharesProtectionAndHierarchyWithoutMutation()
                try await storageBrowsingPagesAreBoundedAndExpandedSelectionsNeverTruncate()
                print("2/2 storage browsing, protection, hierarchy, pagination and read-only selection checks passed; generated fixtures only.")
            } catch { print("FAIL storage browsing: \(error)"); Foundation.exit(1) }
            return
        }
        if Array(CommandLine.arguments.dropFirst()) == ["--storage-search-preview-only"] {
            do {
                try await storageNameSearchReadsEveryImmediateChildAndBindsContinuation()
                try await storagePreviewIsBoundedReadOnlyAndRejectsChangedObjects()
                print("2/2 full-directory search, bounded preview, scan identities, host/path/format boundaries and cancellation checks passed; generated fixtures only, local preview only.")
            } catch { print("FAIL storage search/preview: \(error)"); Foundation.exit(1) }
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
        if Array(CommandLine.arguments.dropFirst()) == ["--rule-catalog-only"] {
            do {
                try await catalogRulesKeepProfilesGamesAndDeveloperState()
                try await catalogRulesRetainProtectedContentsAndPlatformBoundaries()
                print("2/2 Rule catalog boundary and protection tests passed; generated fixtures only.")
            } catch { print("FAIL Rule catalog coverage: \(error)"); Foundation.exit(1) }
            return
        }
        var cases: [(String, () async throws -> Void)] = [
            ("Monitor rate baselines and source resets", { try monitorRatesRequireFreshStableCounters() }),
            ("Monitor groups, PID reuse and bounded history", { try monitorHandlesGroupsReuseMissingDataAndBoundsHistory() }),
            ("Monitor lifecycle rejects late results", { try await monitorSessionRejectsLateResultsAndStopsWhenHidden() }),
            ("Monitor read-only native observation", { try await nativeMonitorReadsWithoutMutation() }),
            ("Paged storage manifests preserve corruption and retention boundaries", { try await storageManifestPagesVerifyCorruptionAndRetention() }),
            ("Storage manifest publication failures and legacy plans remain safe", { try await storageManifestInterruptedPublicationAndLegacyPlans() }),
            ("Cancelling permanent verification never removes files", { try await permanentVerificationCancellationDoesNotRemoveFiles() }),
            ("Execution progress preserves batch totals and partial boundaries", { try executionProgressKeepsBatchTotalsAndPartialBoundaries() }),
            ("Execution progress rejects late stages and nested-entry regressions", { try executionProgressRejectsLateStageAndEntryCallbacks() }),
            ("Privacy independent sources continue after a changed middle source", { try await privacyChangedMiddleSourceDoesNotBlockIndependentSources() }),
            ("Privacy progress follows committed source outcomes", { try await privacyProgressTracksSourcesAndCommittedOutcomes() }),
            ("Privacy progress cancellation preserves remaining sources", { try await privacyProgressCancellationPreservesRemainingSources() }),
            ("Installed application caches use ordinary cleanup and preserve applications", { try await installedApplicationCachesUseNormalCleanupWithoutUninstalling() }),
            ("Installed application cache activity and identity are revalidated", { try await installedApplicationCachesKeepActivityAndIdentityGates() }),
            ("Installed application caches recheck at each mutation boundary", { try await installedApplicationCachesRecheckAtEachMutationBoundary() }),
            ("Installed application caches preserve static scope and disabled rules", { try await installedApplicationCachesRespectStaticScopeAndDisabledRules() }),
            ("Installed application caches retain shared protection and no-follow boundaries", { try await installedApplicationCachesRetainSharedProtectionAndNoFollowBoundaries() }),
            ("Installed application cache discovery reports incomplete and ambiguous owners", { try await installedApplicationCachesReportInventoryGapsAndAmbiguousOwners() }),
            ("Installed application cache evidence preserves legacy digests", { try await installedApplicationCachesKeepLegacyRecordsAndBindEvidenceDigests() }),
            ("Application updates compare only numeric versions", { try applicationUpdatesCompareOnlyVerifiedNumericVersions() }),
            ("Application updates bind catalog identity and system variants", { try applicationUpdatesBindCatalogIdentityAndSystemVariants() }),
            ("Application updates reject changed apps and preserve unknown failures", { try await applicationUpdatesRejectChangedAppsAndKeepFailedChecksUnknown() }),
            ("Application update transport bounds and sanitizes failures", { try await applicationUpdatesTransportBoundsAndSanitizesFailures() }),
            ("Storage comparison merges and bounds wide directories", { try await storageComparisonMergesWideDirectoriesAndBoundsRanking() }),
            ("Storage comparison retains unknown coverage and rejects replaced roots", { try await storageComparisonRetainsUnknownCoverageAndRejectsReplacedRoots() }),
            ("Storage comparison bounds history and honors cancellation", { try await storageComparisonBoundsHistoryAndHonorsCancellation() }),
            ("Storage comparison uses native allocated accounting", { try await storageComparisonUsesNativeAllocatedAccounting() }),
            ("Diagnostic capacity and unknown states remain distinct", { try diagnosticsDistinguishesUnknownAndLowCapacity() }),
            ("Native diagnostics preserves records and excludes private data", { try nativeDiagnosticsPreservesRecordsAndExcludesPrivateData() }),
            ("Native diagnostics honors cancellation", { try await nativeDiagnosticsHonorsCancellation() }),
            ("Disk access policy preserves exact protected boundaries", { try scanAccessPolicyProtectsExactBoundaries() }),
            ("Limited scan retains accessible sibling coverage", { try await scanAccessSkipsContainersAndPreservesAccessibleCoverage() }),
            ("CLI installation preserves arguments and conflicting entries", { try cliInstallationIsRepeatableAndPreservesConflicts() }),
            ("CLI installation preserves symbolic links", { try cliInstallationPreservesSymbolicLinks() }),
            ("Bulk metadata preserves exact stat evidence", { try storageBulkMetadataPreservesExactStatEvidence() }),
            ("Catalog parent IDs preserve nested names and totals", { try storageCatalogParentIDsPreserveNestedNamesAndTotals() }),
            ("Directory workers observe parent task cancellation", { try await storageDirectoryWorkersObserveParentTaskCancellation() }),
            ("Streaming storage catalog measures later siblings", { try await storageCatalogScansLaterSiblingsAndLoadsExactDirectories() }),
            ("Presentation reads saved scope, paging and agent context", { try await storagePresentationReusesSnapshotAndPreservesAccounting() }),
            ("Nested map bounds, omissions, area and cancellation", { try await storageNestedMapIsBoundedAndPreservesParentArea() }),
            ("Storage catalog deduplicates hard links without following symlinks", { try await storageCatalogAccountsHardLinksAndOpaqueLinks() }),
            ("Storage catalog prepares private files after existing-file refusal", { try storageCatalogPreparesPrivateFilesAfterExistingFileRefusal() }),
            ("Full storage catalog preserves the previous analysis", { try await storageCatalogFullFailureNeverReplacesPreviousAnalysis() }),
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
            ("Large receipt journals retain recovery without rewriting manifests", { try await largeReceiptJournalRetainsRecoveryWithoutRewritingManifests() }),
            ("Large receipt journal failures preserve durable mutation intent", { try await largeReceiptJournalFailuresPreserveDurableMutationIntent() }),
            ("History retention protects active records and store boundaries", { try await historyRetentionPreservesActiveRecordsAndRejectsStoreEscapes() }),
            ("Storage coverage distinguishes system and user access", { try storageCoverageSeparatesSystemLocationsFromUserAccess() }),
            ("Storage review refreshes directory changes before confirmation", { try await storageReviewRefreshesDirectoryChangesBeforeConfirmation() }),
            ("Storage incomplete review stays retryable", { try await storageIncompleteReviewReportsCauseAndRemainsRetryable() }),
            ("Storage batch review skips incomplete targets and executes complete siblings", { try await storageBatchReviewSkipsIncompleteTargetsAndExecutesCompleteSiblings() }),
            ("Storage batch review with all excluded targets creates no plan", { try await storageBatchReviewAllExcludedTargetsProducesNoPlanOrMutation() }),
            ("Storage batch review skips disappeared targets", { try await storageBatchReviewSkipsDisappearedTargets() }),
            ("Storage batch review preserves stale-object and cancellation failures", { try await storageBatchReviewDoesNotSkipStaleObjectsOrCancellation() }),
            ("Storage native removal reports manifest progress", { try await storageNativeRemovalReportsManifestProgress() }),
            ("Paged read worker preserves evidence and cancels loading", { try storageWorkerPagesLargeResultsWithoutChangingEvidence() }),
            ("Large storage pages round-trip and reject corruption", { try await storagePagedResultsRoundTripAndRejectCorruption() }),
            ("Storage cancellation does not publish incomplete pages", { try await storageCancellationDoesNotPublishIncompletePages() }),
            ("Storage index cancels without changing accounting", { try storageIndexCanCancelAndKeepsAccounting() }),
            ("SHA-256 known vector", { try sha256KnownVector() }),
            ("Schema and round trip", { try ruleSchemaAndRoundTrip() }),
            ("Personal draft authoring uses the closed portable contract", { try personalDraftUsesClosedContractAndPortableFields() }),
            ("Exact folder authoring cannot broaden workspace scope", { try exactPersonalRuleSelectionCannotExpandItsScope() }),
            ("Personal rule revisions preserve old bindings and reject stale saves", { try await personalRuleRevisionsPreserveBindingsAndRejectStaleSaves() }),
            ("Personal draft preview explains conditions and stays disabled", { try await personalDraftPreviewExplainsConditionsAndPreservesDisabledState() }),
            ("Independent personal rules preserve unselected drafts through cleanup", { try await independentPersonalRulesCompleteCleanupWithoutEnablingOtherDrafts() }),
            ("Personal draft age explanations preserve decision boundaries", { try await personalDraftAgeExplanationUsesCandidateDecisionBoundary() }),
            ("Wildcard semantics", { try wildcardSemantics() }),
            ("Wildcard language equivalence", { try wildcardMatcherPreservesLanguage() }),
            ("Wildcard descendant-prefix soundness", { try wildcardPrefixReachabilityPreservesMatches() }),
            ("Canonical digest", { try canonicalDigestIndependentOfObjectKeyOrder() }),
            ("JSON envelope escaping", { try envelopeUsesStableKeysAndExplicitNull() }),
            ("UTC decision precision", { try utcTimestampsPreserveDecisionPrecision() }),
            ("Chinese desktop default and saved language", { try desktopLanguageDefaultsAndSavedChoice() }),
            ("Runtime localization switches in both directions", { try localizedResourcesSwitchWithoutProcessRestart() }),
            ("Privacy ranges preserve unselected relations and receipts", { try await privacyChromiumRangePreservesUnselectedRelationsAndReceipts() }),
            ("Privacy discovery keeps accessible sources when a browser denies access", { try await privacyDiscoveryPermissionFailureKeepsAccessibleSources() }),
            ("Privacy discovery rejects linked roots and preserves limits and cancellation", { try await privacyDiscoveryRejectsLinkedRootsAndPreservesLimitsAndCancellation() }),
            ("Privacy cookies require separate consent and use last access time", { try await privacyCookiesRequireSeparateConsentAndUseLastAccessTime() }),
            ("Privacy epochs preserve bookmarks and downloads", { try await privacyFirefoxAndSafariEpochsPreserveBookmarksAndDownloads() }),
            ("Privacy refuses running, stale, excluded and unsupported sources", { try await privacyRefusesRunningStaleExcludedAndUnsupportedSources() }),
            ("Privacy transactions roll back and unknown schemas stay unavailable", { try await privacyTransactionsRollbackAndUnknownSchemasStayUnavailable() }),
            ("Privacy integer time bounds, WAL and unknown cascades", { try await privacyIntegerTimeBoundsAndUnknownCascadesAreConservative() }),
            ("Application discovery validates before read and cancellation", { try await applicationCatalogValidatesBeforeReadAndHonorsCancellation() }),
            ("Application catalog preserves distinct paths and explicit scope", { try nativeApplicationCatalogPreservesDistinctPathsAndBoundsItsScope() }),
            ("Application catalog rejects unsafe metadata with explicit gaps", { try nativeApplicationCatalogRejectsUnsafeMetadataWithoutHidingCoverageGaps() }),
            ("Application catalog reads nested, single-segment and linked applications", { try nativeApplicationCatalogSupportsNestedSingleSegmentAndLinkedApplications() }),
            ("Incomplete application removal preserves associations and supports restore", { try await uninstallMissingMetadataKeepsAssociationsAndRestoresBundle() }),
            ("Hard-linked application Trash preserves external content", { try await uninstallHardLinkedBundleUsesTrashAndPreservesExternalContent() }),
            ("User-installed Apple apps and single-segment identifiers support uninstall", { try await uninstallUserInstalledAppleAppsAndSingleSegmentIdentifiers() }),
            ("File targets bind bounded content and preserve legacy manifests", { try fileTargetsRequireBoundedContentEvidenceAndKeepLegacyManifestsStable() }),
            ("Uninstall preview separates personal data without file mutation", { try await uninstallReviewSeparatesPersonalDataAndDoesNotModifyFiles() }),
            ("Application summaries stream one inventory and conservative ownership", { try await applicationSummariesStreamOneInventoryAndKeepOwnershipConservative() }),
            ("Native application summaries avoid manifests and link traversal", { try nativeApplicationSummaryMeasuresWithoutManifestsOrLinkTraversal() }),
            ("Application batch uses one receipt and restores two applications", { try await uninstallBatchUsesOneReceiptAndRestoresTwoApplications() }),
            ("Application batch permanent default cannot restore; single Trash remains compatible", { try await uninstallBatchDefaultPermanentCannotRestoreAndSingleTrashRemainsCompatible() }),
            ("Application batch reports per-item failures and rejects invalid consent and overlaps", { try await uninstallBatchContinuesIndependentItemsAndRejectsInvalidScopes() }),
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
            ("Administrator uninstall requires native Trash and preserves app data on cancellation", { try await administratorUninstallRequiresNativeTrashAndKeepsDataOnCancellation() }),
            ("Native application Trash preserves cancellation and verifies moved contents", { try await nativeApplicationTrashUsesRecyclerAndVerifiesFixtureOutcomes() }),
            ("Native application Trash rejects stale linked and foreign-owned targets", { try await nativeApplicationTrashRejectsLinksStaleAndForeignOwnerManifests() }),
            ("Startup discovery validates before read and cancellation", { try await startupInventoryValidatesBeforeReadingAndHonorsCancellation() }),
            ("Startup control requires explicit capability and action", { try await startupControlRequiresPlatformCapabilityAndForwardsExplicitAction() }),
            ("Startup groups use exact identity and retain mixed states", { try startupGroupsUseExactApplicationIdentityAndPreserveMixedStates() }),
            ("Startup filters distinguish unknown and missing targets", { try startupFiltersKeepUnknownAndMissingTargetsDistinct() }),
            ("Startup legacy payloads decode and configured defaults remain explicit", { try startupDefinitionsDecodeLegacyDataAndResolveConfiguredDefaults() }),
            ("Startup discovery resolves applications without false leftovers", { try nativeStartupInventoryFindsAppIdentityWithoutFalseResiduals() }),
            ("Startup control verifies readback and preflighted fixture removal", { try nativeStartupControlReadbackAndRemovalUseOnlyPreflightedFixtures() }),
            ("Startup background archives enforce bounded data-only parsing", { try startupBackgroundArchiveIsBoundedVersionedAndNeverUnarchivesClasses() }),
            ("System startup toggles use fixed authorization and verified readback", { try nativeStartupDaemonControlUsesFixedAuthorizationAndReadback() }),
            ("Login startup control revalidates native registration identity", { try nativeStartupLoginControlRevalidatesIdentityAndNativeState() }),
            ("Launchctl state parsing stays bounded and explicit", { try launchctlStateParsersKeepOnlyDocumentedStates() }),
            ("Native startup control refuses system and out-of-scope definitions", { try nativeStartupControlRefusesSystemAndOutOfScopeDefinitions() }),
            ("Startup definitions keep state unknown and omit credentials", { try nativeStartupInventoryKeepsStateUnknownAndOmitsSecrets() }),
            ("Startup discovery rejects links, special and invalid definitions", { try nativeStartupInventoryRejectsUnsafeAndInvalidDefinitions() }),
            ("Startup discovery retains explicit budget gaps", { try nativeStartupInventoryReportsBudgetGapsWithoutLosingValidItems() }),
            ("Explicit platform-scoped known locations", { try knownLocationsAreExplicitAndPlatformScoped() }),
            ("Automatic project discovery reuses scope and exclusions", { try await projectDiscoveryFindsCollectionsWithoutRegistrationAndReusesPolicy() }),
            ("Scan location inventory distinguishes automatic, included and built-in roots", { try await scanLocationInventoryDistinguishesAutomaticIncludedAndCacheRoots() }),
            ("Conventional location boundaries follow platform paths", { try conventionalLocationScopeUsesPlatformPathBoundaries() }),
            ("Project discovery respects explicit nested policy", { try await projectDiscoveryRespectsExplicitNestedScopeAndDisabledRules() }),
            ("Project discovery cancels before registration", { try await projectDiscoveryCancellationStopsBeforeRegistration() }),
            ("Project discovery covers additional collections and toolchains", { try await projectDiscoveryFindsAdditionalCollectionsAndToolchains() }),
            ("Project artifacts require exact local markers", { try await projectArtifactRulesRequireExactLocalMarkers() }),
            ("Enabled personal rules join repeated cleanup", { try await enabledPersonalRulesJoinRepeatedCleanupWithoutReselecting() }),
            ("Native location availability uses directory metadata", { try nativeAvailabilityDistinguishesDirectoriesWithoutFollowingLinks() }),
            ("Native root identity requires search without enumeration", { try nativeRootIdentityNeedsOnlySearchAccess() }),
            ("Read worker preserves direct evidence without a store", { try nativeReadWorkerMatchesDirectEvidenceWithoutOpeningStore() }),
            ("Isolated worker batch preserves every cache and project root within capacity", { try await workerBackedSystemScanBoundsConcurrentReadsWithoutLosingRoots() }),
            ("Read worker accepts snake-case protocol fields", { try nativeReadWorkerAcceptsSnakeCaseWireRequest() }),
            ("Read worker cancellation terminates only its child", { try nativeReadWorkerCancellationStopsOwnedChild() }),
            ("Read worker wall timeout returns no evidence", { try nativeReadWorkerTimeoutStopsOwnedChildWithoutEvidence() }),
            ("Container ownership workers cancel and time out", { try await uninstallContainerWorkersCancelAndTimeoutWithoutBlockingReview() }),
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
            ("Catalog rules preserves profiles and developer state", { try await catalogRulesKeepProfilesGamesAndDeveloperState() }),
            ("Catalog declarations retain protection and platform boundaries", { try await catalogRulesRetainProtectedContentsAndPlatformBoundaries() }),
            ("Declarative application activity metadata", { try applicationActivityFollowsDeclarativeCatalogMetadata() }),
            ("Generated Rust requires trusted rule facts", { try await generatedRustSourcesRequireTrustedRulesAndFacts() }),
            ("Generated Rust retains authored sources", { try await generatedRustSourcesPreserveAuthoredFilesAndRequireLayout() }),
            ("Artifacts block tracked and active content", { try await generatedArtifactsBlockTrackedContentActiveBuildsAndUnknownFacts() }),
            ("Additional project sources require verified generated layouts", { try await additionalProjectSourcesStayInsideVerifiedGeneratedLayouts() }),
            ("Additional project artifacts protect authored content", { try await additionalProjectArtifactsBlockAuthoredAndProtectedContent() }),
            ("Project artifact activity stays scoped and verified", { try await projectArtifactActivityIsScopedAndUnknownFactsRemainBlocked() }),
            ("Browser runtimes require global activity and source checks", { try await browserAutomationCachesRequireGlobalActivityFactsAndProtectSource() }),
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
            ("Enabled rule presets preserve reviewed configuration and disabled bindings", { try await enabledRulePresetsPreserveReviewedConfigurationAndBindings() }),
            ("Built-in binding validation, isolation and benchmark", { try await builtinCatalogBindingPreservesValidationAndIsolation() }),
            ("Built-in protected descendants", { try await builtinRulesPreserveProtectedDescendants() }),
            ("Storage selection preserves siblings and deduplicates", { try storageSelectionPreservesSiblingsAndDeduplicates() }),
            ("Disposable catalog selection preserves other record protection", { try storageCatalogProtectionExemptsOnlyDisposableFiles() }),
            ("Referenced and current catalogs support explicit cleanup", { try await storageCatalogCleanupAllowsReferencedAndCurrentIndexes() }),
            ("Catalog cleanup preserves recovery and rejects changed files", { try await storageCatalogTrashCleanupPreservesRestoreAndRechecksChanges() }),
            ("Storage browsing shares protection and selection without mutation", { try await storageBrowsingSelectionSharesProtectionAndHierarchyWithoutMutation() }),
            ("Storage browsing pages and selection expansion retain exact scope", { try await storageBrowsingPagesAreBoundedAndExpandedSelectionsNeverTruncate() }),
            ("Storage name search covers unloaded children and binds continuation", { try await storageNameSearchReadsEveryImmediateChildAndBindsContinuation() }),
            ("Storage preview is bounded, read-only and identity-bound", { try await storagePreviewIsBoundedReadOnlyAndRejectsChangedObjects() }),
            ("Storage analysis separates read scope and stale removal", { try await storageAnalysisProtectsRootsAndDetectsChanges() }),
            ("Storage removal rechecks exclusions and new descendants", { try await storageRemovalRechecksCurrentExclusionsAndNewDescendants() }),
            ("Native space analysis large-file Trash restore and permanent removal", { try await storageNativeLargeFileTrashRestoreAndPermanentRemoval(permanent: CommandLine.arguments.contains("--native-trash-purge")) }),
            ("Storage and treemap accounting", { try storageAccountingAndTreemapConserveArea() }),
            ("Non-overlapping cleanup overview", { try await cleanupOverviewDoesNotDoubleCount() }),
            ("Unified review evidence and eligibility", { try await commonReviewGroupsEvidenceWithoutGrantingAuthority() }),
            ("Unified review separates user caches and cross-project artifacts", { try await commonReviewSeparatesUserCachesAndCrossProjectArtifacts() }),
            ("Unified review replaces only the refined target", { try await commonReviewRefinesOnlyOneTargetAndRetainsOriginalEvidence() }),
            ("Unified review rejects stale and repeated refinement conflicts", { try await commonReviewRefinementRejectsStaleEvidenceAndSupportsRepeatedPartialScans() }),
            ("Cleanup target rescan and isolated execution", { try await cleanupTargetRescanCompletesOnlyOriginalTargetAndExecutes() }),
            ("Cleanup target rescan requires current enabled evidence", { try await cleanupTargetRescanRejectsPreviewCompleteAndChangedConfiguration() }),
            ("Cleanup target rescan rejects replaced bindings and markers", { try await cleanupTargetRescanRejectsReplacedBindingsAndMissingMarkers() }),
            ("Cleanup target rescan rechecks sources and build activity", { try await cleanupTargetRescanRechecksSourceGitAndBuildActivity() }),
            ("Cleanup target rescan retains finite limits and cancellation", { try await cleanupTargetRescanProtectsLimitsCancellationAndMidScanChanges() }),
            ("Cleanup target rescan rejects changes during measurement", { try await cleanupTargetRescanRejectsChangesDuringMeasurement() }),
            ("Cleanup target rescan retains canonical generated-source policy", { try await cleanupTargetRescanRetainsCanonicalGeneratedSourceRules() }),
            ("Cleanup target rescan matches isolated-worker evidence", { try await isolatedCleanupTargetRescanMatchesNativeNarrowEvidence() }),
            ("Disabled imports and non-executable previews", { try await importIsDisabledAndPreviewCannotExecute() }),
            ("Trash and restore loop; replay refusal", { try await completeTrashRestoreLoopAndRepeatRefusal() }),
            ("Trash root comparison allows only directory ctime", { try trashRootComparisonAllowsOnlyDirectoryCTime() }),
            ("Verified Trash root ctime drift still restores", { try await trashRootCTimeChangeRestoresThroughBothVerificationLayers() }),
            ("Trash root ctime exception never authorizes cleanup", { try await trashRootCTimeExceptionNeverAuthorizesPlanExecution() }),
            ("Changed Trash metadata, identity and descendants stay blocked", { try await changedTrashMetadataIdentityAndDescendantsStillRefuseRestore() }),
            ("Cleanup scan uses bounded workers with serial parity", { try await cleanupScanUsesBoundedWorkersAndPreservesSerialResults() }),
            ("System scan honors platform read capacity", { try await systemScanHonorsPlatformReadConcurrency() }),
            ("Native cleanup concurrency preserves generated filesystem evidence", { try await nativeCleanupConcurrencyPreservesRealFilesystemEvidence() }),
            ("Derived record retention preserves active plans and recovery", { try await recordRetentionProtectsActivePlansAndRecoveryWithZeroQuota() }),
            ("Orphan cleanup verifies absence, consent and shared recovery", { try await applicationOrphansRequireAbsenceConsentAndReuseDeletionJournals() }),
            ("Orphan cleanup retains unknown owners and changed or excluded targets", { try await applicationOrphansRespectUnknownOwnersExclusionsAndChangedContents() }),
            ("Agent rules measure new coverage and persist opt-in reuse", { try await agentRuleLoopMeasuresAdditionalCoverageAndPersistsReuse() }),
            ("AI connections, private scope and physical folder selections", { try aiInvestigationPreservesConnectionAndPhysicalSelectionBoundaries() }),
            ("Replaceable AI decisions and credential-wait revocation", { try await aiDecisionProvidersAreReplaceableAndRevokedCredentialsCannotSend() }),
            ("Private local AI credentials and independent provider accounts", { try aiLocalCredentialsRemainPrivateAndIndependent() }),
            ("Application closing binds identity and verifies remaining owners", { try await applicationClosingVerifiesIdentityAndReportsRemainingOwners() }),
            ("Tool cleanup uses fixed owner operations and verifies outcomes", { try await toolCleanupUsesFixedOwnerOperationsAndVerifiesOutcomes() }),
            ("Tool cleanup rejects remote, stale and unknown outcomes", { try await toolCleanupRejectsRemoteStaleAndUnknownOutcomes() }),
            ("Tool cleanup review expires during owner preview", { try await toolCleanupExpiresDuringOwnerPreview() }),
            ("Native tool adapter bounds generated process groups and output", { try nativeToolAdapterBoundsRealFixtureProcesses() }),
            ("Package updates freeze exact selections and verify installed versions", { try await packageUpdatesFreezeExactSelectionsAndVerifyInstalledVersions() }),
            ("MySQL reviews bind account hosts and exclude credentials", { try await mysqlAdminUsesExactHostAndSingleUseSecretFreeReviews() }),
            ("MySQL rejects changed servers and existing users", { try await mysqlAdminRejectsStaleServersExistingAccountsAndUnjournaledChanges() }),
            ("MySQL records partial changes and limits backup scope", { try await mysqlAdminKeepsPartialOutcomesAndRejectsSystemBackups() }),
            ("MySQL registration binds exact reviews and durable intent", { try await mysqlInstanceRegistrationBindsReviewsAndRequiresDurableIntent() }),
            ("MySQL configuration rejects stale files and links", { try mysqlConfigurationRejectsChangesLinksAndKeepsSourceScope() }),
            ("Developer catalog validates categories and package sources", { try developerCatalogCoversCategoriesWithoutInventingSources() }),
            ("Restart requires verified stopping and reports partial outcomes", { try await developerServiceRestartRequiresVerifiedStopBeforeStart() }),
            ("Service switches bind source identities and preserve journal outcomes", { try await developerServiceSwitchesBindSourcesAndVerifyJournaledOutcomes() }),
            ("Scoped service loading preserves other tool observations", { try await developerServicesLoadOnlySelectedToolsWithoutDiscardingOtherObservations() }),
            ("Native service switches preserve generated login registration", { try await nativeDeveloperServicesPreserveLoginRegistrationUsingGeneratedManager() }),
            ("Native service instances preserve independent generated databases", { try await nativeDeveloperInstancesSeparateAndRestartGeneratedDatabases() }),
            ("Developer configuration edits preserve identity and software paths", { try developerConfigurationFilesPreserveIdentityAndSoftwarePaths() }),
            ("Developer configuration adapters discover independent software scopes", { try developerConfigurationAdaptersDiscoverSoftwareScopesWithoutExecutingPrograms() }),
            ("Developer configuration formats preserve exact files and reject unknown writes", { try developerConfigurationFormatsPreserveExactFilesAndRejectUnknownWrites() }),
            ("Developer log cleanup preserves open-file identity and exact single-use reviews", { try await developerLogsRequireExactSingleUseReviewsAndPreserveOpenFileIdentity() }),
            ("Developer package uninstall rejects running generated images and ambiguous paths", { try await developerPackageUninstallRejectsRunningGeneratedImagesAndAmbiguousPaths() }),
            ("Native launchd restart preserves generated KeepAlive registration", { try await nativeDeveloperLaunchdRestartsGeneratedKeepAliveWithoutRegistrationChanges() }),
            ("Developer tool plans are single-use and journal outcomes", { try await developerToolsRequireFrozenSingleUsePlansAndJournalResults() }),
            ("Developer tools reject stale authority and missing intent records", { try await developerToolsRejectIdentityDriftExpiryAndUnrecordedMutation() }),
            ("Developer tools verify actual installed state", { try await developerToolsDoNotTreatManagerCompletionAsSuccess() }),
            ("Native developer tools install and uninstall only generated exact fixtures", { try await nativeDeveloperToolsUseGeneratedExactInstallAndUninstall() }),
            ("Developer discovery preserves copies without executing binaries", { try developerDiscoveryPreservesMultipleCopiesWithoutExecutingThem() }),
            ("AI workspace summaries exclude credentials and private values", { try aiWorkspaceSummarizesNamesWithoutExposingPrivateValues() }),
            ("Package dependencies reaching frozen versions avoid repeat upgrades", { try await packageUpdatesRecognizeFrozenTargetsReachedByDependencies() }),
            ("Package updates reject stale changed pinned and unknown selections", { try await packageUpdatesRejectStaleChangedPinnedAndUnknownSelections() }),
            ("Package updates reject malformed identities and preserve global mise ranges", { try await packageUpdatesRejectMalformedIdentitiesAndPreserveGlobalMiseRanges() }),
            ("Interrupted or unverified package installs remain unknown", { try await packageUpdatesInterruptedOrUnverifiedInstallsRemainUnknown() }),
            ("Native package upgrades use only exact generated commands", { try nativePackageUpdatesUseOnlyGlobalExactGeneratedCommands() }),
            ("Record retention groups publications and rejects changed evidence", { try await recordRetentionPreservesDependenciesAndRejectsChangedRecords() }),
            ("History summaries page and reject stale caches", { try await historySummariesPageAndInvalidateWithoutChangingRecoveryEvidence() }),
            ("Full descendant manifest invalidation", { try await fullManifestDetectsDescendantChange() }),
            ("Native purge reports progress for deep directories", { try nativePermanentRemovalReportsProgressForDeepDirectories() }),
            ("Native purge rejects replaced cached directories", { try nativePermanentRemovalRejectsReplacedCachedDirectories() }),
            ("Native purge preserves unplanned files", { try nativePermanentRemovalPreservesNewUnplannedFiles() }),
            ("Permanent removal continues past permission failures and later targets", { try await permanentRemovalContinuesPastPermissionFailuresAndLaterTargets() }),
            ("Native purge handles nested and retained hard links", { try nativePermanentRemovalHandlesNestedAndRetainedHardLinks() }),
            ("Permanent rule batch handles hard links across targets", { try await permanentRuleBatchHandlesHardLinksAcrossTargets() }),
            ("Permanent storage batch handles shared files and directories", { try await permanentStorageBatchHandlesSharedFilesAndDirectories() }),
            ("Permanent removal refuses external hard-link changes", { try permanentRemovalStillRejectsExternallyChangedHardLinks() }),
            ("Permanent removal reconciles only observed unlink effects", { try permanentRemovalContextRejectsUnrelatedMetadataChanges() }),
            ("Permanent batch refuses external changes after its own unlink", { try await permanentBatchRefusesExternalChangeAfterItsOwnUnlink() }),
            ("Recorded Trash purge handles shared hard links across targets", { try await trashFollowUpPurgesHardLinksAcrossRecordedTargets() }),
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
            ("Cleanup discovery shares finite budgets across large and later projects", { try await selectiveDiscoverySharesFiniteBudgetAcrossLargeAndLaterProjects() }),
            ("Fair discovery retains rule markers, exclusions and disabled bindings", { try await selectiveFairDiscoveryPreservesRulesMarkersAndExclusions() }),
            ("Cleanup discovery rejects replaced targets and project markers", { try await selectiveDiscoveryRejectsReplacedTargetsAndMarkers() }),
            ("Cancelled cleanup discovery never returns authorized targets", { try selectiveDiscoveryCancellationKeepsPartialTargetsUnauthorized() }),
            ("Isolated cleanup discovery preserves later projects within shared budgets", { try await isolatedCleanupDiscoveryKeepsLaterProjectsWithinSharedBudget() }),
            ("Wide projects retain target and marker discovery", { try await selectiveDiscoveryFindsTargetsAndMarkersInWideDirectories() }),
            ("Plans scope policy checks and report changed safety", { try await cleanupPlanRechecksOnlySelectedPolicyAndReportsChangedSafety() }),
            ("Manual selection prepares fresh scope and permanently removes generated data", { try await manualCleanupSelectionPreparesFreshScopeAndPermanentlyRemovesOnlyFixture() }),
            ("Manual selection keeps exclusions, preview and changed-manifest gates", { try await manualCleanupSelectionKeepsExclusionsPreviewAndChangedManifestGates() }),
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
        #if DEBUG && os(macOS)
        do {
            try await nativeSystemAuthorizationProtocolFixtures()
            print("PASS Authorization protocol and generated Trash fixtures")
        } catch { print("FAIL Authorization protocol: \(error)"); Foundation.exit(1) }
        #endif
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
