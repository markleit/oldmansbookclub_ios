using Azure.Storage.Blobs.Models;
using BookClubApi.Services;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Hosting;

namespace BookClubApi.Tests.Infrastructure;

/// Stands in for Azure Blob Storage. Every real BlobService call needs network access and an
/// identity holding "Storage Blob Data Contributor" + "Storage Blob Delegator" — a CI runner has
/// neither, and a developer's `az login` session is not something tests should depend on.
///
/// It is a subclass rather than a mock on purpose: <c>AccountHost</c> stays a real, single source
/// of truth, so <c>MessageSendService.IsOwnBlobUrl</c> is exercised for real. A test that sends a
/// URL on <see cref="Host"/> is accepted; one on any other host is rejected — which is precisely
/// the check that broke every dev media send when #120 moved dev to a separate storage account.
public sealed class FakeBlobService() : BlobService(TestEnvironment)
{
    public const string Host = "ombctest.blob.core.windows.net";

    /// Set by a test to make the next size check fail the server-side cap. Null means "unknown
    /// size", which the production code treats as acceptable (`size is > 0 && size > max`).
    public long? NextBlobSize { get; set; }

    public override string AccountHost => Host;

    public override Task<(string UploadUrl, string MediaUrl)> GenerateUploadUrlAsync(Guid clubId, string? extension = null)
    {
        var ext = (extension ?? "m4a").TrimStart('.');
        var plain = $"https://{Host}/club-media/{clubId}/{Guid.NewGuid()}.{ext}";
        return Task.FromResult((plain + "?sig=fake-write", plain));
    }

    public override Task<(string UploadUrl, string AvatarUrl)> GenerateAvatarUploadUrlAsync(Guid userId)
    {
        var plain = $"https://{Host}/avatars/{userId}/avatar.jpg";
        return Task.FromResult((plain + "?sig=fake-write", plain));
    }

    public override Task<string> GenerateAvatarReadUrlAsync(Guid userId, DateTime? avatarUpdatedAt = null)
        => Task.FromResult($"https://{Host}/avatars/{userId}/avatar.jpg?sig=fake-read");

    public override Task<(UserDelegationKey Key, DateTimeOffset ExpiresOn)> GetReadDelegationKeyAsync()
    {
        var expiry = DateTimeOffset.UtcNow.AddHours(1);
        var key = BlobsModelFactory.UserDelegationKey(
            Guid.Empty.ToString(),
            Guid.Empty.ToString(),
            DateTimeOffset.UtcNow.AddMinutes(-5),
            expiry,
            "b",
            "2021-08-06",
            Convert.ToBase64String("fake-delegation-key"u8.ToArray()));
        return Task.FromResult((key, expiry));
    }

    public override Task<long?> GetBlobSizeAsync(string storedUrl) => Task.FromResult(NextBlobSize);

    public override string NewMediaBlobUrl(Guid clubId, string extension) =>
        $"https://{Host}/club-media/{clubId}/{Guid.NewGuid()}.{extension}";

    /// The validity the last video upload link was made with — what the app's upload can wait.
    public TimeSpan? LastVideoUploadLinkValidity { get; private set; }

    public override Task<string> GenerateVideoUploadUrlAsync(string mediaUrl, TimeSpan validity)
    {
        LastVideoUploadLinkValidity = validity;
        return Task.FromResult(mediaUrl.Split('?')[0] + "?sig=fake-create");
    }

    private readonly Dictionary<string, IDictionary<string, string>> _landed = [];

    /// A test puts a file "in storage" — what the app's upload would have done, with whatever
    /// metadata it sent — before telling the server it landed. Nothing else is in storage, so a
    /// report of anything else is false.
    public void Land(string mediaUrl, IDictionary<string, string>? metadata = null)
    {
        lock (_landed)
            _landed[mediaUrl.Split('?')[0]] = new Dictionary<string, string>(
                metadata ?? new Dictionary<string, string>(), StringComparer.OrdinalIgnoreCase);
    }

    public override Task<IDictionary<string, string>?> GetBlobMetadataAsync(string storedUrl)
    {
        lock (_landed) return Task.FromResult(_landed.GetValueOrDefault(storedUrl.Split('?')[0]));
    }

    /// A file stored by the one-request voice/photo send (#204), as the server handed it over.
    public sealed record StoredUpload(string Url, byte[] Bytes, string ContentType);

    private readonly List<StoredUpload> _uploads = [];
    private readonly List<string> _deleted = [];

    public IReadOnlyList<StoredUpload> Uploads { get { lock (_uploads) return [.. _uploads]; } }
    public IReadOnlyList<string> Deleted { get { lock (_deleted) return [.. _deleted]; } }

    public void ClearRecorded()
    {
        lock (_uploads) _uploads.Clear();
        lock (_deleted) _deleted.Clear();
        lock (_landed) _landed.Clear();
        LastVideoUploadLinkValidity = null;
    }

    /// Reads the stream to the end exactly as the real SDK would, so the server's size cap
    /// (CappedReadStream) is exercised for real — a cap that only worked against Azure's client
    /// would pass here while proving nothing.
    public override async Task<string> UploadMediaAsync(Guid clubId, string extension, Stream content,
        string contentType, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        await content.CopyToAsync(buffer, ct);
        var url = $"https://{Host}/club-media/{clubId}/{Guid.NewGuid()}.{extension}";
        lock (_uploads) _uploads.Add(new StoredUpload(url, buffer.ToArray(), contentType));
        return url;
    }

    public override Task DeleteMediaAsync(string storedUrl)
    {
        lock (_deleted) _deleted.Add(storedUrl.Split('?')[0]);
        return Task.CompletedTask;
    }

    /// Mirrors production's contract: a stored (plain) URL comes back with a signature appended,
    /// null stays null. Tests assert the "?sig=" suffix to prove a fresh SAS was attached on
    /// broadcast rather than a stale one being reused.
    public override string? GenerateFreshReadUrl(string? storedUrl, UserDelegationKey key, DateTimeOffset keyExpiresOn)
        => storedUrl is null ? null : storedUrl.Split('?')[0] + "?sig=fake-read";

    private static IHostEnvironment TestEnvironment => new StubEnvironment();

    private sealed class StubEnvironment : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = Environments.Development;
        public string ApplicationName { get; set; } = "BookClubApi.Tests";
        public string ContentRootPath { get; set; } = AppContext.BaseDirectory;
        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
}
