using System.Net;
using BookClubApi.Services;
using BookClubApi.Tests.Infrastructure;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Options;

namespace BookClubApi.Tests.Api;

/// The HTTP rate-limit partitions, through the real Program.cs pipeline with only the permit count
/// lowered. The shared test host runs with limits lifted (see ApiFactory), so this boots its own.
public class RateLimitTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    [Fact]
    public async Task Upload_links_are_limited_per_member_not_for_the_whole_club()
    {
        // #204 — the "media" limiter had no partition key, so it was ONE bucket for every caller:
        // a couple of members sending photo batches in the same minute refused everyone's upload
        // links. It also only works per user if authentication runs BEFORE the rate limiter —
        // otherwise no user is known yet, both callers fall back to the same address partition,
        // and the second member is refused here.
        await using var limited = App.WithWebHostBuilder(b => b.ConfigureTestServices(services =>
        {
            services.RemoveAll<IConfigureOptions<RateLimiterOptions>>();
            services.AddRateLimiter(options =>
            {
                options.RejectionStatusCode = 429;
                options.AddPolicy("auth", ctx => RateLimitPolicies.Auth(ctx, int.MaxValue));
                options.AddPolicy("media", ctx => RateLimitPolicies.Media(ctx, 2));
            });
        }));
        var club = await CreateClubAsync();
        var busy = await CreateUserAsync("Busy", club.Id);
        var quiet = await CreateUserAsync("Quiet", club.Id);

        async Task<HttpStatusCode> UploadLinkAsync(TestUser user)
        {
            using var client = limited.CreateClient();
            client.DefaultRequestHeaders.Authorization = user.Client.DefaultRequestHeaders.Authorization;
            return (await client.PostAsync($"/media/upload-url?clubId={club.Id}&ext=jpg", null)).StatusCode;
        }

        Assert.Equal(HttpStatusCode.OK, await UploadLinkAsync(busy));
        Assert.Equal(HttpStatusCode.OK, await UploadLinkAsync(busy));
        Assert.Equal(HttpStatusCode.TooManyRequests, await UploadLinkAsync(busy));

        Assert.Equal(HttpStatusCode.OK, await UploadLinkAsync(quiet));
    }
}
