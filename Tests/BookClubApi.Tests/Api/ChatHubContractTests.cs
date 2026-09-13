using System.Reflection;
using BookClubApi.Hubs;
using Microsoft.AspNetCore.SignalR;

namespace BookClubApi.Tests.Api;

/// A frozen snapshot of ChatHub's wire surface.
///
/// SignalR dispatches by method NAME and EXACT ARGUMENT COUNT. Adding a parameter to an existing
/// hub method does not extend it — it replaces it, and every already-installed App Store build
/// invoking the old arity fails at runtime with no compile-time warning anywhere. That is why the
/// hub has SendTextMessage / SendTextWithClientId / SendTextReply rather than one method with
/// optional parameters.
///
/// This test is deliberately a snapshot rather than a rule: it does not know which changes are
/// safe. Its whole job is to make a change to the wire contract impossible to do by accident. If
/// it fails, the question to answer is "will a shipped client still work?" — and if the answer is
/// yes (a genuinely new method name), update the table.
public class ChatHubContractTests
{
    /// method name → parameter count. Optional parameters count as parameters here: a client may
    /// invoke SendVoiceMessage with 3 or 4 arguments, and SignalR binds the missing one as null.
    private static readonly Dictionary<string, int> Expected = new()
    {
        ["JoinBook"] = 1,
        ["Typing"] = 2,
        ["SendTextMessage"] = 2,
        ["SendTextWithClientId"] = 3,
        ["SendTextReply"] = 4,
        ["SendVoiceMessage"] = 4,
        ["SendVoiceReply"] = 5,
        ["SendPhotoMessage"] = 3,
        ["SendPhotoReply"] = 4,
        ["SendVideoMessage"] = 3,
        ["SendVideoReply"] = 4,
        ["EditTextMessage"] = 2,
        ["DeleteMessage"] = 1,
        ["ForwardMessage"] = 2,
    };

    private static Dictionary<string, int> ActualSurface() =>
        typeof(ChatHub)
            .GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.DeclaredOnly)
            // Overrides of Hub's own lifecycle hooks (OnConnectedAsync and friends) are not part
            // of the client-invokable surface — GetBaseDefinition still points at Hub for those.
            .Where(m => !m.IsSpecialName && m.GetBaseDefinition().DeclaringType == typeof(ChatHub))
            .ToDictionary(m => m.Name, m => m.GetParameters().Length);

    [Fact]
    public void No_hub_method_is_removed_or_renamed()
    {
        var actual = ActualSurface();
        var missing = Expected.Keys.Where(name => !actual.ContainsKey(name)).ToList();

        Assert.True(missing.Count == 0,
            $"Hub methods removed or renamed: {string.Join(", ", missing)}. " +
            "Every client build still in the wild invokes these by name — removing one breaks it silently.");
    }

    [Fact]
    public void No_hub_method_changes_its_argument_count()
    {
        var actual = ActualSurface();
        var changed = Expected
            .Where(e => actual.TryGetValue(e.Key, out var count) && count != e.Value)
            .Select(e => $"{e.Key}: was {e.Value}, now {actual[e.Key]}")
            .ToList();

        Assert.True(changed.Count == 0,
            $"Hub method arity changed: {string.Join("; ", changed)}. " +
            "SignalR matches on exact argument count, so this breaks shipped clients. " +
            "Add a NEW method name instead of extending an existing one.");
    }

    [Fact]
    public void A_new_hub_method_has_to_be_declared_here()
    {
        // Not about safety — a new method breaks nothing. It is about making sure whoever adds one
        // reads the note above before they reach for "just one more parameter" next time.
        var extra = ActualSurface().Keys.Where(name => !Expected.ContainsKey(name)).ToList();

        Assert.True(extra.Count == 0,
            $"New hub methods not listed in this test: {string.Join(", ", extra)}. " +
            "Add them to Expected once you have confirmed they are new names, not changed arities.");
    }
}
