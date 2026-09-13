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
