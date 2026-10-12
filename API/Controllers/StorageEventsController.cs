using System.Text.Json;
using BookClubApi.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace BookClubApi.Controllers;

// #204 design v2 — Azure Event Grid delivers storage's "a file landed" events here: BlobCreated on
// the media storage account, filtered by the subscription to club-media/*.mp4 (setup in
// docs/ARCHITECTURE.md). A reserved video's message is created from it, so a video send completes
// with the sender's app asleep.
//
// Anonymous because Event Grid can't sign in. Safe because an event can only complete a video its
// sender already reserved, and only once the file is verifiably in storage — a forged event can at
// most make that happen a moment early. Any failure answers 500, and Event Grid retries.
[ApiController]
[AllowAnonymous]
[Route("storage/events")]
public class StorageEventsController(MessageSendService messageSend, ILogger<StorageEventsController> logger) : ControllerBase
{
    private const string ValidationEvent = "Microsoft.EventGrid.SubscriptionValidationEvent";
    private const string BlobCreatedEvent = "Microsoft.Storage.BlobCreated";
    private const int MaxEventsPerDelivery = 100;

    [HttpPost]
    public async Task<IActionResult> Receive([FromBody] JsonElement events)
    {
        if (events.ValueKind != JsonValueKind.Array) return BadRequest();

        foreach (var e in events.EnumerateArray().Take(MaxEventsPerDelivery))
        {
            if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty("data", out var data)
                || data.ValueKind != JsonValueKind.Object) continue;
            var type = e.TryGetProperty("eventType", out var t) && t.ValueKind == JsonValueKind.String ? t.GetString() : null;

            if (type == ValidationEvent)
            {
                // Event Grid's handshake when the subscription is created: echo the code back. Its
                // own camelCase, not the API's snake_case.
                var code = data.TryGetProperty("validationCode", out var c) && c.ValueKind == JsonValueKind.String
                    ? c.GetString() : null;
                return Content(JsonSerializer.Serialize(new { validationResponse = code }), "application/json");
            }
            if (type == BlobCreatedEvent && data.TryGetProperty("url", out var url)
                && url.ValueKind == JsonValueKind.String && url.GetString() is { } blobUrl)
            {
                if (await messageSend.CompleteReservedVideoAsync(blobUrl))
                    logger.LogInformation("Reserved video landed: {BlobUrl}", blobUrl);
            }
        }
        return Ok();
    }
}
