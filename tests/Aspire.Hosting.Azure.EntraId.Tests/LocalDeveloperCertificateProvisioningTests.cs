// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json.Nodes;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Azure.EntraId.Tests.TestServices;
using Aspire.Hosting.Azure.Provisioning;
using Aspire.Hosting.Pipelines;
using Aspire.Hosting.Testing;
using Aspire.Hosting.Utils;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;

namespace Aspire.Hosting.Azure.EntraId.Tests;

public class LocalDeveloperCertificateProvisioningTests
{
    private const string TenantId = "aaaabbbb-0000-cccc-1111-dddd2222eeee";

    [Fact]
    public async Task PublicInput_ReadsTheCorrectApplicationAndContainsOnlyThePublicCertificate()
    {
        using var builder = TestDistributedApplicationBuilder.Create();
        var tokens = ConfigureGraph(builder, (request, _) =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.Equal("https://graph.microsoft.com/v1.0/applications(uniqueName='entra-web-dev')?$select=keyCredentials", request.RequestUri!.AbsoluteUri);
            Assert.Equal("Bearer", request.Headers.Authorization?.Scheme);
            Assert.Equal("test-graph-token", request.Headers.Authorization?.Parameter);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound));
        });
        var entra = builder.AddEntraIdApplication("entra-web").RunWithLocalDeveloperCertificateCredential();
        using var app = builder.Build();

        var parameters = new JsonObject();
        _ = entra.Resource.GetBicepTemplateString();
        await BicepUtilities.SetParametersAsync(parameters, entra.Resource, builder.ExecutionContext, cancellationToken: TestContext.Current.CancellationToken);

        var payload = JsonNode.Parse(parameters["localDeveloperKeyCredentials"]!["value"]!.GetValue<string>())!.AsArray();
        var key = Assert.IsType<JsonObject>(Assert.Single(payload));
        using var certificate = X509CertificateLoader.LoadCertificate(Convert.FromBase64String(key["key"]!.GetValue<string>()));
        Assert.False(certificate.HasPrivateKey);
        Assert.Equal("AsymmetricX509Cert", key["type"]!.GetValue<string>());
        Assert.Equal("Verify", key["usage"]!.GetValue<string>());
        Assert.Equal(["https://graph.microsoft.com/.default"], tokens.LastRequest!.Value.Scopes);
        Assert.Equal(TenantId, tokens.LastRequest.Value.TenantId);
        var local = await ((EntraIdLocalDeveloperCertificateCredential)entra.Resource.ClientCredentials[0])
            .GetCertificateAsync(app.Services, entra.Resource, TestContext.Current.CancellationToken);
        Assert.Equal(local.PublicCertificate, key["key"]!.GetValue<string>());
    }

    [Fact]
    public async Task Checksum_ReusesCachedCertificateAndChangesWhenANewRunRenewsIt()
    {
        using var builder = TestDistributedApplicationBuilder.Create();
        var clock = new CertificateTestTimeProvider();
        builder.Services.AddSingleton<TimeProvider>(clock);
        JsonArray remoteKeys = [];
        ConfigureGraph(builder, (_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new JsonObject { ["keyCredentials"] = remoteKeys.DeepClone() })
        }));
        var entra = builder.AddEntraIdApplication("entra-web").RunWithLocalDeveloperCertificateCredential();
        using var app = builder.Build();
        _ = entra.Resource.GetBicepTemplateString();
        var parameters = new JsonObject();
        await BicepUtilities.SetParametersAsync(parameters, entra.Resource, builder.ExecutionContext, cancellationToken: TestContext.Current.CancellationToken);
        remoteKeys = JsonNode.Parse(parameters["localDeveloperKeyCredentials"]!["value"]!.GetValue<string>())!.AsArray();
        var initialChecksum = BicepUtilities.GetChecksum(entra.Resource, parameters, scope: null);
        var section = new DeploymentStateSection("entra-web", new JsonObject { ["Parameters"] = parameters.ToJsonString() }, 0);

        Assert.Equal(initialChecksum, await BicepUtilities.GetCurrentChecksumAsync(entra.Resource, section, builder.ExecutionContext, NullLogger.Instance, TestContext.Current.CancellationToken));
        clock.UtcNow = clock.UtcNow.AddDays(1);
        // A new credential instance represents selection at the next AppHost startup.
        entra.Resource.ClientCredentials.Clear();
        entra.Resource.ClientCredentials.Add(new EntraIdLocalDeveloperCertificateCredential(entra.Resource, builder.ExecutionContext));

        var renewedChecksum = await BicepUtilities.GetCurrentChecksumAsync(entra.Resource, section, builder.ExecutionContext, NullLogger.Instance, TestContext.Current.CancellationToken);
        Assert.NotNull(renewedChecksum);
        Assert.NotEqual(initialChecksum, renewedChecksum);
        parameters = new JsonObject();
        await BicepUtilities.SetParametersAsync(parameters, entra.Resource, builder.ExecutionContext, cancellationToken: TestContext.Current.CancellationToken);
        var renewedKeys = JsonNode.Parse(parameters["localDeveloperKeyCredentials"]!["value"]!.GetValue<string>())!.AsArray();
        Assert.Equal(2, renewedKeys.Count);
        Assert.Contains(renewedKeys, k => k!["keyId"]!.GetValue<string>() == remoteKeys[0]!["keyId"]!.GetValue<string>());
    }

    [Fact]
    public async Task GraphReadFailureFailsClosedAndRetryUsesThePersistedCertificate()
    {
        using var builder = TestDistributedApplicationBuilder.Create();
        var fail = true;
        ConfigureGraph(builder, (_, _) => Task.FromResult(new HttpResponseMessage(fail ? HttpStatusCode.Forbidden : HttpStatusCode.NotFound)));
        var entra = builder.AddEntraIdApplication("entra-web").RunWithLocalDeveloperCertificateCredential();
        using var app = builder.Build();
        var provider = GetPublicInput(entra.Resource);
        var context = new ValueProviderContext { ExecutionContext = builder.ExecutionContext };

        await Assert.ThrowsAsync<HttpRequestException>(() => provider.GetValueAsync(context, TestContext.Current.CancellationToken).AsTask());
        var selected = await ((EntraIdLocalDeveloperCertificateCredential)entra.Resource.ClientCredentials[0])
            .GetCertificateAsync(app.Services, entra.Resource, TestContext.Current.CancellationToken);
        fail = false;
        var retry = JsonNode.Parse((await provider.GetValueAsync(context, TestContext.Current.CancellationToken))!)!.AsArray();

        Assert.Equal(selected.KeyId.ToString(), Assert.Single(retry)!["keyId"]!.GetValue<string>());
        Assert.False(entra.Resource.ProvisioningTaskCompletionSource!.Task.IsCompleted);
    }

    [Fact]
    public async Task MissingGraphKeyCollectionFailsClosed()
    {
        using var builder = TestDistributedApplicationBuilder.Create();
        ConfigureGraph(builder, (_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(new JsonObject())
        }));
        var entra = builder.AddEntraIdApplication("entra-web").RunWithLocalDeveloperCertificateCredential();
        using var app = builder.Build();
        var provider = GetPublicInput(entra.Resource);

        await Assert.ThrowsAsync<InvalidOperationException>(() => provider.GetValueAsync(
            new ValueProviderContext { ExecutionContext = builder.ExecutionContext }, TestContext.Current.CancellationToken).AsTask());
        Assert.False(entra.Resource.ProvisioningTaskCompletionSource!.Task.IsCompleted);
    }

    [Fact]
    public async Task GraphReadCancellationLeavesTheCertificateAvailableForRetry()
    {
        using var builder = TestDistributedApplicationBuilder.Create();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        ConfigureGraph(builder, async (_, cancellationToken) =>
        {
            entered.SetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException("The canceled request must not complete.");
        });
        var entra = builder.AddEntraIdApplication("entra-web").RunWithLocalDeveloperCertificateCredential();
        using var app = builder.Build();
        var provider = GetPublicInput(entra.Resource);
        var context = new ValueProviderContext { ExecutionContext = builder.ExecutionContext };
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(TestContext.Current.CancellationToken);
        var pending = provider.GetValueAsync(context, cancellation.Token).AsTask();
        await entered.Task.WaitAsync(TestContext.Current.CancellationToken);

        await cancellation.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);

        var selected = await ((EntraIdLocalDeveloperCertificateCredential)entra.Resource.ClientCredentials[0])
            .GetCertificateAsync(app.Services, entra.Resource, TestContext.Current.CancellationToken);
        var persisted = await app.Services.GetRequiredService<LocalDeveloperCertificateStore>().GetCertificateAsync(entra.Resource.Name, TestContext.Current.CancellationToken);
        Assert.Equal(selected.KeyId, persisted.KeyId);
        Assert.False(entra.Resource.ProvisioningTaskCompletionSource!.Task.IsCompleted);
    }

    private static CertificateTestTokenCredential ConfigureGraph(
        IDistributedApplicationTestingBuilder builder,
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send)
    {
        builder.Configuration["Azure:SubscriptionId"] = "00001111-aaaa-2222-bbbb-3333cccc4444";
        builder.Configuration["Azure:Location"] = "eastus";
        builder.Configuration["Azure:TenantId"] = TenantId;
        builder.Configuration["Azure:TenantResourceSuffix"] = "dev";
        var tokenCredential = new CertificateTestTokenCredential();
        builder.Services.AddSingleton<ITokenCredentialProvider>(tokenCredential);
        builder.Services.AddHttpClient(EntraIdLocalKeyCredentials.HttpClientName)
            .ConfigurePrimaryHttpMessageHandler(() => new CertificateTestHttpMessageHandler(send));
        return tokenCredential;
    }

    private static IValueProvider GetPublicInput(EntraIdApplicationResource application)
    {
        _ = application.GetBicepTemplateString();
        return Assert.IsAssignableFrom<IValueProvider>(application.Parameters["localDeveloperKeyCredentials"]);
    }
}
