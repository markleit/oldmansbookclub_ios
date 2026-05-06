using System.IdentityModel.Tokens.Jwt;
using System.Security.Cryptography;
using Microsoft.IdentityModel.Tokens;

namespace BookClubApi.Services;

public class AppleTokenValidator(IHttpClientFactory httpClientFactory, ILogger<AppleTokenValidator> logger)
{
    private const string AppleKeysUrl = "https://appleid.apple.com/auth/keys";
    private const string AppleIssuer = "https://appleid.apple.com";

    public async Task<string?> ValidateAsync(string identityToken, string bundleId)
    {
        var keys = await FetchApplePublicKeysAsync();
        var handler = new JwtSecurityTokenHandler { MapInboundClaims = false };

        var validationParams = new TokenValidationParameters
        {
            ValidIssuer = AppleIssuer,
            ValidAudience = bundleId,
            IssuerSigningKeys = keys,
            ValidateLifetime = true
        };

        try
        {
            var principal = handler.ValidateToken(identityToken, validationParams, out _);
            return principal.FindFirst("sub")?.Value;
        }
        catch (Exception ex)
        {
            logger.LogWarning("Apple token validation failed: {Message}", ex.Message);
            return null;
        }
    }

    private async Task<IEnumerable<SecurityKey>> FetchApplePublicKeysAsync()
    {
        var client = httpClientFactory.CreateClient();
        var response = await client.GetFromJsonAsync<AppleKeysResponse>(AppleKeysUrl);
        return response?.Keys.Select(k =>
        {
            var rsa = RSA.Create();
            rsa.ImportParameters(new RSAParameters
            {
                Modulus = Base64UrlEncoder.DecodeBytes(k.N),
                Exponent = Base64UrlEncoder.DecodeBytes(k.E)
            });
            return (SecurityKey)new RsaSecurityKey(rsa) { KeyId = k.Kid };
        }) ?? [];
    }

    private record AppleKeysResponse(AppleKey[] Keys);
    private record AppleKey(string Kid, string N, string E);
}
