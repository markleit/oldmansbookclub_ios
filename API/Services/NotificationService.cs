using System.Collections.Concurrent;
using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text.Json;
using BookClubApi.Data;
using BookClubApi.Models;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;

namespace BookClubApi.Services;

public class NotificationService(IConfiguration config, IHttpClientFactory httpClientFactory, IServiceScopeFactory scopeFactory, ILogger<NotificationService> logger)
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

    public async Task SendJoinResponseNotificationAsync(IEnumerable<string> deviceTokens, string clubName, bool approved)
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
        await SendToAllAsync(deviceTokens, payload);
    }

    public async Task SendNewMessageAsync(IEnumerable<string> deviceTokens, MessageDto message, string bookTitle = "Book Club", Guid bookId = default, int badge = 1, int bookUnread = -1)
    {
        var alertBody = message.Type switch
        {
            MessageType.Voice => $"{message.SenderName} sent a voice message",
            MessageType.Photo => $"{message.SenderName} sent a photo",
            _ => message.Body?.Length > 60
                ? $"{message.SenderName}: {message.Body[..60]}…"
                : $"{message.SenderName}: {message.Body}"
        };

        // content-available:1 wakes the client in the background to prefetch the message into its
        // chat cache (instant open). Kept alongside the visible alert as a combined push, so the
        // banner still shows; background execution is best-effort (iOS throttles it). A Dictionary
        // is used for aps because the key literally contains a hyphen.
        var payload = JsonSerializer.Serialize(new
        {
            aps = new Dictionary<string, object>
            {
                ["alert"] = new { title = bookTitle, body = alertBody },
                ["sound"] = "default",
                ["badge"] = badge,
                ["content-available"] = 1
            },
            clubId = message.ClubId.ToString(),
            bookId = bookId.ToString(),
            messageId = message.Id.ToString(),
            // The recipient's unread count for THIS book, so a woken client can set it exactly
            // rather than incrementing a number it can't verify (#119). -1 = not supplied.
            bookUnread
        });

        await SendToAllAsync(deviceTokens, payload);
    }

    private async Task SendToAllAsync(IEnumerable<string> deviceTokens, string payload)
    {
        // Single choke point for all three public send methods (#120 half A). Dev never calls
        // Apple — a dev/test account's messages must not push real devices. Real push behaviour
        // is verified deliberately, by pointing a client at the Production preset instead.
        if (!config.GetValue("Apns:Enabled", true))
        {
            var tokenList = deviceTokens.ToList();
            logger.LogInformation("Apns:Enabled=false — skipping push to {Count} device(s)", tokenList.Count);
            return;
        }

        var bearerToken = GetBearerToken();
        var prodClient = httpClientFactory.CreateClient("apns");
        var sandboxClient = httpClientFactory.CreateClient("apns-sandbox");

        // Tokens APNs told us are permanently invalid (uninstalled / bad token on both
        // environments). Collected here, then pruned from the DB after all sends finish so a
        // dead token stops being retried on every message (self-cleaning). #25.
        var deadTokens = new ConcurrentBag<string>();

        var tasks = deviceTokens.Select(async deviceToken =>
        {
            try
            {
                var response = await SendWithRetryAsync(prodClient, bearerToken, deviceToken, payload);
                if (response.IsSuccessStatusCode)
                {
                    logger.LogWarning("APNs push delivered to {Token}", deviceToken[..8]);
                    return;
                }

                var body = await response.Content.ReadAsStringAsync();
                var status = (int)response.StatusCode;

                // 410 Unregistered = a valid PRODUCTION token whose app was uninstalled → prune.
                if (status == 410)
                {
                    deadTokens.Add(deviceToken);
                    logger.LogWarning("APNs token unregistered (prod) {Token} — pruning", deviceToken[..8]);
                    return;
                }

                // 400 BadDeviceToken on prod usually just means it's a SANDBOX (dev-build) token —
                // retry on the sandbox endpoint before deciding it's dead.
                if (status == 400 && body.Contains("BadDeviceToken"))
                {
                    var sandboxResponse = await SendWithRetryAsync(sandboxClient, bearerToken, deviceToken, payload);
                    if (sandboxResponse.IsSuccessStatusCode)
                    {
                        logger.LogWarning("APNs sandbox push delivered to {Token}", deviceToken[..8]);
                        return;
                    }

                    var sandboxBody = await sandboxResponse.Content.ReadAsStringAsync();
                    var sandboxStatus = (int)sandboxResponse.StatusCode;
                    // Dead on BOTH environments (uninstalled sandbox app, or a genuinely malformed
                    // token) → prune. Other sandbox failures are treated as transient.
                    if (sandboxStatus == 410 || (sandboxStatus == 400 && sandboxBody.Contains("BadDeviceToken")))
                    {
                        deadTokens.Add(deviceToken);
                        logger.LogWarning("APNs token dead on prod+sandbox {Token}: {Status} {Body} — pruning",
                            deviceToken[..8], sandboxStatus, sandboxBody);
                    }
                    else
                    {
                        logger.LogWarning("APNs sandbox push failed {Token}: {Status} {Body}",
                            deviceToken[..8], sandboxStatus, sandboxBody);
                    }
                    return;
                }

                // Everything else (403 auth, 429 throttle, 5xx) is transient — don't prune.
                logger.LogWarning("APNs push failed {Token}: {Status} {Body}", deviceToken[..8], status, body);
            }
            catch (Exception ex)
            {
                logger.LogWarning(ex, "APNs push threw for token {Token}", deviceToken[..8]);
            }
        });

        await Task.WhenAll(tasks);

        if (!deadTokens.IsEmpty)
            await PruneDeadTokensAsync(deadTokens.Distinct().ToList());
    }

    // Delete any UserDevices rows still holding a dead token. The DeviceToken match makes this
    // race-safe: if the device has already re-registered a fresh token, the row won't match and is
    // left alone. NotificationService is a singleton, so we resolve a scoped DbContext per prune.
    private async Task PruneDeadTokensAsync(List<string> deadTokens)
    {
        try
        {
            using var scope = scopeFactory.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
            var pruned = await db.UserDevices
                .Where(d => deadTokens.Contains(d.DeviceToken))
                .ExecuteDeleteAsync();
            if (pruned > 0)
                logger.LogWarning("Pruned {Count} dead device token(s)", pruned);
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Failed to prune dead device tokens");
        }
    }
}
