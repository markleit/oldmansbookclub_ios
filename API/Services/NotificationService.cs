using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using BookClubApi.Models;
using Microsoft.IdentityModel.Tokens;

namespace BookClubApi.Services;

public class NotificationService(IConfiguration config, IHttpClientFactory httpClientFactory, ILogger<NotificationService> logger)
{
    private readonly string _keyId = config["Apns:KeyId"]
        ?? throw new InvalidOperationException("Apns:KeyId not configured");
    private readonly string _teamId = config["Apns:TeamId"]
        ?? throw new InvalidOperationException("Apns:TeamId not configured");
    private readonly string _bundleId = config["Apple:BundleId"]
        ?? throw new InvalidOperationException("Apple:BundleId not configured");
    private readonly string _privateKey = config["Apns:PrivateKey"]
        ?? throw new InvalidOperationException("Apns:PrivateKey not configured");

    private readonly Lock _tokenLock = new();
    private string? _cachedToken;
    private DateTime _tokenExpiry = DateTime.MinValue;

    private Task<HttpResponseMessage> SendToApnsAsync(HttpClient client, string bearerToken, string deviceToken, string payload)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, $"/3/device/{deviceToken}");
        request.Version = HttpVersion.Version20;
        request.Headers.Authorization = new AuthenticationHeaderValue("bearer", bearerToken);
        request.Headers.Add("apns-topic", _bundleId);
        request.Headers.Add("apns-push-type", "alert");
        request.Headers.Add("apns-priority", "10");
        request.Content = new StringContent(payload, System.Text.Encoding.UTF8, "application/json");
        return client.SendAsync(request);
    }

    private string GetBearerToken()
    {
        lock (_tokenLock)
        {
            if (_cachedToken != null && DateTime.UtcNow < _tokenExpiry)
                return _cachedToken;

            var keyBase64 = _privateKey
                .Replace("-----BEGIN PRIVATE KEY-----", "")
                .Replace("-----END PRIVATE KEY-----", "")
                .Replace("\n", "").Replace("\r", "").Trim();

            var ecdsa = ECDsa.Create();
            ecdsa.ImportPkcs8PrivateKey(Convert.FromBase64String(keyBase64), out _);

            var key = new ECDsaSecurityKey(ecdsa) { KeyId = _keyId };
            var credentials = new SigningCredentials(key, SecurityAlgorithms.EcdsaSha256);

            var now = DateTime.UtcNow;
            var token = new JwtSecurityToken(
                issuer: _teamId,
                claims: [],
                notBefore: now,
                expires: now.AddMinutes(60),
                signingCredentials: credentials);

            _cachedToken = new JwtSecurityTokenHandler().WriteToken(token);
            _tokenExpiry = DateTime.UtcNow.AddMinutes(55);
            return _cachedToken;
        }
    }

    public async Task SendNewMessageAsync(IEnumerable<string> deviceTokens, MessageDto message, string bookTitle = "Book Club")
    {
        var alertBody = message.Type switch
        {
            MessageType.Voice => $"{message.SenderName} sent a voice message",
            MessageType.Photo => $"{message.SenderName} sent a photo",
            _ => message.Body?.Length > 60
                ? $"{message.SenderName}: {message.Body[..60]}…"
                : $"{message.SenderName}: {message.Body}"
        };

        var payload = JsonSerializer.Serialize(new
        {
            aps = new
            {
                alert = new { title = bookTitle, body = alertBody },
                sound = "default",
                badge = 1
            },
            clubId = message.ClubId.ToString()
        });

        var bearerToken = GetBearerToken();
        var prodClient = httpClientFactory.CreateClient("apns");
        var sandboxClient = httpClientFactory.CreateClient("apns-sandbox");

        var tasks = deviceTokens.Select(async deviceToken =>
        {
            var response = await SendToApnsAsync(prodClient, bearerToken, deviceToken, payload);
            if (!response.IsSuccessStatusCode)
            {
                var body = await response.Content.ReadAsStringAsync();
                if ((int)response.StatusCode == 400 && body.Contains("BadDeviceToken"))
                {
                    // Token might be from a sandbox/dev build — retry on sandbox
                    var sandboxResponse = await SendToApnsAsync(sandboxClient, bearerToken, deviceToken, payload);
                    if (!sandboxResponse.IsSuccessStatusCode)
                    {
                        var sandboxBody = await sandboxResponse.Content.ReadAsStringAsync();
                        logger.LogWarning("APNs sandbox push failed for token {Token}: {Status} {Body}",
                            deviceToken[..8], (int)sandboxResponse.StatusCode, sandboxBody);
                    }
                    else
                    {
                        logger.LogInformation("APNs sandbox push sent to {Token}", deviceToken[..8]);
                    }
                }
                else
                {
                    logger.LogWarning("APNs push failed for token {Token}: {Status} {Body}",
                        deviceToken[..8], (int)response.StatusCode, body);
                }
            }
            else
            {
                logger.LogInformation("APNs push sent to {Token}", deviceToken[..8]);
            }
        });

        await Task.WhenAll(tasks);
    }
}
