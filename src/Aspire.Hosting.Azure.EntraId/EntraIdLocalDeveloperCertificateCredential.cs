// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using Aspire.Hosting.ApplicationModel;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace Aspire.Hosting.Azure;

/// <summary>
/// Configures a local certificate without exposing its private material to provisioning.
/// </summary>
internal sealed class EntraIdLocalDeveloperCertificateCredential : EntraIdClientCredential
{
    private readonly SemaphoreSlim _certificateLock = new(1, 1);
    private LocalDeveloperCertificate? _certificate;

    public EntraIdLocalDeveloperCertificateCredential(EntraIdApplicationResource application, DistributedApplicationExecutionContext executionContext)
    {
        // A ParameterResource makes the PFX participate in the existing secret discovery/redaction
        // pipeline. It has no published default and never enters the Azure provisioning parameters.
        Secret = new ParameterResource(
            $"{application.Name}-local-certificate",
            _ => GetCertificateAsync(executionContext.Services, application,
                executionContext.Services.GetRequiredService<IHostApplicationLifetime>().ApplicationStopping).GetAwaiter().GetResult().Base64EncodedValue,
            secret: true);
    }

    public override string SourceType => "Base64Encoded";

    internal ParameterResource Secret { get; }

    internal async Task<LocalDeveloperCertificate> GetCertificateAsync(IServiceProvider services, EntraIdApplicationResource application, CancellationToken cancellationToken)
    {
        await _certificateLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Keep one selection for the entire run. An environment callback evaluated a day after
            // provisioning must not silently switch to a certificate that Graph has not received.
            return _certificate ??= await services.GetRequiredService<LocalDeveloperCertificateStore>()
                .GetCertificateAsync(application.Name, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _certificateLock.Release();
        }
    }

    internal override bool EmitEnvironmentVariables(IDictionary<string, object> envVars, string prefix, string separator, EntraIdApplicationResource application, IResource consumer, DistributedApplicationExecutionContext executionContext)
    {
        if (executionContext.IsPublishMode)
        {
            return false;
        }

        base.EmitEnvironmentVariables(envVars, prefix, separator, application, consumer, executionContext);
        // Keep the secret parameter visible to ExpressionResolver, which marks a ReferenceExpression
        // containing a secret parameter as sensitive. Wrapping it in an opaque provider loses that flag.
        envVars[$"{prefix}{separator}Base64EncodedValue"] = ReferenceExpression.Create($"{new ProvisioningGate(application)}{Secret}");
        return true;
    }

    private sealed class ProvisioningGate(EntraIdApplicationResource application)
        : IValueProvider, IManifestExpressionProvider, IValueWithReferences
    {
        public string ValueExpression => string.Empty;
        public IEnumerable<object> References => [application];

        public async ValueTask<string?> GetValueAsync(CancellationToken cancellationToken = default)
        {
            await application.ClientIdOutputReference.GetValueAsync(cancellationToken).ConfigureAwait(false);
            return string.Empty;
        }
    }
}
