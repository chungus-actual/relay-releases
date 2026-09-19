using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Relay;

internal sealed record ReleaseUpdate(Version Version, string FileName, Uri PackageUrl, Uri ChecksumsUrl, long Size);

internal sealed class ReleaseUpdates(HttpClient http)
{
    internal const string Repository = "chungus-actual/relay-releases";
    internal static readonly Uri LatestUrl = new("https://api.github.com/repos/" + Repository + "/releases/latest");
    private const long MaxPackageSize = 500L * 1024 * 1024;

    internal async Task<ReleaseUpdate?> CheckAsync(Version current, bool installed, CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, LatestUrl);
        request.Headers.UserAgent.ParseAdd("Relay/" + App.DisplayVersion);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
        response.EnsureSuccessStatusCode();
        using var json = JsonDocument.Parse(await ReadLimited(response.Content, 1024 * 1024, token));
        var release = json.RootElement;
        if (release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean()) return null;
        var tag = release.GetProperty("tag_name").GetString() ?? "";
        if (!Regex.IsMatch(tag, @"^v\d+\.\d+\.\d+$") || !Version.TryParse(tag[1..], out var version)) throw new InvalidDataException("Invalid release version.");
        if (version <= current) return null;
        var filename = installed ? $"Relay-{version}-Setup-x64.exe" : $"Relay-{version}-win-x64.zip";
        var assets = release.GetProperty("assets").EnumerateArray().ToArray();
        var package = assets.Single(a => a.GetProperty("name").GetString() == filename);
        var checksums = assets.Single(a => a.GetProperty("name").GetString() == "SHA256SUMS.txt");
        long size = package.GetProperty("size").GetInt64();
        if (size <= 0 || size > MaxPackageSize) throw new InvalidDataException("Invalid update size.");
        Uri AssetUrl(JsonElement asset, string name)
        {
            var url = new Uri(asset.GetProperty("browser_download_url").GetString()!);
            string path = "/" + Repository + "/releases/download/" + tag + "/" + name;
            if (url.Scheme != "https" || url.Host != "github.com" || url.AbsolutePath != path || url.Query.Length > 0 || url.Fragment.Length > 0 || !url.IsDefaultPort || url.UserInfo.Length > 0)
                throw new InvalidDataException("Unexpected update source.");
            return url;
        }
        return new(version, filename, AssetUrl(package, filename), AssetUrl(checksums, "SHA256SUMS.txt"), size);
    }

    internal async Task<string> DownloadAsync(ReleaseUpdate update, string directory, IProgress<int>? progress, CancellationToken token)
    {
        using var checksumResponse = await http.GetAsync(update.ChecksumsUrl, HttpCompletionOption.ResponseHeadersRead, token);
        checksumResponse.EnsureSuccessStatusCode();
        string manifest = System.Text.Encoding.UTF8.GetString(await ReadLimited(checksumResponse.Content, 64 * 1024, token));
        string hash = ExpectedHash(manifest, update.FileName);
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, update.FileName), partial = path + ".partial";
        try
        {
            using var response = await http.GetAsync(update.PackageUrl, HttpCompletionOption.ResponseHeadersRead, token);
            response.EnsureSuccessStatusCode();
            await using (var source = await response.Content.ReadAsStreamAsync(token))
            await using (var destination = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true))
            using (var digest = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                var buffer = new byte[81920]; long total = 0; int read;
                while ((read = await source.ReadAsync(buffer, token)) > 0)
                {
                    total += read;
                    if (total > update.Size || total > MaxPackageSize) throw new InvalidDataException("Update size mismatch.");
                    digest.AppendData(buffer, 0, read);
                    await destination.WriteAsync(buffer.AsMemory(0, read), token);
                    progress?.Report((int)(total * 100 / update.Size));
                }
                if (total != update.Size || !Convert.ToHexString(digest.GetHashAndReset()).Equals(hash, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Update checksum mismatch.");
            }
            File.Move(partial, path);
            return hash;
        }
        catch { if (File.Exists(partial)) File.Delete(partial); throw; }
    }

    internal static string ExpectedHash(string manifest, string filename)
    {
        var matches = manifest.Split('\n').Select(line => Regex.Match(line.Trim(), @"^([a-fA-F0-9]{64})\s+\*?(.+)$"))
            .Where(match => match.Success && match.Groups[2].Value == filename).ToArray();
        if (matches.Length != 1) throw new InvalidDataException("Missing or duplicate update checksum.");
        return matches[0].Groups[1].Value;
    }

    private static async Task<byte[]> ReadLimited(HttpContent content, int limit, CancellationToken token)
    {
        await using var stream = await content.ReadAsStreamAsync(token);
        using var bytes = new MemoryStream(); var buffer = new byte[8192]; int count;
        while ((count = await stream.ReadAsync(buffer, token)) > 0)
        {
            if (bytes.Length + count > limit) throw new InvalidDataException("Update response is too large.");
            bytes.Write(buffer, 0, count);
        }
        return bytes.ToArray();
    }
}
