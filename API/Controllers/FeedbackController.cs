using BookClubApi.Data;
using BookClubApi.Models;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace BookClubApi.Controllers;

// In-app feedback → GitHub issues. Restricted to global admins and club admins.
[Authorize]
[ApiController]
[Route("[controller]")]
public class FeedbackController(AppDbContext db, GitHubService github) : ControllerBase
{
    [HttpGet]
    public async Task<ActionResult<List<FeedbackDto>>> List([FromQuery] string state = "open")
    {
        if (!await IsAdminOrClubAdminAsync()) return Forbid();
        var allowed = state is "open" or "closed" or "all" ? state : "open";
        var issues = await github.ListIssuesAsync(allowed);
        return issues
            .Select(i => new FeedbackDto(i.Number, i.Title, i.State, i.HtmlUrl, i.CreatedAt))
            .ToList();
    }

    [HttpPost]
    public async Task<ActionResult<FeedbackDto>> Create([FromBody] CreateFeedbackRequest req)
    {
        if (!await IsAdminOrClubAdminAsync()) return Forbid();

        var title = req.Title?.Trim() ?? "";
        var body = req.Body?.Trim() ?? "";
        if (title.Length == 0 || body.Length == 0)
            return BadRequest("Title and description are required.");
        if (title.Length > 256) title = title[..256];

        var submitter = await db.Users
            .Where(u => u.Id == CallerId())
            .Select(u => u.Nickname ?? u.DisplayName)
            .FirstOrDefaultAsync() ?? "Unknown";

        var footer = $"\n\n---\n_Submitted from the app by {submitter}"
            + (string.IsNullOrWhiteSpace(req.AppVersion) ? "" : $" · v{req.AppVersion}")
            + $" · {DateTime.UtcNow:yyyy-MM-dd HH:mm} UTC_";

        var issue = await github.CreateIssueAsync(title, body + footer);
        if (issue is null) return StatusCode(StatusCodes.Status502BadGateway, "Could not file the feedback on GitHub.");

        return new FeedbackDto(issue.Number, issue.Title, issue.State, issue.HtmlUrl, issue.CreatedAt);
    }

    private Guid CallerId() =>
        Guid.TryParse(User.FindFirst("sub")?.Value, out var id) ? id : Guid.Empty;

    private async Task<bool> IsAdminOrClubAdminAsync()
    {
        var id = CallerId();
        if (id == Guid.Empty) return false;
        if (await db.Users.Where(u => u.Id == id).Select(u => u.IsAdmin).FirstOrDefaultAsync()) return true;
        return await db.Memberships.AnyAsync(m => m.UserId == id && m.IsClubAdmin);
    }
}
