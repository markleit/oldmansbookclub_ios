using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using BookClubApi.Models;
using BookClubApi.Tests.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Tests.Api;

/// #204 design v2 — the send token (docs/SEND_REQUIREMENTS.md K1–K5): what a message handed to iOS
/// carries, so it can wait up to a week for the network without the app awake to refresh it.
public class SendTokenTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    private sealed record Session(string Access, string Refresh, string Send, Book Book);

    /// A real sign-in, through the endpoint, so the tokens are the ones a phone actually gets.
    private async Task<Session> SignInAsync()
    {
        var response = await App.CreateClient().PostAsync("/auth/apple", JsonBody(new
        {
            identity_token = "any-token-the-validator-is-faked",
            display_name = "Mark",
            club_name = "Club"
        }));
        var body = await ReadAsync<JsonElement>(response);
        await using var db = App.NewDbContext();
        var book = await CreateBookAsync((await db.Clubs.SingleAsync()).Id, "The Road");
        return new Session(body.GetProperty("access_token").GetString()!, body.GetProperty("refresh_token").GetString()!,
            body.GetProperty("send_token").GetString()!, book);
    }

    private HttpClient With(string token)
    {
        var client = App.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return client;
    }

    private Task<HttpResponseMessage> SendTextAsync(string token, Guid bookId) =>
        With(token).PostAsync($"/books/{bookId}/messages",
            JsonBody(new { type = "Text", body = "hello", client_id = Guid.NewGuid() }));

    [Fact]
    public async Task K1_signing_in_and_refreshing_each_hand_out_a_send_token_that_lasts_a_week()
    {
        var session = await SignInAsync();
        var refreshed = await ReadAsync<JsonElement>(
            await App.CreateClient().PostAsync("/auth/refresh", JsonBody(new { refresh_token = session.Refresh })));

        foreach (var token in new[] { session.Send, refreshed.GetProperty("send_token").GetString()! })
        {
            var jwt = new JwtSecurityTokenHandler().ReadJwtToken(token);
            Assert.Equal("send", jwt.Claims.Single(c => c.Type == "scope").Value);
            Assert.InRange((jwt.ValidTo - DateTime.UtcNow).TotalDays, 6.99, 7.0);
        }
        // The access token is untouched — no scope, still an hour — which is what keeps every
        // older client working exactly as before.
        var access = new JwtSecurityTokenHandler().ReadJwtToken(session.Access);
        Assert.DoesNotContain(access.Claims, c => c.Type == "scope");
        Assert.InRange((access.ValidTo - DateTime.UtcNow).TotalMinutes, 58, 60);
    }

    [Fact]
    public async Task K2_a_send_token_sends_every_kind_of_message()
    {
        var session = await SignInAsync();

        var text = await SendTextAsync(session.Send, session.Book.Id);

        var voice = new ByteArrayContent([1, 2, 3]);
        voice.Headers.ContentType = new MediaTypeHeaderValue("audio/mp4");
        var file = await With(session.Send).PostAsync(
            $"/books/{session.Book.Id}/messages?client_id={Guid.NewGuid()}&duration_seconds=3", voice);

        var video = await With(session.Send).PostAsync($"/books/{session.Book.Id}/messages/video",
            JsonBody(new { client_id = Guid.NewGuid() }));

        await ReadAsync<MessageDto>(text);
        await ReadAsync<MessageDto>(file);
        await ReadAsync<VideoReservation>(video);
    }

    [Fact]
    public async Task K3_a_send_token_does_nothing_but_send()
    {
        // A week-long token is only acceptable because it can't read a chat, change an account or
        // join the live connection — every one of those still needs the hour-long access token.
        var session = await SignInAsync();
        var send = With(session.Send);

        Assert.Equal(HttpStatusCode.Unauthorized, (await send.GetAsync("/users/me")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await send.GetAsync($"/books/{session.Book.Id}/messages")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized,
            (await send.PostAsync($"/media/upload-url?clubId={session.Book.ClubId}", null)).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized,
            (await App.CreateClient().PostAsync($"/hubs/chat/negotiate?negotiateVersion=1&access_token={session.Send}", null)).StatusCode);

        // The same requests with the access token go through — so the 401s above are the scope,
        // not something wrong with the requests.
        var access = With(session.Access);
        Assert.Equal(HttpStatusCode.OK, (await access.GetAsync("/users/me")).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await access.GetAsync($"/books/{session.Book.Id}/messages")).StatusCode);
        Assert.Equal(HttpStatusCode.OK,
            (await App.CreateClient().PostAsync($"/hubs/chat/negotiate?negotiateVersion=1&access_token={session.Access}", null)).StatusCode);
    }

    [Fact]
    public async Task K4_signing_out_ends_the_send_token_at_once()
    {
        var session = await SignInAsync();
        await ReadAsync<MessageDto>(await SendTextAsync(session.Send, session.Book.Id));

        await With(session.Access).PostAsync("/auth/logout", JsonBody(new { refresh_token = session.Refresh }));

        Assert.Equal(HttpStatusCode.Unauthorized, (await SendTextAsync(session.Send, session.Book.Id)).StatusCode);
    }

    // K5 (deleting the account ends the send token) waits on #244: account deletion itself fails.
}
