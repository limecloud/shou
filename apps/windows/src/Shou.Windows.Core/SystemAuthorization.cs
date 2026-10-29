namespace Shou.Windows.Core;

public enum SystemAuthorizationState { NotRequested, Authorized, Unavailable }

/// <summary>System access is independent of exact business-operation consent.</summary>
public interface ISystemAuthorization
{
    SystemAuthorizationState AdministratorState { get; }
    Task PrepareAdministratorAuthorizationAsync(CancellationToken cancellationToken = default);
    Task AuthorizeAdministratorAsync(CancellationToken cancellationToken = default);
}
