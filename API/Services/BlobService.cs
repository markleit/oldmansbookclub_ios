using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Sas;

namespace BookClubApi.Services;

public class BlobService
{
    private readonly BlobServiceClient _client;
    private const string MediaContainer = "club-media";
    private const string AvatarContainer = "avatars";

    private UserDelegationKey? _cachedKey;
    private DateTimeOffset _cachedKeyExpiry;
    private readonly SemaphoreSlim _keySemaphore = new(1, 1);

    // Dev and prod are two separate real Azure Storage accounts (not Azurite — SAS generation
    // goes through GetUserDelegationKeyAsync, an Azure AD user-delegation SAS, which Azurite only
    // supports via account-key SAS). Same branch pattern as Program.cs's SignalR dev/prod split.
    // NOTE: `oldmansbookclubdev` needs "Storage Blob Data Contributor" + "Storage Blob Delegator"
    // granted to whichever identity runs locally (DefaultAzureCredential falls back to your `az
    // login` session outside Azure) — without those roles, GetUserDelegationKeyAsync 403s.
    public BlobService(IHostEnvironment env)
    {
        var accountUri = env.IsDevelopment()
            ? "https://oldmansbookclubdev.blob.core.windows.net"
            : "https://oldmansbookclubstore.blob.core.windows.net";
        _client = new BlobServiceClient(new Uri(accountUri), new DefaultAzureCredential());
    }

    /// The storage host this deployment actually writes to. Anything validating that a
    /// client-supplied media URL is one of ours has to compare against this rather than a
    /// hardcoded literal — dev and prod are different accounts (see the constructor), so a
    /// literal is necessarily wrong in one of them.
    public string AccountHost => _client.Uri.Host;

    private static readonly HashSet<string> AllowedExtensions = new(StringComparer.OrdinalIgnoreCase) { "m4a", "jpg", "jpeg", "mp4" };

    public async Task<(string UploadUrl, string MediaUrl)> GenerateUploadUrlAsync(Guid clubId, string? extension = null)
    {
        var ext = (extension ?? "m4a").TrimStart('.');
        if (!AllowedExtensions.Contains(ext)) ext = "m4a";  // safe default, container doesn't care
        var blobName = $"{clubId}/{Guid.NewGuid()}.{ext.ToLowerInvariant()}";
        // 60 min (was 10): large videos upload phone→blob via a background URLSession that iOS can
        // delay/suspend; a big clip on cellular can exceed a short window and 403 mid-upload. The
        // container is private and blob names are random GUIDs, so a longer write window is low-risk.
        var uploadUrl = await GenerateUserDelegationSasAsync(MediaContainer, blobName,
            BlobSasPermissions.Write | BlobSasPermissions.Create, TimeSpan.FromMinutes(60));
        // Plain URL — SAS is added fresh when serving messages, so it never expires in the DB
        var plainUrl = _client.GetBlobContainerClient(MediaContainer).GetBlobClient(blobName).Uri.ToString();
        return (uploadUrl, plainUrl);
    }

    public async Task<(string UploadUrl, string AvatarUrl)> GenerateAvatarUploadUrlAsync(Guid userId)
    {
        var containerClient = _client.GetBlobContainerClient(AvatarContainer);
        await containerClient.CreateIfNotExistsAsync(PublicAccessType.None);

        var blobName = $"{userId}/avatar.jpg";
        var blobClient = containerClient.GetBlobClient(blobName);

        var uploadUrl = await GenerateUserDelegationSasAsync(AvatarContainer, blobName,
            BlobSasPermissions.Write | BlobSasPermissions.Create, TimeSpan.FromMinutes(10));

        return (uploadUrl, blobClient.Uri.ToString());
    }

    public async Task<string> GenerateAvatarReadUrlAsync(Guid userId, DateTime? avatarUpdatedAt = null)
    {
        var blobName = $"{userId}/avatar.jpg";
        var url = await GenerateUserDelegationSasAsync(AvatarContainer, blobName,
            BlobSasPermissions.Read, TimeSpan.FromDays(7));
        // Cache-bust hint as a URL fragment. Fragments aren't sent over HTTP so the
        // blob fetch is unaffected, but iOS preserves the fragment in its image
        // cache key — so when the avatar is replaced, the version changes and the
        // path-based key no longer collides with the prior cached bytes.
        if (avatarUpdatedAt is DateTime t)
        {
            var unix = ((DateTimeOffset)DateTime.SpecifyKind(t, DateTimeKind.Utc)).ToUnixTimeSeconds();
            url += $"#v={unix}";
        }
        return url;
    }

