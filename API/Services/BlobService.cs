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
        var readUrl = await GenerateUserDelegationSasAsync(MediaContainer, blobName,
            BlobSasPermissions.Read, TimeSpan.FromDays(7));
        return (uploadUrl, readUrl);
    }

    public async Task<(string UploadUrl, string AvatarUrl)> GenerateAvatarUploadUrlAsync(Guid userId)
    {
        var containerClient = _client.GetBlobContainerClient(AvatarContainer);
        await containerClient.CreateIfNotExistsAsync(PublicAccessType.Blob);

        var blobName = $"{userId}/avatar.jpg";
        var blobClient = containerClient.GetBlobClient(blobName);

        var uploadUrl = await GenerateUserDelegationSasAsync(AvatarContainer, blobName,
            BlobSasPermissions.Write | BlobSasPermissions.Create, TimeSpan.FromMinutes(10));

        // Avatar container is publicly readable — return plain URL, no SAS needed
        return (uploadUrl, blobClient.Uri.ToString());
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
