using System.IO;
using System.Net.Http;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using TheOptimiser.Models;

namespace TheOptimiser.Services;

// Icons for the Install list. These apps usually aren't installed yet, so there's no local icon to read -
// we fetch each app's favicon from Google's favicon service (the approach winutil uses), keyed by a domain
// guessed from the app name, cache the PNG under %LOCALAPPDATA%, and fall back to a letter chip on a miss.
// shortcut: the domain is guessed (name -> name.com, plus a small override map), so obscure apps may show a
// generic icon; upgrade by adding a homepage URL per app to the catalog.
public static class AppIcons
{
    private static readonly string CacheDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TheOptimiser", "icons");
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(8) };
    private static readonly SemaphoreSlim Gate = new(8);           // cap concurrent fetches
    private static readonly Dictionary<string, ImageSource?> Mem = new();

    // name/id -> the site whose favicon is actually the app's logo (covers the common mismatches)
    private static readonly Dictionary<string, string> Overrides = new(StringComparer.OrdinalIgnoreCase)
    {
        ["VLC media player"] = "videolan.org", ["7-Zip"] = "7-zip.org", ["Steam"] = "store.steampowered.com",
        ["Visual Studio Code"] = "code.visualstudio.com", ["Notepad++"] = "notepad-plus-plus.org",
        ["Git"] = "git-scm.com", ["OBS Studio"] = "obsproject.com", ["qBittorrent"] = "qbittorrent.org",
        ["PowerToys"] = "learn.microsoft.com", ["Microsoft PowerToys"] = "learn.microsoft.com",
        ["Audacity"] = "audacityteam.org", ["ShareX"] = "getsharex.com", ["Chromium"] = "chromium.org",
        ["Mozilla Firefox"] = "mozilla.org", ["GIMP"] = "gimp.org", ["Chrome"] = "google.com",
    };

    private static string Domain(InstallApp a)
    {
        if (Overrides.TryGetValue(a.Name, out var d)) return d;
        if (Overrides.TryGetValue(a.Id, out var d2)) return d2;
        var slug = new string(a.Name.Where(char.IsLetterOrDigit).ToArray()).ToLowerInvariant();
        return slug.Length > 0 ? slug + ".com" : "";
    }

    public static async Task<ImageSource?> GetAsync(InstallApp a)
    {
        if (Mem.TryGetValue(a.Id, out var cached)) return cached;

        ImageSource? img = null;
        try
        {
            Directory.CreateDirectory(CacheDir);
            var file = Path.Combine(CacheDir, Sanitize(a.Id) + ".png");
            byte[]? bytes = File.Exists(file) ? await File.ReadAllBytesAsync(file) : null;
            if (bytes == null)
            {
                var domain = Domain(a);
                if (domain.Length == 0) { Mem[a.Id] = null; return null; }
                await Gate.WaitAsync();
                try { bytes = await Http.GetByteArrayAsync($"https://www.google.com/s2/favicons?domain={Uri.EscapeDataString(domain)}&sz=64"); }
                finally { Gate.Release(); }
                if (bytes.Length > 0) await File.WriteAllBytesAsync(file, bytes);
            }
            img = Decode(bytes);
        }
        catch { img = null; }

        Mem[a.Id] = img;
        return img;
    }

    private static ImageSource? Decode(byte[] bytes)
    {
        try
        {
            var bi = new BitmapImage();
            bi.BeginInit();
            bi.StreamSource = new MemoryStream(bytes);
            bi.CacheOption = BitmapCacheOption.OnLoad;
            bi.EndInit();
            bi.Freeze();
            return bi;
        }
        catch { return null; }
    }

    private static string Sanitize(string s) => new(s.Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray());
}