    // Returns a cached delegation key valid for 7 days. Refreshes only when within 1 hour of expiry.
    // Thread-safe via SemaphoreSlim — safe because BlobService is registered as Singleton.
    public async Task<(UserDelegationKey Key, DateTimeOffset ExpiresOn)> GetReadDelegationKeyAsync()
    {
        if (_cachedKey != null && _cachedKeyExpiry > DateTimeOffset.UtcNow.AddHours(1))
            return (_cachedKey, _cachedKeyExpiry);

        await _keySemaphore.WaitAsync();
        try
        {
            if (_cachedKey != null && _cachedKeyExpiry > DateTimeOffset.UtcNow.AddHours(1))
                return (_cachedKey, _cachedKeyExpiry);

            var startsOn = DateTimeOffset.UtcNow.AddMinutes(-5);
            var expiresOn = DateTimeOffset.UtcNow.AddDays(7);
            // 12.29 replaced the (startsOn, expiresOn) overload with an options object. StartsOn is
            // optional there (null = start immediately); we set it explicitly to keep the same
            // 5-minute clock-skew allowance the previous call had.
            var key = await _client.GetUserDelegationKeyAsync(
                new BlobGetUserDelegationKeyOptions(expiresOn) { StartsOn = startsOn });
            _cachedKey = key;
            _cachedKeyExpiry = expiresOn;
            return (key, expiresOn);
        }
        finally
        {
            _keySemaphore.Release();
        }
    }

    // Synchronous — strips any existing SAS query params, generates a fresh read SAS.
    // Handles both old DB rows (SAS URL) and new rows (plain URL).
    // Actual stored size of an uploaded blob, in bytes — used to enforce per-type size
    // limits server-side (a client can't bypass the limit by uploading a larger file).
    // Returns null if the blob can't be found / read.
    public async Task<long?> GetBlobSizeAsync(string storedUrl)
    {
        var plainUrl = storedUrl.Split('?')[0];
        if (!Uri.TryCreate(plainUrl, UriKind.Absolute, out var uri)) return null;
        var segments = uri.AbsolutePath.TrimStart('/').Split('/', 2);
        if (segments.Length < 2) return null;
        try
        {
            var blobClient = _client.GetBlobContainerClient(segments[0]).GetBlobClient(segments[1]);
            var props = await blobClient.GetPropertiesAsync();
            return props.Value.ContentLength;
        }
        catch
        {
            return null;
        }
    }

    public string? GenerateFreshReadUrl(string? storedUrl, UserDelegationKey key, DateTimeOffset keyExpiresOn)
    {
        if (storedUrl is null) return null;

        var plainUrl = storedUrl.Split('?')[0];
        if (!Uri.TryCreate(plainUrl, UriKind.Absolute, out var uri)) return storedUrl;

        var segments = uri.AbsolutePath.TrimStart('/').Split('/', 2);
        if (segments.Length < 2) return storedUrl;

        var containerName = segments[0];
        var blobName = segments[1];
        var blobUri = _client.GetBlobContainerClient(containerName).GetBlobClient(blobName).Uri;

        // SAS expiry must not exceed the key's own expiry
        var sasBuilder = new BlobSasBuilder
        {
            BlobContainerName = containerName,
            BlobName = blobName,
            Resource = "b",
            StartsOn = DateTimeOffset.UtcNow.AddMinutes(-5),
            ExpiresOn = keyExpiresOn.AddHours(-1)
        };
        sasBuilder.SetPermissions(BlobSasPermissions.Read);

        var sasParams = sasBuilder.ToSasQueryParameters(key, _client.AccountName);
        return new UriBuilder(blobUri) { Query = sasParams.ToString() }.Uri.ToString();
    }

    private async Task<string> GenerateUserDelegationSasAsync(
        string containerName, string blobName, BlobSasPermissions permissions, TimeSpan validity)
    {
        var containerClient = _client.GetBlobContainerClient(containerName);
        await containerClient.CreateIfNotExistsAsync(PublicAccessType.None);

        var startsOn = DateTimeOffset.UtcNow.AddMinutes(-5);
        var expiresOn = DateTimeOffset.UtcNow.Add(validity);

        var delegationKey = await _client.GetUserDelegationKeyAsync(
            new BlobGetUserDelegationKeyOptions(expiresOn) { StartsOn = startsOn });

        var sasBuilder = new BlobSasBuilder
        {
            BlobContainerName = containerName,
            BlobName = blobName,
            Resource = "b",
            StartsOn = startsOn,
            ExpiresOn = expiresOn
        };
        sasBuilder.SetPermissions(permissions);

        var sasParams = sasBuilder.ToSasQueryParameters(delegationKey, _client.AccountName);
        var blobUri = _client.GetBlobContainerClient(containerName).GetBlobClient(blobName).Uri;
        return new UriBuilder(blobUri) { Query = sasParams.ToString() }.Uri.ToString();
    }
}
