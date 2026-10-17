using System.IO;
using System.Windows.Media.Imaging;
using Windows.Management.Deployment;
using Windows.Storage.Streams;

namespace TheOptimiser.Services;

public sealed class AppInfo
{
    public bool Installed { get; set; }
    public BitmapImage? Logo { get; set; }
    public string? DisplayName { get; set; }
}

// Enumerates the current user's installed Store/Appx packages and extracts each app's own
// logo at runtime (never bundled/redistributed). Keyed by package Name (matches catalog debloat ids).
public static class InstalledApps
{
    public static async Task<Dictionary<string, AppInfo>> ScanAppxAsync()
    {
        var map = new Dictionary<string, AppInfo>(StringComparer.OrdinalIgnoreCase);
        try
        {
            var pm = new PackageManager();
            string sid = "";
            try { sid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ?? ""; } catch { }
            foreach (var pkg in pm.FindPackagesForUser(sid))
            {
                string name;
                try { name = pkg.Id.Name; } catch { continue; }
                if (string.IsNullOrEmpty(name) || map.ContainsKey(name)) continue;

                var info = new AppInfo { Installed = true };
                try { info.DisplayName = pkg.DisplayName; } catch { }
                try { info.Logo = await LoadLogoAsync(pkg); } catch { }
                map[name] = info;
            }
        }
        catch { /* enumeration unavailable -> empty map, UI falls back to letter chips */ }
        return map;
    }

    private static async Task<BitmapImage?> LoadLogoAsync(Windows.ApplicationModel.Package pkg)
    {
        var sr = pkg.GetLogoAsRandomAccessStreamReference(new Windows.Foundation.Size(48, 48));
        using var ras = await sr.OpenReadAsync();
        var size = (uint)ras.Size;
        if (size == 0) return null;
        var reader = new DataReader(ras);
        await reader.LoadAsync(size);
        var bytes = new byte[size];
        reader.ReadBytes(bytes);

        var bmp = new BitmapImage();
        using var ms = new MemoryStream(bytes);
        bmp.BeginInit();
        bmp.CacheOption = BitmapCacheOption.OnLoad;
        bmp.StreamSource = ms;
        bmp.EndInit();
        bmp.Freeze();
        return bmp;
    }
}
