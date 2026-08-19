using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace BookClubApi.Controllers;

// #100 — receives MetricKit crash/hang/perf diagnostics from the device and auto-files a
// deduped GitHub issue via the existing PAT path (GitHubService). Any authenticated user can
// report (crashes come from anyone's device); MetricKit batches ~once/day so volume is low.
[Authorize]
[ApiController]
[Route("[controller]")]
public class DiagnosticsController(GitHubService github) : ControllerBase
{
    private const int MaxPayloadChars = 25000;

    [HttpPost]
    public async Task<IActionResult> Report([FromBody] DiagnosticReportRequest req)
    {
        var kind = (req.Kind ?? "").Trim().ToLowerInvariant();
        if (kind is not ("crash" or "hang" or "cpu" or "disk"))
            return BadRequest("Unknown diagnostic kind.");

        // Sanitize the signature to a short alphanumeric token (it goes into the issue title).
        var sig = new string((req.Signature ?? "").Where(char.IsLetterOrDigit).Take(16).ToArray());
        if (sig.Length == 0) return BadRequest("Missing signature.");

        // Crashes get the "crash" label; hang/cpu/disk share the "hang" label. Title prefix
        // preserves the exact kind, and `sig:<hash>` is the dedup marker.
        var label = kind == "crash" ? "crash" : "hang";
        var marker = $"sig:{sig}";

        var summary = (req.Summary ?? "").Trim();
        if (summary.Length == 0) summary = kind;
        if (summary.Length > 120) summary = summary[..120];
        var title = $"[{kind}] {summary} · {marker}";

        var meta = $"v{req.AppVersion ?? "?"} (build {req.Build ?? "?"}) · {req.OsVersion ?? "?"} · {req.DeviceModel ?? "?"}";
        var when = $"{DateTime.UtcNow:yyyy-MM-dd HH:mm} UTC";

        // Dedup: an open issue with the same signature already exists → add a recurrence comment.
        var existing = (await github.ListOpenIssuesByLabelAsync(label))
            .FirstOrDefault(i => i.Title.Contains(marker, StringComparison.OrdinalIgnoreCase));
        if (existing is not null)
        {
            await github.AddCommentAsync(existing.Number, $"🔁 Recurred: {meta} · {when}");
            return Ok(new { deduped = true, issue = existing.Number, url = existing.HtmlUrl });
        }

        var payload = (req.PayloadJson ?? "").Trim();
        if (payload.Length > MaxPayloadChars) payload = payload[..MaxPayloadChars] + "\n…(truncated)…";

        var body =
            $"**Auto-filed client {kind} diagnostic (MetricKit, #100).**\n\n"
            + $"- **First seen:** {when}\n"
            + $"- **App:** v{req.AppVersion ?? "?"} (build {req.Build ?? "?"})\n"
            + $"- **OS / device:** {req.OsVersion ?? "?"} · {req.DeviceModel ?? "?"}\n"
            + $"- **Signature:** `{sig}`\n\n"
            + (payload.Length == 0
                ? ""
                : $"<details><summary>MetricKit payload</summary>\n\n```json\n{payload}\n```\n\n</details>\n")
            + "\n_Reported automatically by the app; recurrences are deduped by call-stack signature into this issue._";

        var issue = await github.CreateLabeledIssueAsync(title, body, label);
        if (issue is null)
            return StatusCode(StatusCodes.Status502BadGateway, "Could not file the diagnostic on GitHub.");

        return Ok(new { deduped = false, issue = issue.Number, url = issue.HtmlUrl });
    }
}
