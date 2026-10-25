using System.Collections.Immutable;
using System.Text.Json;

namespace Shou.Windows.Core.Tests;

public sealed class ApplicationUpdateTests
{
    private static ApplicationRegistration Registration => new(ApplicationSource.MachineRegistry64,
        "{EA457B21-F73E-494C-ACAB-524FDE069978}_is1", "Microsoft Visual Studio Code", "1.1", "Microsoft Corporation");
    private sealed class Inventory : IApplicationInventory
    {
        public ApplicationRegistration App = Registration;
        public Task<ApplicationInventory> ReadAsync(ApplicationDiscoveryBudget budget, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            return Task.FromResult(new ApplicationInventory([App], Enum.GetValues<ApplicationSource>().Select(source =>
                new ApplicationSourceCoverage(source, ApplicationSourceState.Complete, source == App.Source ? 1 : 0, [])).ToImmutableArray()));
        }
    }
    private sealed class Catalog : IApplicationUpdateCatalog
    {
        public int Calls;
        public string Version = "1.2";
        public bool Prerelease;
        public Action? DuringRead;
        public Exception? Error;
        public Task<byte[]> ReadAsync(CancellationToken token)
        {
            Calls++; DuringRead?.Invoke(); token.ThrowIfCancellationRequested();
            return Error is { } error ? Task.FromException<byte[]>(error) : Task.FromResult(JsonSerializer.SerializeToUtf8Bytes(new
            { draft = false, prerelease = Prerelease, tag_name = Version, html_url = "https://github.com/microsoft/vscode/releases/tag/" + Version }));
        }
    }
    private static string Id => ApplicationCatalog.ApplicationId(Registration.Source, Registration.RegistrationKey);

    [Theory]
    [InlineData("1.2", "1.2.0", 0)]
    [InlineData("1.2", "1.3", -1)]
    [InlineData("2", "1.3", 1)]
    [InlineData("latest", "1.3", null)]
    [InlineData("v1.2", "1.3", null)]
    [InlineData("1.2-beta", "1.3", null)]
    [InlineData("１.2", "1.3", null)]
    [InlineData("1.1234567890", "1.3", null)]
    public void NumericVersionsAreStrictAndTrailingZerosAreEquivalent(string installed, string available, int? result) =>
        Assert.Equal(result, ApplicationUpdateChecker.Compare(installed, available));

    [Fact]
    public async Task SourceDiscoveryAndUnsupportedIdentityNeverContactTheCatalog()
    {
        var inventory = new Inventory(); var source = new Catalog(); var checker = new ApplicationUpdateChecker(new(inventory), source);
        Assert.Equal("complete", (await checker.SourceAsync(Id, null, default)).Status);
        inventory.App = Registration with { Publisher = "Unrelated publisher" };
        Assert.Equal(ApplicationUpdateState.Unsupported, (await checker.CheckAsync(Id, null, default)).State); Assert.Equal(0, source.Calls);
    }

    [Theory]
    [InlineData("1.2", ApplicationUpdateState.NewerCatalogVersion)]
    [InlineData("1.1.0", ApplicationUpdateState.SameCatalogVersion)]
    [InlineData("1.0", ApplicationUpdateState.InstalledVersionNewer)]
    [InlineData("1.3-preview", ApplicationUpdateState.Unknown)]
    public async Task StableCatalogObservationsKeepUnknownVersionsHonest(string version, ApplicationUpdateState expected)
    {
        var checker = new ApplicationUpdateChecker(new(new Inventory()), new Catalog { Version = version });
        var result = await checker.CheckAsync(Id, null, default); Assert.Equal(expected, result.State);
        Assert.Equal(expected == ApplicationUpdateState.Unknown ? "partial" : "complete", result.Status);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ApplicationChangesOnSuccessOrFailureRejectTheObservation(bool fail)
    {
        var inventory = new Inventory(); var source = new Catalog { DuringRead = () => inventory.App = Registration with { Version = "2.0" }, Error = fail ? new IOException("secret") : null };
        var checker = new ApplicationUpdateChecker(new(inventory), source);
        Assert.Equal("application_changed", (await Assert.ThrowsAsync<ShouException>(() => checker.CheckAsync(Id, null, default))).Code);
    }

    [Fact]
    public async Task ErrorsAreSanitizedAndCancellationCannotPublish()
    {
        var source = new Catalog { Error = new IOException("private user path") }; var checker = new ApplicationUpdateChecker(new(new Inventory()), source);
        Assert.Equal("update_network_unavailable", (await checker.CheckAsync(Id, null, default)).Reason);
        source.Error = null; source.Prerelease = true;
        Assert.Equal("update_channel_unverified", (await checker.CheckAsync(Id, null, default)).Reason);
        using var cancel = new CancellationTokenSource(); source.DuringRead = () => cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => checker.CheckAsync(Id, null, cancel.Token));
    }
}
