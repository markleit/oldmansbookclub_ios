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
        await containerClient.CreateIfNotExistsAsync(PublicAccessType.Blob);

        var blobName = $"{clubId}/{Guid.NewGuid()}.m4a";
        var blobClient = containerClient.GetBlobClient(blobName);

        var sasBuilder = new BlobSasBuilder
        {
            BlobContainerName = Container,
            BlobName = blobName,
            Resource = "b",
            ExpiresOn = DateTimeOffset.UtcNow.AddMinutes(10)
        };
        sasBuilder.SetPermissions(BlobSasPermissions.Write | BlobSasPermissions.Create);

        var uploadUrl = blobClient.GenerateSasUri(sasBuilder).ToString();
        var mediaUrl = blobClient.Uri.ToString();

        return (uploadUrl, mediaUrl);
    }
}
