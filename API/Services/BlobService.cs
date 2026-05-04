using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Sas;

namespace BookClubApi.Services;

public class BlobService(IConfiguration config)
{
    private readonly BlobServiceClient _client = new(config["Azure:StorageConnectionString"]);
    private const string Container = "voice-messages";

    public async Task<(string UploadUrl, string MediaUrl)> GenerateUploadUrlAsync(Guid clubId)
    {
        var containerClient = _client.GetBlobContainerClient(Container);
        await containerClient.CreateIfNotExistsAsync(PublicAccessType.None);

        var blobName = $"{clubId}/{Guid.NewGuid()}.m4a";
        var blobClient = containerClient.GetBlobClient(blobName);

        var uploadSas = new BlobSasBuilder
        {
            BlobContainerName = Container,
            BlobName = blobName,
            Resource = "b",
            ExpiresOn = DateTimeOffset.UtcNow.AddMinutes(10)
        };
        uploadSas.SetPermissions(BlobSasPermissions.Write | BlobSasPermissions.Create);

        var readSas = new BlobSasBuilder
        {
            BlobContainerName = Container,
            BlobName = blobName,
            Resource = "b",
            ExpiresOn = DateTimeOffset.UtcNow.AddHours(24)
        };
        readSas.SetPermissions(BlobSasPermissions.Read);

        var uploadUrl = blobClient.GenerateSasUri(uploadSas).ToString();
        var mediaUrl = blobClient.GenerateSasUri(readSas).ToString();

        return (uploadUrl, mediaUrl);
    }
}
