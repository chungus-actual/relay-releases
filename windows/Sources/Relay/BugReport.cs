using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace Relay;

// Deliberately separate from errors.log: exception messages can contain URLs,
// local paths, and page content. Only bounded, explicitly chosen events go here.
internal static class ReportEvents
{
    private static readonly Queue<string> events = new();
    internal static void Record(string provider, string action)
    {
        lock (events)
        {
            events.Enqueue($"{DateTime.UtcNow:O} {provider} {action}");
            while (events.Count > 200) events.Dequeue();
        }
    }
    internal static string Snapshot() { lock (events) return string.Join('\n', events); }
}

internal sealed class BugReport
{
    public int Schema { get; set; } = 1;
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Created { get; set; } = DateTime.UtcNow.ToString("O");
    public string Description { get; set; } = "";
    public Dictionary<string, string> Diagnostics { get; set; } = new();
    public string Events { get; set; } = "";
    public string? Screenshot { get; set; }
    internal static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    internal byte[] Encode()
    {
        if (string.IsNullOrWhiteSpace(Description) || Description.Length > 8000)
            throw new IOException("Enter a description (up to 8,000 characters).");
        return JsonSerializer.SerializeToUtf8Bytes(this, Json);
    }
    internal static Uri? Endpoint(string? address) =>
        Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.Scheme == "https" && uri.Host != "" && uri.UserInfo == "" && uri.Fragment == "" ? uri : null;
    internal static (Uri? Endpoint, string Destination) Configuration()
    {
        try
        {
            using var config = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "reporting.json")));
            string? address = config.RootElement.GetProperty("endpoint").GetString();
            return (Endpoint(address), config.RootElement.GetProperty("destination").GetString() ?? "Private Relay intake");
        }
        catch { return (null, "Private Relay intake"); }
    }
    internal static async Task Submit(byte[] payload, string id, Uri endpoint, string code)
    {
        // Do not forward a report or its intake code through a redirect.
        using var handler = new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(45) };
        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Add("X-Relay-Intake-Key", code);
        request.Content = new ByteArrayContent(payload);
        request.Content.Headers.ContentType = new("application/json");
        using var response = await client.SendAsync(request);
        if (!response.IsSuccessStatusCode) throw new IOException($"Intake returned {(int)response.StatusCode}. Your report is still available to save or retry.");
        using var receipt = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        if (receipt.RootElement.GetProperty("id").GetString() != id || !receipt.RootElement.GetProperty("stored").GetBoolean())
            throw new IOException("The intake did not confirm this report. Save or retry it.");
    }
}
