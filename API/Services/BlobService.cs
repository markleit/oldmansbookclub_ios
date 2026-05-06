using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Sas;

namespace BookClubApi.Services;

public class BlobService(IConfiguration config)
{
    private readonly BlobServiceClient _client = new(config["Azure:StorageConnectionString"]);
    private const string MediaContainer = "club-media";
    private const string AvatarContainer = "avatars";

    public async Task<(string UploadUrl, string MediaUrl)> GenerateUploadUrlAsync(Guid clubId)
    {
        return await GenerateSasUrlPairAsync(MediaContainer, $"{clubId}/{Guid.NewGuid()}.m4a",
            uploadMinutes: 10, readHours: 24);
    }

    public async Task<(string UploadUrl, string AvatarUrl)> GenerateAvatarUploadUrlAsync(Guid userId)
    {
        // Avatar is permanent — use a long-lived read SAS (1 year)
        return await GenerateSasUrlPairAsync(AvatarContainer, $"{userId}/avatar.jpg",
            uploadMinutes: 10, readHours: 24 * 365);
    }

    private async Task<(string UploadUrl, string MediaUrl)> GenerateSasUrlPairAsync(
        string containerName, string blobName, int uploadMinutes, int readHours)
    {
        var containerClient = _client.GetBlobContainerClient(containerName);
        await containerClient.CreateIfNotExistsAsync(PublicAccessType.None);

        var blobClient = containerClient.GetBlobClient(blobName);

        var uploadSas = new BlobSasBuilder
        {
            BlobContainerName = containerName,
            BlobName = blobName,
            Resource = "b",
            ExpiresOn = DateTimeOffset.UtcNow.AddMinutes(uploadMinutes)
        };
        uploadSas.SetPermissions(BlobSasPermissions.Write | BlobSasPermissions.Create);

        var readSas = new BlobSasBuilder
        {
            BlobContainerName = containerName,
            BlobName = blobName,
            Resource = "b",
            ExpiresOn = DateTimeOffset.UtcNow.AddHours(readHours)
        };
        readSas.SetPermissions(BlobSasPermissions.Read);

        return (blobClient.GenerateSasUri(uploadSas).ToString(),
                blobClient.GenerateSasUri(readSas).ToString());
    }
}
