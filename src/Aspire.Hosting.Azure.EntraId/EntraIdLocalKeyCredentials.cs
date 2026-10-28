// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using System.Globalization;
using System.IO.Hashing;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json.Nodes;
using Aspire.Hosting.ApplicationModel;
using Aspire.Hosting.Azure.Provisioning.Internal;
using Azure.Core;
using Microsoft.Extensions.DependencyInjection;

namespace Aspire.Hosting.Azure;

/// <summary>
/// Supplies only public certificate material to the deployment and its cache checksum.
/// </summary>
internal sealed class EntraIdLocalKeyCredentials(EntraIdApplicationResource application, EntraIdLocalDeveloperCertificateCredential credential)
    : IValueProvider, IManifestExpressionProvider
{
    internal const string HttpClientName = "Aspire.EntraId.LocalDeveloperCertificate";

    // This provider only exists on the run-mode model. A publish must never serialize local credentials.
    public string ValueExpression => throw new InvalidOperationException("Local developer certificate credentials cannot be published.");

    public ValueTask<string?> GetValueAsync(CancellationToken cancellationToken = default) =>
        throw new InvalidOperationException("Resolving local developer certificate credentials requires the provisioning context.");

    public async ValueTask<string?> GetValueAsync(ValueProviderContext context, CancellationToken cancellationToken = default)
    {
        var executionContext = context.ExecutionContext
            ?? throw new InvalidOperationException("Local developer certificate credentials require an execution context.");
        if (!executionContext.IsRunMode)
        {
            throw new InvalidOperationException("Local developer certificate credentials cannot be published.");
        }

        var services = executionContext.Services;
        var optionsManager = services.GetRequiredService<IAzureProvisioningOptionsManager>();
        if (!await optionsManager.EnsureProvisioningOptionsAsync(forcePrompt: false, cancellationToken).ConfigureAwait(false))
        {
            throw new InvalidOperationException("Azure provisioning options are required to provision the local developer certificate.");
        }

        var options = await optionsManager.GetProvisioningOptionsAsync(cancellationToken).ConfigureAwait(false);
        var name = string.IsNullOrEmpty(options.TenantResourceSuffix) ? application.Name : $"{application.Name}-{options.TenantResourceSuffix}";
        var graphEndpoint = GetGraphEndpoint(application.Instance);
        var certificate = await credential.GetCertificateAsync(services, application, cancellationToken).ConfigureAwait(false);
        var token = await services.GetRequiredService<ITokenCredentialProvider>().TokenCredential.GetTokenAsync(
            new TokenRequestContext([$"{graphEndpoint}/.default"], tenantId: options.TenantId), cancellationToken).ConfigureAwait(false);

        // Graph addresses an application by its immutable uniqueName, for example:
        //   /applications(uniqueName='web-dev')?$select=keyCredentials
        // Escape embedded OData quotes before URI-encoding the string literal.
        var escapedName = Uri.EscapeDataString(name.Replace("'", "''", StringComparison.Ordinal));
        using var request = new HttpRequestMessage(HttpMethod.Get, $"{graphEndpoint}/v1.0/applications(uniqueName='{escapedName}')?$select=keyCredentials");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        using var client = services.GetRequiredService<IHttpClientFactory>().CreateClient(HttpClientName);
        using var response = await client.SendAsync(request, cancellationToken).ConfigureAwait(false);
        JsonArray existing;
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            existing = [];
        }
        else
        {
            // A permission or network failure must not turn into an empty collection that removes keys.
            response.EnsureSuccessStatusCode();
            var result = await response.Content.ReadFromJsonAsync<JsonObject>(cancellationToken).ConfigureAwait(false);
            existing = result?["keyCredentials"] as JsonArray
                ?? throw new InvalidOperationException("Microsoft Graph did not return the application's keyCredentials collection.");
        }

        var store = services.GetRequiredService<IAspireStore>();
        var owner = GetOwnerMarker(store.BasePath, application.Name);
        var now = services.GetRequiredService<TimeProvider>().GetUtcNow();
        return MergePublicKeys(existing, certificate, owner, now).ToJsonString();
    }

    internal static string GetGraphEndpoint(string instance) => new Uri(instance).Host switch
    {
        "login.microsoftonline.com" => "https://graph.microsoft.com",
        "login.microsoftonline.us" => "https://graph.microsoft.us",
        "login.partner.microsoftonline.cn" or "login.chinacloudapi.cn" => "https://microsoftgraph.chinacloudapi.cn",
        _ => throw new InvalidOperationException($"Local developer certificate provisioning does not support the Entra instance '{instance}'.")
    };

    internal static string GetOwnerMarker(string storePath, string resourceName) =>
        $"aspire-local-{XxHash3.HashToUInt64(Encoding.UTF8.GetBytes($"{storePath}\n{resourceName}")):x16}";

    internal static JsonArray MergePublicKeys(JsonArray existing, LocalDeveloperCertificate certificate, string owner, DateTimeOffset now)
    {
        var keys = new List<JsonObject>();
        foreach (var node in existing)
        {
            if (node is not JsonObject key)
            {
                throw new InvalidOperationException("Microsoft Graph returned an invalid key credential.");
            }

            if (Guid.Parse(key["keyId"]!.GetValue<string>()) == certificate.KeyId ||
                (key["displayName"]?.GetValue<string>() == owner &&
                 key["endDateTime"] is { } end && DateTimeOffset.Parse(end.GetValue<string>(), CultureInfo.InvariantCulture) <= now))
            {
                continue;
            }

            // Application updates replace the entire collection. Preserve unrelated keys and unexpired
            // predecessors, which other running workloads may still be using.
            // https://learn.microsoft.com/graph/api/application-update?view=graph-rest-1.0
            keys.Add(NormalizeKey(key));
        }

        keys.Add(new JsonObject
        {
            ["customKeyIdentifier"] = certificate.Thumbprint,
            ["displayName"] = owner,
            ["endDateTime"] = certificate.NotAfter.ToString("O", CultureInfo.InvariantCulture),
            ["key"] = certificate.PublicCertificate,
            ["keyId"] = certificate.KeyId.ToString(),
            ["startDateTime"] = certificate.NotBefore.ToString("O", CultureInfo.InvariantCulture),
            ["type"] = "AsymmetricX509Cert",
            ["usage"] = "Verify"
        });

        // Graph's collection order and date spelling are not stable. Canonicalizing prevents an
        // otherwise unchanged registration from redeploying each time its checksum is evaluated.
        return new JsonArray(keys.OrderBy(k => k["keyId"]!.GetValue<string>(), StringComparer.Ordinal).Select(k => (JsonNode)k).ToArray());
    }

    private static JsonObject NormalizeKey(JsonObject key)
    {
        var normalized = new JsonObject();
        foreach (var property in new[] { "customKeyIdentifier", "displayName", "endDateTime", "key", "keyId", "startDateTime", "type", "usage" })
        {
            var value = key[property]?.DeepClone();
            if (value is not null && property is "startDateTime" or "endDateTime")
            {
                value = JsonValue.Create(DateTimeOffset.Parse(value.GetValue<string>(), CultureInfo.InvariantCulture).ToUniversalTime().ToString("O", CultureInfo.InvariantCulture));
            }

            normalized[property] = value;
        }

        return normalized;
    }
}
