using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using BookClubApi.Tests.Infrastructure;

namespace BookClubApi.Tests.Api;

/// #175–#177: the auto-filed issue couldn't say which screen froze. #283: it also listed the frames
/// backwards — MetricKit's tree is INNERMOST first (the root frame is the top of the stack, each
/// subFrame its caller) and the server reversed it, so the 40-frame cut dropped the innermost end.
/// These pin the issue body the server builds — the only place a developer ever sees the diagnostic.
public class DiagnosticsTests(TestAppFixture fixture) : IntegrationTestBase(fixture)
{
    /// No open issues → a new one is filed; the created issue echoes back as #1.
    private void GitHubWithNoOpenIssues() =>
        App.GitHub.Responder = (req, _) => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(req.Method == HttpMethod.Get
                ? "[]"
                : """{"number": 1, "title": "t", "html_url": "https://example/1"}""")
        };

    /// MetricKit's shape: the root frame is the innermost (Top), its subFrames are callers
    /// (Caller → Start), with a lighter sibling caller that must be skipped.
    private static string Payload() => JsonSerializer.Serialize(new
    {
        callStackTree = new
        {
            callStacks = new object[]
            {
                new { threadAttributed = false, callStackRootFrames = new[] { new { binaryName = "OtherThread", offsetIntoBinaryTextSegment = 1, sampleCount = 1 } } },
                new
                {
                    threadAttributed = true,
                    callStackRootFrames = new[]
                    {
                        new
                        {
                            binaryName = "Top", offsetIntoBinaryTextSegment = 10, sampleCount = 5,
                            subFrames = new object[]
                            {
                                new { binaryName = "LightBranch", offsetIntoBinaryTextSegment = 20, sampleCount = 1 },
                                new
                                {
                                    binaryName = "Caller", offsetIntoBinaryTextSegment = 30, sampleCount = 4,
                                    subFrames = new[] { new { binaryName = "Start", offsetIntoBinaryTextSegment = 40, sampleCount = 4 } }
                                }
                            }
                        }
                    }
                }
            }
        }
    });

    private static object Report(string? payload, string? breadcrumbs, string signature = "abc123") => new
    {
        kind = "crash", signature, summary = "watchdog",
        app_version = "1.9.6", build = "1", os_version = "iPhone OS 27.0", device_model = "iPhone18,2",
        payload_json = payload, breadcrumbs
    };

    private string FiledIssueBody()
    {
        var create = App.GitHub.Requests.Single(r => r.Request.Method == HttpMethod.Post && r.Request.RequestUri!.AbsolutePath.EndsWith("/issues"));
        return JsonDocument.Parse(create.Body).RootElement.GetProperty("body").GetString()!;
    }

    [Fact]
    public async Task Issue_leads_with_the_attributed_threads_innermost_frames_and_the_screen_trail()
    {
        GitHubWithNoOpenIssues();
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Mark", club.Id);

        var response = await user.Client.PostAsJsonAsync("/diagnostics",
            Report(Payload(), "+0s launch → +40s tab Admin → +55s background"), Json);
        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());

        var body = FiledIssueBody();
        Assert.Contains("Screen trail (crashed process):** `+0s launch → +40s tab Admin → +55s background`", body);
        Assert.Contains("0  Top +10\n1  Caller +30\n2  Start +40", body);   // innermost first, heaviest path
        Assert.DoesNotContain("LightBranch +20\n", body.Split("<details>")[0]);
        Assert.DoesNotContain("OtherThread", body.Split("<details>")[0]);
        Assert.True(body.IndexOf("Innermost frames", StringComparison.Ordinal) < body.IndexOf("<details>", StringComparison.Ordinal),
            "the frame summary must come before the (truncatable) payload dump");
    }

    /// #283 — a stack deeper than the 40 shown keeps its INNERMOST frames (where the app actually
    /// was) and drops the outer ones (run loop, main, start).
    [Fact]
    public async Task A_deep_stack_keeps_the_innermost_frames_and_drops_the_outer_ones()
    {
        GitHubWithNoOpenIssues();
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Mark", club.Id);
        // Built by hand: 45 nested frames is deeper than System.Text.Json's default limit of 64
        // levels — which the server's own parse used to hit too (#283).
        var frames = "";
        for (var i = 44; i >= 0; i--)   // F0 is the root frame (innermost); F44 the outermost caller
            frames = "{\"binaryName\":\"F" + i + "\",\"offsetIntoBinaryTextSegment\":" + i + ",\"sampleCount\":1"
                     + (frames == "" ? "" : ",\"subFrames\":[" + frames + "]") + "}";
        var payload = "{\"callStackTree\":{\"callStacks\":[{\"threadAttributed\":true,\"callStackRootFrames\":[" + frames + "]}]}}";

        var response = await user.Client.PostAsJsonAsync("/diagnostics", Report(payload, null), Json);

        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
        var summary = FiledIssueBody().Split("<details>")[0];
        Assert.Contains("0  F0 +0\n1  F1 +1", summary);
        Assert.Contains("39  F39 +39", summary);
        Assert.Contains("… 5 outer frames omitted", summary);
        Assert.DoesNotContain("F44 +44", summary);
    }

    [Fact]
    public async Task A_payload_that_does_not_parse_still_files_the_issue()
    {
        // Exactly what the old 25k truncation produced: JSON cut off mid-tree.
        GitHubWithNoOpenIssues();
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Mark", club.Id);

        var response = await user.Client.PostAsJsonAsync("/diagnostics", Report(Payload()[..60], null), Json);

        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
        var body = FiledIssueBody();
        Assert.DoesNotContain("Innermost frames", body);
        Assert.DoesNotContain("Screen trail", body);
    }

    [Fact]
    public async Task A_recurrence_comment_carries_the_new_screen_trail()
    {
        App.GitHub.Responder = (req, _) => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(req.Method == HttpMethod.Get
                ? """[{"number": 7, "title": "[crash] watchdog · sig:abc123", "html_url": "https://example/7"}]"""
                : "{}")
        };
        var club = await CreateClubAsync();
        var user = await CreateUserAsync("Mark", club.Id);

        var response = await user.Client.PostAsJsonAsync("/diagnostics", Report(Payload(), "+3s tab Profile → +9s background"), Json);

        Assert.True(response.IsSuccessStatusCode, await response.Content.ReadAsStringAsync());
        var comment = App.GitHub.Requests.Single(r => r.Request.RequestUri!.AbsolutePath.EndsWith("/issues/7/comments"));
        Assert.Contains("Screen trail: `+3s tab Profile → +9s background`", JsonDocument.Parse(comment.Body).RootElement.GetProperty("body").GetString());
    }
}
