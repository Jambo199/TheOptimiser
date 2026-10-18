using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace TheOptimiser.Services;

// Signed update check: downloads a manifest + its .minisig, verifies with minisign/Ed25519,
// compares versions. Never auto-downloads or runs an installer - it only reports.
public static class UpdateChecker
{
    public static string ConfigPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TheOptimiser", "update.json");

    public sealed class Result { public string Status = ""; public string Message = ""; public string Version = ""; public bool Newer; public string? DownloadUrl; }

    private sealed class Config { public string? url { get; set; } public string? pubkey { get; set; } }
    private sealed class Manifest { public string? version { get; set; } public string? url { get; set; } public string? notes { get; set; } }

    private static Config? ReadConfig()
    {
        try { if (File.Exists(ConfigPath)) return JsonSerializer.Deserialize<Config>(File.ReadAllText(ConfigPath)); } catch { }
        return null;
    }

    public static string? ConfiguredUrl() => ReadConfig()?.url;

    public static async Task<Result> CheckAsync()
    {
        var cfg = ReadConfig();
        if (string.IsNullOrEmpty(cfg?.url) || string.IsNullOrEmpty(cfg.pubkey))
            return new Result { Status = "unconfigured", Message = $"No signed-update source set. Drop an update.json ({{url, pubkey}}) at {ConfigPath} to enable." };
        try
        {
            if (!cfg.url.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                return new Result { Status = "error", Message = "Update URL must be https." };
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(20), MaxResponseContentBufferSize = 4 * 1024 * 1024 };
            var manBytes = await http.GetByteArrayAsync(cfg.url);
            var sig = await http.GetStringAsync(cfg.url + ".minisig");
            var sigLine = sig.Split('\n').FirstOrDefault(l => l.Trim().Length > 0
                && !l.StartsWith("untrusted comment:") && !l.StartsWith("trusted comment:")) ?? "";
            var v = Minisign.Verify(cfg.pubkey!, sigLine, manBytes);
            if (!v.ok) return new Result { Status = "bad-signature", Message = $"Update manifest signature INVALID ({v.why}). Ignored." };

            Manifest? info = null; try { info = JsonSerializer.Deserialize<Manifest>(Encoding.UTF8.GetString(manBytes)); } catch { }
            var ver = string.IsNullOrEmpty(info?.version) ? "(signed, see manifest)" : info!.version!;
            bool newer = IsNewer(ver, About.Version);
            var msg = newer
                ? $"Update available: v{ver} (you have v{About.Version}). Signature verified (key {v.keyid})."
                : $"You're on the latest version (v{About.Version}). Signature verified.";
            return new Result { Status = "verified", Version = ver, Newer = newer, Message = msg, DownloadUrl = info?.url };
        }
        catch (Exception ex) { return new Result { Status = "error", Message = "Update check failed: " + ex.Message }; }
    }

    public static bool IsNewer(string remote, string local)
    {
        if (string.IsNullOrEmpty(remote)) return false;
        if (Version.TryParse(remote, out var r) && Version.TryParse(local, out var l)) return r > l;
        return remote != local;
    }
}
