using System.Net;
using System.Net.Http.Headers;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;

namespace BookClubApi.Tests.Api;

/// #204 — ten photos sent at once all arrive on the first try (docs/SEND_REQUIREMENTS.md, S5).
///
/// The phone sends a batch over one connection, so an upload can wait its turn with nothing
/// arriving for many seconds while the others go. Kestrel's default minimum upload speed cut such
/// uploads off in production (2.2 (2) device pass: 2 of 9). These tests run on the real web
/// server: the in-memory test server every other test uses doesn't apply that limit at all.
public class BatchUploadTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private static readonly byte[] JpegStart = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46];

    private static byte[] Photo(int size)
    {
        var bytes = new byte[size];
        JpegStart.CopyTo(bytes, 0);
        return bytes;
    }

    /// The API on Kestrel, on a free port, sharing the suite's database.
    private sealed class OnKestrel : IAsyncDisposable
    {
        public ApiFactory App { get; }
        public Uri Address { get; }

        public OnKestrel(SqlServerFixture sql)
        {
            App = new ApiFactory(sql);
            App.UseKestrel(0);
            App.StartServer();
            var addresses = App.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!;
            Address = new Uri(addresses.Addresses.First());
        }

        public HttpClient ClientFor(Guid userId) => new()
        {
            BaseAddress = Address,
            Timeout = TimeSpan.FromSeconds(60),
            DefaultRequestHeaders = { Authorization = new AuthenticationHeaderValue("Bearer", TokenFor(userId)) },
        };

        public ValueTask DisposeAsync() => App.DisposeAsync();
    }

    /// One upload among several on a shared connection: its first bytes go at once, then nothing
    /// until it's this upload's turn, then the rest.
    private sealed class QueuedPhoto(byte[] bytes, Func<Task> waitForTurn, Action? done = null) : HttpContent
    {
        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        {
            await stream.WriteAsync(bytes.AsMemory(0, JpegStart.Length));
            await stream.FlushAsync();
            await waitForTurn();
            try
            {
                // The rest in slices over ~0.8 s: this upload's share of the link.
                const int slices = 8;
                var slice = (bytes.Length - JpegStart.Length + slices - 1) / slices;
                for (var offset = JpegStart.Length; offset < bytes.Length; offset += slice)
                {
                    await stream.WriteAsync(bytes.AsMemory(offset, Math.Min(slice, bytes.Length - offset)));
                    await stream.FlushAsync();
                    await Task.Delay(100);
                }
            }
            finally
            {
                done?.Invoke();   // a cut-off upload still hands the link on, so the test fails fast
            }
        }

        protected override bool TryComputeLength(out long length)
        {
            length = bytes.Length;
            return true;
        }
    }

    private static Task<HttpResponseMessage> SendAsync(HttpClient client, Guid bookId, HttpContent content)
    {
        content.Headers.ContentType = new MediaTypeHeaderValue("image/jpeg");
        return client.PostAsync($"/books/{bookId}/messages?client_id={Guid.NewGuid()}", content);
    }

    [Fact]
    public async Task A_photo_that_waits_its_turn_for_eight_seconds_still_arrives()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var me = await CreateUserAsync("Mark", club.Id);
        await using var server = new OnKestrel(Fixture.Sql);
        using var client = server.ClientFor(me.Id);

        var response = await SendAsync(client, book.Id,
            new QueuedPhoto(Photo(200_000), () => Task.Delay(TimeSpan.FromSeconds(8))));

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Single(server.App.Blob.Uploads);
    }

    [Fact]
    public async Task Ten_photos_sent_at_once_over_one_slow_connection_all_arrive_the_first_time()
    {
        var club = await CreateClubAsync();
        var book = await CreateBookAsync(club.Id, "The Road");
        var me = await CreateUserAsync("Mark", club.Id);
        await using var server = new OnKestrel(Fixture.Sql);
        using var client = server.ClientFor(me.Id);

        // One link: the photos take turns, so the tenth waits ~7 s with nothing arriving.
        using var link = new SemaphoreSlim(1);
        var sends = Enumerable.Range(0, 10).Select(_ => SendAsync(client, book.Id,
            new QueuedPhoto(Photo(150_000), () => link.WaitAsync(), () => link.Release()))).ToList();
        var responses = await Task.WhenAll(sends);

        Assert.All(responses, r => Assert.Equal(HttpStatusCode.OK, r.StatusCode));
        Assert.Equal(10, server.App.Blob.Uploads.Count);
        await using var db = App.NewDbContext();
        Assert.Equal(10, await db.Messages.CountAsync(m => m.BookId == book.Id && m.Type == MessageType.Photo));
    }
}
