using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TheOptimiser.Services;

// Pulls a program's own icon (from its DisplayIcon or its exe) at runtime and hands back a
// frozen bitmap. Nothing is bundled or drawn - it's the icon already on the user's disk.
public static class IconExtractor
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, uint count);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);

    public static ImageSource? From(string displayIcon, string location, string uninstall)
    {
        foreach (var (path, index) in Candidates(displayIcon, location, uninstall))
        {
            if (string.IsNullOrEmpty(path)) continue;
            if (path.StartsWith(@"\\")) continue;   // never auth to a remote share during a scan (NTLM hash leak)
            if (!File.Exists(path)) continue;
            var img = Load(path, index);
            if (img != null) return img;
        }
        return null;
    }

    private static IEnumerable<(string path, int index)> Candidates(string displayIcon, string location, string uninstall)
    {
        if (!string.IsNullOrWhiteSpace(displayIcon))
            yield return ParseIcon(displayIcon);

        var exe = ExeFrom(uninstall);
        if (exe != null) yield return (exe, 0);

        if (!string.IsNullOrWhiteSpace(location) && !location.StartsWith(@"\\") && Directory.Exists(location))
        {
            string? pick = null;
            try { pick = Directory.EnumerateFiles(location, "*.exe").FirstOrDefault(f => !f.Contains("unins", StringComparison.OrdinalIgnoreCase)); } catch { }
            try { pick ??= Directory.EnumerateFiles(location, "*.exe").FirstOrDefault(); } catch { }
            if (pick != null) yield return (pick, 0);
        }
    }

    private static (string path, int index) ParseIcon(string s)
    {
        s = s.Trim().Trim('"');
        int comma = s.LastIndexOf(',');
        if (comma > 2 && int.TryParse(s[(comma + 1)..].Trim(), out var idx))
            return (s[..comma].Trim().Trim('"'), idx);
        return (s, 0);
    }

    private static string? ExeFrom(string u)
    {
        if (string.IsNullOrWhiteSpace(u)) return null;
        var m = Regex.Match(u, "\"([^\"]+\\.exe)\"", RegexOptions.IgnoreCase);
        if (m.Success) return m.Groups[1].Value;
        m = Regex.Match(u, @"([A-Za-z]:\\[^""]+?\.exe)", RegexOptions.IgnoreCase);
        return m.Success ? m.Groups[1].Value : null;
    }

    private static ImageSource? Load(string path, int index)
    {
        var large = new IntPtr[1];
        var small = new IntPtr[1];
        try
        {
            ExtractIconEx(path, index, large, small, 1);
            var h = large[0] != IntPtr.Zero ? large[0] : small[0];
            if (h == IntPtr.Zero) return null;
            var src = Imaging.CreateBitmapSourceFromHIcon(h, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            src.Freeze();
            return src;
        }
        catch { return null; }
        finally
        {
            if (large[0] != IntPtr.Zero) DestroyIcon(large[0]);
            if (small[0] != IntPtr.Zero) DestroyIcon(small[0]);
        }
    }
}
