using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace BookClubApi.Services;

// Thin wrapper over the GitHub Issues REST API. The token lives in server config
// (GitHub:Token) and is attached to the named "github" HttpClient in Program.cs —
// it never reaches the app. Feedback submissions become labeled issues in the repo.
public class GitHubService(IConfiguration config, IHttpClientFactory httpClientFactory)
{
    private const string FeedbackLabel = "feedback";
    private string Owner => config["GitHub:Owner"] ?? "";
    private string Repo => config["GitHub:Repo"] ?? "";

    private static readonly JsonSerializerOptions JsonOpts = new() { PropertyNameCaseInsensitive = true };

    public async Task<GitHubIssue?> CreateIssueAsync(string title, string body)
    {
        var client = httpClientFactory.CreateClient("github");
        var payload = JsonSerializer.Serialize(new { title, body, labels = new[] { FeedbackLabel } });
        var resp = await client.PostAsync($"repos/{Owner}/{Repo}/issues",
            new StringContent(payload, Encoding.UTF8, "application/json"));
        if (!resp.IsSuccessStatusCode) return null;
        var json = await resp.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<GitHubIssue>(json, JsonOpts);
    }

    // state: "open" | "closed" | "all". Excludes pull requests (GitHub returns PRs in
    // the issues list too).
    public async Task<List<GitHubIssue>> ListIssuesAsync(string state)
    {
        var client = httpClientFactory.CreateClient("github");
        var resp = await client.GetAsync(
            $"repos/{Owner}/{Repo}/issues?labels={FeedbackLabel}&state={state}&per_page=100&sort=created&direction=desc");
        if (!resp.IsSuccessStatusCode) return [];
        var json = await resp.Content.ReadAsStringAsync();
        var issues = JsonSerializer.Deserialize<List<GitHubIssue>>(json, JsonOpts) ?? [];
        return issues.Where(i => i.PullRequest is null).ToList();
    }
}

public class GitHubIssue
{
    [JsonPropertyName("number")] public int Number { get; set; }
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("state")] public string State { get; set; } = "open";
    [JsonPropertyName("html_url")] public string HtmlUrl { get; set; } = "";
    [JsonPropertyName("created_at")] public DateTime CreatedAt { get; set; }
    [JsonPropertyName("pull_request")] public object? PullRequest { get; set; }
}
