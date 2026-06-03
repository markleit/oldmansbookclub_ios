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

    public BlobService()
    {
        _client = new BlobServiceClient(
            new Uri("https://oldmansbookclubstore.blob.core.windows.net"),
            new DefaultAzureCredential());
    }

    public async Task<(string UploadUrl, string MediaUrl)> GenerateUploadUrlAsync(Guid clubId)
    {
        var blobName = $"{clubId}/{Guid.NewGuid()}.m4a";
        var uploadUrl = await GenerateUserDelegationSasAsync(MediaContainer, blobName,
            BlobSasPermissions.Write | BlobSasPermissions.Create, TimeSpan.FromMinutes(10));
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

    public Task<string> GenerateAvatarReadUrlAsync(Guid userId)
    {
        var blobName = $"{userId}/avatar.jpg";
        return GenerateUserDelegationSasAsync(AvatarContainer, blobName,
            BlobSasPermissions.Read, TimeSpan.FromDays(7));
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
            var key = await _client.GetUserDelegationKeyAsync(startsOn, expiresOn);
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

        var delegationKey = await _client.GetUserDelegationKeyAsync(startsOn, expiresOn);

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
