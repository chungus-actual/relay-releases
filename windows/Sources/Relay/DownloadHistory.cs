using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace Relay;

internal sealed class DownloadHistoryRecord
{
    public string Id { get; set; } = "";
    public string AccountId { get; set; } = "";
    public string AccountName { get; set; } = "";
    public string Path { get; set; } = "";
    public string Status { get; set; } = "Interrupted";
    public long Received { get; set; }
    public long Total { get; set; }
    public long Started { get; set; }
}

public partial class MainWindow
{
    private string? downloadHistoryError;
    private bool downloadHistoryWritable = true;
    private static string DownloadHistoryPath => Path.Combine(App.DataPath, "downloads.json");
    internal static List<DownloadHistoryRecord> ReadDownloadHistory(string path)
    {
        if (!File.Exists(path)) return [];
        if (new FileInfo(path).Length > 2_000_000) throw new InvalidDataException("Download history is too large.");
        var rows = JsonSerializer.Deserialize<List<DownloadHistoryRecord>>(File.ReadAllText(path)) ?? [];
        return rows.Where(r => r != null && !string.IsNullOrEmpty(r.Id) && !string.IsNullOrEmpty(r.AccountName) && Path.IsPathFullyQualified(r.Path))
            .DistinctBy(r => r.Id).OrderByDescending(r => r.Started).Take(200).ToList();
    }
    private void LoadDownloadHistory()
    {
        try
        {
            foreach (var row in ReadDownloadHistory(DownloadHistoryPath)) downloads.Add(new()
            {
                Id = row.Id, AccountId = row.AccountId, AccountName = row.AccountName, FilePath = row.Path,
                Complete = row.Status == "Complete", Status = row.Status is "Complete" or "Canceled" or "Failed" ? row.Status : "Interrupted",
                Received = Math.Max(0, row.Received), Total = Math.Max(0, row.Total), Started = row.Started
            });
        }
        catch (Exception ex) { downloadHistoryWritable = false; downloadHistoryError = "Couldn't read saved history. The original file has been preserved."; Log(ex); }
    }
    private void SaveDownloadHistory()
    {
        if (!downloadHistoryWritable) return;
        try
        {
            var records = downloads.Take(200).Select(d => new DownloadHistoryRecord { Id = d.Id, AccountId = d.AccountId, AccountName = d.AccountName,
                Path = d.FilePath, Status = d.Complete ? "Complete" : d.Status is "Canceled" or "Failed" ? d.Status : "Interrupted", Received = d.Received, Total = d.Total, Started = d.Started });
            File.WriteAllText(DownloadHistoryPath + ".tmp", JsonSerializer.Serialize(records)); File.Move(DownloadHistoryPath + ".tmp", DownloadHistoryPath, true);
            downloadHistoryError = null;
        }
        catch (Exception ex) { downloadHistoryError = "Couldn't save download history."; Log(ex); }
    }
}
