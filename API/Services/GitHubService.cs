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

    // Create an issue with explicit labels (crash/hang auto-diagnostics use their own
    // label, not the feedback one). Used by #100.
    public async Task<GitHubIssue?> CreateLabeledIssueAsync(string title, string body, params string[] labels)
    {
        var client = httpClientFactory.CreateClient("github");
        var payload = JsonSerializer.Serialize(new { title, body, labels });
        var resp = await client.PostAsync($"repos/{Owner}/{Repo}/issues",
            new StringContent(payload, Encoding.UTF8, "application/json"));
        if (!resp.IsSuccessStatusCode) return null;
        var json = await resp.Content.ReadAsStringAsync();
        return JsonSerializer.Deserialize<GitHubIssue>(json, JsonOpts);
    }

    // Add a comment to an existing issue (used to record a recurrence of a deduped crash/hang).
    public async Task<bool> AddCommentAsync(int issueNumber, string body)
    {
        var client = httpClientFactory.CreateClient("github");
        var payload = JsonSerializer.Serialize(new { body });
        var resp = await client.PostAsync($"repos/{Owner}/{Repo}/issues/{issueNumber}/comments",
            new StringContent(payload, Encoding.UTF8, "application/json"));
        return resp.IsSuccessStatusCode;
    }

    // Open issues carrying a given label — used to dedup auto-filed diagnostics by their
    // call-stack signature (embedded in the title).
    public async Task<List<GitHubIssue>> ListOpenIssuesByLabelAsync(string label)
    {
        var client = httpClientFactory.CreateClient("github");
        var resp = await client.GetAsync(
            $"repos/{Owner}/{Repo}/issues?labels={Uri.EscapeDataString(label)}&state=open&per_page=100");
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
