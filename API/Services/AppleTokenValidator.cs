using System.IdentityModel.Tokens.Jwt;
using System.Net.Http.Headers;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.IdentityModel.Tokens;

namespace BookClubApi.Services;

public class AppleTokenValidator(IHttpClientFactory httpClientFactory, IConfiguration config, ILogger<AppleTokenValidator> logger)
{
    private const string AppleKeysUrl = "https://appleid.apple.com/auth/keys";
    private const string AppleIssuer = "https://appleid.apple.com";

    // Apple's JWKs rotate rarely; cache them process-wide (this service is scoped, so a
    // per-instance cache wouldn't survive across logins). TTL bounds staleness; an
    // unknown key id (rotation mid-TTL) forces a one-off refresh below.
    private static readonly TimeSpan KeysTtl = TimeSpan.FromHours(12);
    private static readonly SemaphoreSlim KeysGate = new(1, 1);
    private static List<SecurityKey>? _cachedKeys;
    private static DateTimeOffset _cachedAt;

    public async Task<string?> ValidateAsync(string identityToken, string bundleId)
    {
        var handler = new JwtSecurityTokenHandler { MapInboundClaims = false };

        TokenValidationParameters Params(IEnumerable<SecurityKey> keys) => new()
        {
            ValidIssuer = AppleIssuer,
            ValidAudience = bundleId,
            IssuerSigningKeys = keys,
            ValidateLifetime = true
        };

        try
        {
            var keys = await GetApplePublicKeysAsync(forceRefresh: false);
            try
            {
                var principal = handler.ValidateToken(identityToken, Params(keys), out _);
                return principal.FindFirst("sub")?.Value;
            }
            catch (SecurityTokenSignatureKeyNotFoundException)
            {
                // Keys likely rotated since we cached — refresh once and retry.
                var fresh = await GetApplePublicKeysAsync(forceRefresh: true);
                var principal = handler.ValidateToken(identityToken, Params(fresh), out _);
                return principal.FindFirst("sub")?.Value;
            }
        }
        catch (Exception ex)
        {
            logger.LogWarning("Apple token validation failed: {Message}", ex.Message);
            return null;
        }
    }

    private async Task<List<SecurityKey>> GetApplePublicKeysAsync(bool forceRefresh)
    {
        if (!forceRefresh && _cachedKeys is { Count: > 0 } && DateTimeOffset.UtcNow - _cachedAt < KeysTtl)
            return _cachedKeys;

        await KeysGate.WaitAsync();
        try
        {
            if (!forceRefresh && _cachedKeys is { Count: > 0 } && DateTimeOffset.UtcNow - _cachedAt < KeysTtl)
                return _cachedKeys;

            var client = httpClientFactory.CreateClient();
            var response = await client.GetFromJsonAsync<AppleKeysResponse>(AppleKeysUrl);
            var keys = response?.Keys.Select(k =>
            {
                var rsa = RSA.Create();
                rsa.ImportParameters(new RSAParameters
                {
                    Modulus = Base64UrlEncoder.DecodeBytes(k.N),
                    Exponent = Base64UrlEncoder.DecodeBytes(k.E)
                });
                return (SecurityKey)new RsaSecurityKey(rsa) { KeyId = k.Kid };
            }).ToList() ?? [];

            if (keys.Count > 0)
            {
                _cachedKeys = keys;
                _cachedAt = DateTimeOffset.UtcNow;
            }
            return keys;
        }
        finally
        {
            KeysGate.Release();
        }
    }

    public async Task<string?> ExchangeCodeForRefreshTokenAsync(string authorizationCode, string bundleId)
    {
        try
        {
            var content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["client_id"] = bundleId,
                ["client_secret"] = GenerateClientSecret(bundleId),
                ["code"] = authorizationCode,
                ["grant_type"] = "authorization_code"
            });
            var client = httpClientFactory.CreateClient();
            var response = await client.PostAsync("https://appleid.apple.com/auth/token", content);
            if (!response.IsSuccessStatusCode) return null;
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            return doc.RootElement.TryGetProperty("refresh_token", out var rt) ? rt.GetString() : null;
        }
        catch (Exception ex)
        {
            logger.LogWarning("Apple token exchange failed: {Message}", ex.Message);
            return null;
        }
    }

    public async Task RevokeRefreshTokenAsync(string refreshToken, string bundleId)
    {
        try
        {
            var content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["client_id"] = bundleId,
                ["client_secret"] = GenerateClientSecret(bundleId),
                ["token"] = refreshToken,
                ["token_type_hint"] = "refresh_token"
            });
            var client = httpClientFactory.CreateClient();
            await client.PostAsync("https://appleid.apple.com/auth/revoke", content);
        }
        catch (Exception ex)
        {
            logger.LogWarning("Apple token revocation failed: {Message}", ex.Message);
        }
    }

    private string GenerateClientSecret(string bundleId)
    {
        var keyId = config["Apple:SignInKeyId"] ?? config["Apns:KeyId"]
            ?? throw new InvalidOperationException("Apple signing key ID not configured");
        var teamId = config["Apns:TeamId"]
            ?? throw new InvalidOperationException("Apns:TeamId not configured");
        var privateKey = config["Apple:SignInPrivateKey"] ?? config["Apns:PrivateKey"]
            ?? throw new InvalidOperationException("Apple signing private key not configured");

        var keyBase64 = privateKey
            .Replace("-----BEGIN PRIVATE KEY-----", "")
            .Replace("-----END PRIVATE KEY-----", "")
            .Replace("\n", "").Replace("\r", "").Trim();

        var ecdsa = ECDsa.Create();
        ecdsa.ImportPkcs8PrivateKey(Convert.FromBase64String(keyBase64), out _);

        var key = new ECDsaSecurityKey(ecdsa) { KeyId = keyId };
        var now = DateTimeOffset.UtcNow;
        var token = new JwtSecurityToken(
            issuer: teamId,
            audience: "https://appleid.apple.com",
            claims: [
                new Claim("sub", bundleId),
                new Claim("iat", now.ToUnixTimeSeconds().ToString(), ClaimValueTypes.Integer64)
            ],
            expires: now.AddMonths(6).UtcDateTime,
            signingCredentials: new SigningCredentials(key, SecurityAlgorithms.EcdsaSha256));

        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    private record AppleKeysResponse(AppleKey[] Keys);
    private record AppleKey(string Kid, string N, string E);
}
