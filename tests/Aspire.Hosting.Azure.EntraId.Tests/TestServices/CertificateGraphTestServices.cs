// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

using Azure.Core;
using Microsoft.Identity.Client;

namespace Aspire.Hosting.Azure.EntraId.Tests.TestServices;

internal sealed class CertificateTestHttpMessageHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request, cancellationToken);
}

internal sealed class CertificateTestMsalHttpClientFactory(HttpClient client) : IMsalHttpClientFactory
{
    public HttpClient GetHttpClient() => client;
}

internal sealed class CertificateTestTokenCredential : TokenCredential, ITokenCredentialProvider
{
    public TokenCredential TokenCredential => this;

    public TokenRequestContext? LastRequest { get; private set; }

    public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        LastRequest = requestContext;
        return new AccessToken("test-graph-token", DateTimeOffset.UtcNow.AddHours(1));
    }

    public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
        ValueTask.FromResult(GetToken(requestContext, cancellationToken));
}
