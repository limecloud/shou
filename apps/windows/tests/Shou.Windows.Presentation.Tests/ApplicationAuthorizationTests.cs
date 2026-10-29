using Shou.Windows.Core;
using Shou.Windows.Presentation;

namespace Shou.Windows.Presentation.Tests;

public sealed class ApplicationAuthorizationTests
{
    [Fact]
    public async Task SelectingAnotherApplicationAfterDeclinedConsentDoesNotRequestRecovery()
    {
        var authorization = new Authorization();
        using var selection = new ApplicationSelectionViewModel(() => new(new Operations(), authorization: authorization));
        var first = "application_" + new string('a', 64);
        var second = "application_" + new string('b', 64);
        await selection.SelectAsync(first, true);
        await selection.SelectAsync(second, true);
        Assert.Equal(2, selection.SelectedCount);
        Assert.Equal(2, authorization.Preparations);
        Assert.Equal(1, authorization.Prompts);
        Assert.Equal("authorization_cancelled", selection.Item(first).Review.ErrorCode);
        Assert.Equal("authorization_unavailable", selection.Item(second).Review.ErrorCode);

        // Only the explicit recovery action may ask for consent again.
        await selection.Item(first).Review.AuthorizeAsync(first);
        Assert.Equal(2, authorization.Prompts);
        Assert.True(selection.Item(first).Review.IsAuthorized);
        Assert.Equal(first, selection.Item(first).Review.Review?.Application.Id);
        Assert.Equal(2, selection.SelectedCount);
        Assert.False(selection.CanExecute);
    }

    private sealed class Authorization : ISystemAuthorization
    {
        public SystemAuthorizationState AdministratorState { get; private set; }
        public int Prompts { get; private set; }
        public int Preparations { get; private set; }
        public Task PrepareAdministratorAuthorizationAsync(CancellationToken cancellationToken = default)
        {
            Preparations++;
            if (AdministratorState == SystemAuthorizationState.NotRequested)
            {
                Prompts++; AdministratorState = SystemAuthorizationState.Unavailable;
                throw new ShouException("authorization_cancelled", "Generated declined consent.");
            }
            throw new ShouException("authorization_unavailable", "Explicit recovery is required.");
        }
        public Task AuthorizeAdministratorAsync(CancellationToken cancellationToken = default)
        {
            Prompts++; AdministratorState = SystemAuthorizationState.Authorized;
            return Task.CompletedTask;
        }
    }

    private sealed class Operations : IApplicationUninstallOperations
    {
        public bool ExecutionAvailable => false;
        public Task<ApplicationUninstallReview> InspectAsync(string applicationId, CancellationToken cancellationToken)
        {
            var review = ApplicationUninstallViewModelTests.Review();
            return Task.FromResult(review with
            {
                Application = review.Application with { Id = applicationId },
                Installation = review.Installation with { Identity = review.Installation.Identity! with { Context = MsiInstallationContext.Machine } }
            });
        }
        public Task<ApplicationUninstallPlan> CreatePlanAsync(string applicationId, string reviewDigest, bool allowInstallerDataChanges, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public Task<ApplicationUninstallExecution> ExecuteAsync(string planId, IApplicationUninstallConfirmation confirmation, CancellationToken cancellationToken) => throw new InvalidOperationException();
        public Task<ApplicationUninstallExecution> ReadExecutionAsync(string planId, CancellationToken cancellationToken) => throw new InvalidOperationException();
    }
}
