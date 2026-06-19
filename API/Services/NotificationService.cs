using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Claims;
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

    private HttpRequestMessage BuildRequest(string deviceToken, string bearerToken, string payload)
    {
        var request = new HttpRequestMessage(HttpMethod.Post, $"/3/device/{deviceToken}");
        request.Version = HttpVersion.Version20;
        request.Headers.Authorization = new AuthenticationHeaderValue("bearer", bearerToken);
        request.Headers.Add("apns-topic", _bundleId);
        request.Headers.Add("apns-push-type", "alert");
        request.Headers.Add("apns-priority", "10");
        request.Content = new StringContent(payload, System.Text.Encoding.UTF8, "application/json");
        return request;
    }

    // Retries once on connection-level failure (stale HTTP/2 connection)
    private async Task<HttpResponseMessage> SendWithRetryAsync(HttpClient client, string bearerToken, string deviceToken, string payload)
    {
        try
        {
            return await client.SendAsync(BuildRequest(deviceToken, bearerToken, payload));
        }
        catch (HttpRequestException ex) when (ex.InnerException is System.IO.IOException or System.Net.Sockets.SocketException)
        {
            logger.LogWarning(ex, "APNs connection error for {Token}, retrying once", deviceToken[..8]);
            return await client.SendAsync(BuildRequest(deviceToken, bearerToken, payload));
        }
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

            var now = DateTimeOffset.UtcNow;
            var token = new JwtSecurityToken(
                issuer: _teamId,
                claims: [new Claim("iat", now.ToUnixTimeSeconds().ToString(), ClaimValueTypes.Integer64)],
                signingCredentials: credentials);

            _cachedToken = new JwtSecurityTokenHandler().WriteToken(token);
            _tokenExpiry = now.AddMinutes(55).UtcDateTime;
            return _cachedToken;
        }
    }

    public async Task SendJoinRequestNotificationAsync(IEnumerable<string> adminTokens, string requesterName, string clubName)
    {
        var payload = JsonSerializer.Serialize(new
        {
            aps = new
            {
                alert = new { title = "New Join Request", body = $"{requesterName} wants to join {clubName}" },
                sound = "default"
            },
            type = "join_request"
        });
        await SendToAllAsync(adminTokens, payload);
    }

    public async Task SendJoinResponseNotificationAsync(string deviceToken, string clubName, bool approved)
    {
        var payload = JsonSerializer.Serialize(new
        {
            aps = new
            {
                alert = new
                {
                    title = approved ? "Request Approved" : "Request Declined",
                    body = approved
                        ? $"You've been approved to join {clubName}!"
                        : $"Your request to join {clubName} was not approved."
                },
                sound = "default"
            },
            type = approved ? "join_approved" : "join_declined"
        });
        await SendToAllAsync([deviceToken], payload);
    }

    public async Task SendNewMessageAsync(IEnumerable<string> deviceTokens, MessageDto message, string bookTitle = "Book Club", Guid bookId = default, int badge = 1)
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
                badge
            },
            clubId = message.ClubId.ToString(),
            bookId = bookId.ToString(),
            messageId = message.Id.ToString()
        });

        await SendToAllAsync(deviceTokens, payload);
    }

    private async Task SendToAllAsync(IEnumerable<string> deviceTokens, string payload)
    {
        var bearerToken = GetBearerToken();
        var prodClient = httpClientFactory.CreateClient("apns");
        var sandboxClient = httpClientFactory.CreateClient("apns-sandbox");

        var tasks = deviceTokens.Select(async deviceToken =>
        {
            try
            {
                var response = await SendWithRetryAsync(prodClient, bearerToken, deviceToken, payload);
                if (!response.IsSuccessStatusCode)
                {
                    var body = await response.Content.ReadAsStringAsync();
                    if ((int)response.StatusCode == 400 && body.Contains("BadDeviceToken"))
                    {
                        // Sandbox token — try sandbox endpoint
                        var sandboxResponse = await SendWithRetryAsync(sandboxClient, bearerToken, deviceToken, payload);
                        if (!sandboxResponse.IsSuccessStatusCode)
                        {
                            var sandboxBody = await sandboxResponse.Content.ReadAsStringAsync();
                            logger.LogWarning("APNs sandbox push failed {Token}: {Status} {Body}",
                                deviceToken[..8], (int)sandboxResponse.StatusCode, sandboxBody);
                        }
                        else
                        {
                            logger.LogWarning("APNs sandbox push delivered to {Token}", deviceToken[..8]);
                        }
                    }
                    else
                    {
                        logger.LogWarning("APNs push failed {Token}: {Status} {Body}",
                            deviceToken[..8], (int)response.StatusCode, body);
                    }
                }
                else
                {
                    logger.LogWarning("APNs push delivered to {Token}", deviceToken[..8]);
                }
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "APNs push threw for token {Token}", deviceToken[..8]);
            }
        });

        await Task.WhenAll(tasks);
    }
}
