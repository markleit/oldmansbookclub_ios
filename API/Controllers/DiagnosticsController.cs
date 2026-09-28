using System.Text;
using System.Text.Json;
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
    // GitHub caps an issue body at 65,536 chars; leave room for the header + frame summary.
    private const int MaxPayloadChars = 50000;
    private const int MaxInnermostFrames = 40;
    private const int MaxBreadcrumbChars = 1500;

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
        // The crashed process's screen/lifecycle trail (client ≥ 1.9.6, iOS 17+). Single line,
        // no backticks, so it can't break the Markdown around it.
        var trail = (req.Breadcrumbs ?? "").Replace('`', '\'').Replace('\n', ' ').Replace('\r', ' ').Trim();
        if (trail.Length > MaxBreadcrumbChars) trail = "…" + trail[^MaxBreadcrumbChars..];
        var trailLine = trail.Length == 0 ? "" : $"- **Screen trail (crashed process):** `{trail}`\n";

        // Dedup: an open issue with the same signature already exists → add a recurrence comment.
        var existing = (await github.ListOpenIssuesByLabelAsync(label))
            .FirstOrDefault(i => i.Title.Contains(marker, StringComparison.OrdinalIgnoreCase));
        if (existing is not null)
        {
            await github.AddCommentAsync(existing.Number,
                $"🔁 Recurred: {meta} · {when}" + (trail.Length == 0 ? "" : $"\n\nScreen trail: `{trail}`"));
            return Ok(new { deduped = true, issue = existing.Number, url = existing.HtmlUrl });
        }

        var payload = (req.PayloadJson ?? "").Trim();
        var innermost = InnermostFrames(payload);
        if (payload.Length > MaxPayloadChars) payload = payload[..MaxPayloadChars] + "\n…(truncated)…";

        var body =
            $"**Auto-filed client {kind} diagnostic (MetricKit, #100).**\n\n"
            + $"- **First seen:** {when}\n"
            + $"- **App:** v{req.AppVersion ?? "?"} (build {req.Build ?? "?"})\n"
            + $"- **OS / device:** {req.OsVersion ?? "?"} · {req.DeviceModel ?? "?"}\n"
            + $"- **Signature:** `{sig}`\n"
            // The call stack tree is huge and serializes before terminationReason/exceptionType/
            // signal in MetricKit's own JSON, so those fields land past MaxPayloadChars and get
            // silently cut off. Surface the summary (computed from those same fields on-device)
            // here, ahead of the truncated dump, so it's never lost.
            + $"- **Summary:** {summary}\n"
            + trailLine + "\n"
            // #175–#177: the payload is a root-first tree, so truncation cut exactly the frames
            // that say what the thread was doing. Pull the attributed thread's innermost frames
            // out first, from the full (untruncated) payload.
            + (innermost is null
                ? ""
                : $"**Innermost frames (attributed thread, innermost first):**\n\n```\n{innermost}\n```\n\n")
            + (payload.Length == 0
                ? ""
                : $"<details><summary>MetricKit payload</summary>\n\n```json\n{payload}\n```\n\n</details>\n")
            + "\n_Reported automatically by the app; recurrences are deduped by call-stack signature into this issue._";

        var issue = await github.CreateLabeledIssueAsync(title, body, label);
        if (issue is null)
            return StatusCode(StatusCodes.Status502BadGateway, "Could not file the diagnostic on GitHub.");

        return Ok(new { deduped = false, issue = issue.Number, url = issue.HtmlUrl });
    }

    // MetricKit's callStackTree: callStacks[] (one per thread; `threadAttributed` marks the one
    // blamed), each a tree of callStackRootFrames → subFrames, OUTERMOST first. Walk the
    // attributed thread down its heaviest path (max sampleCount — hang reports hold several
    // samples) and return that path innermost-first. Null if the payload doesn't parse or has
    // no stack; never throws — a malformed payload must not stop the issue being filed.
    internal static string? InnermostFrames(string payloadJson)
    {
        if (string.IsNullOrWhiteSpace(payloadJson)) return null;
        try
        {
            using var doc = JsonDocument.Parse(payloadJson);
            if (!doc.RootElement.TryGetProperty("callStackTree", out var tree)
                || !tree.TryGetProperty("callStacks", out var stacks)
                || stacks.ValueKind != JsonValueKind.Array) return null;

            JsonElement? thread = null;
            foreach (var s in stacks.EnumerateArray())
            {
                thread ??= s;
                if (s.TryGetProperty("threadAttributed", out var a) && a.ValueKind == JsonValueKind.True)
                { thread = s; break; }
            }
            if (thread is null || !thread.Value.TryGetProperty("callStackRootFrames", out var level)) return null;

            var path = new List<string>();
            while (level.ValueKind == JsonValueKind.Array && level.GetArrayLength() > 0)
            {
                var frame = level.EnumerateArray()
                    .OrderByDescending(f => f.TryGetProperty("sampleCount", out var c) && c.TryGetInt32(out var n) ? n : 0)
                    .First();
                var name = frame.TryGetProperty("binaryName", out var b) ? b.GetString() : null;
                var offset = frame.TryGetProperty("offsetIntoBinaryTextSegment", out var o) ? o.ToString() : "?";
                path.Add($"{name ?? "???"} +{offset}");
                if (!frame.TryGetProperty("subFrames", out level)) break;
            }
            if (path.Count == 0) return null;

            path.Reverse();
            var sb = new StringBuilder();
            foreach (var (line, i) in path.Take(MaxInnermostFrames).Select((l, i) => (l, i)))
                sb.Append(i).Append("  ").AppendLine(line);
            if (path.Count > MaxInnermostFrames) sb.AppendLine($"… {path.Count - MaxInnermostFrames} outer frames omitted");
            return sb.ToString().TrimEnd();
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
