using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using TheOptimiser.Models;

namespace TheOptimiser.Services;

public static class Cleaner
{
    private static string Env(string s) => Environment.ExpandEnvironmentVariables(s);

    public static List<CleanTarget> Targets() => new()
    {
        new() { Id = "temp-user", Cat = "Junk files", Name = "Temporary files (user)", Kind = "files", Desc = "Your per-user temp folder. Safe to empty; apps recreate what they need.", Paths = new[] { "%TEMP%" } },
        new() { Id = "temp-win", Cat = "Junk files", Name = "Temporary files (Windows)", Kind = "files", Admin = true, Desc = "The system temp folder. Needs admin.", Paths = new[] { @"%SystemRoot%\Temp" } },
        new() { Id = "prefetch", Cat = "Junk files", Name = "Prefetch", Kind = "files", Admin = true, Desc = "Boot/app prefetch traces. Windows rebuilds them.", Paths = new[] { @"%SystemRoot%\Prefetch\*.pf" } },
        new() { Id = "crashdumps", Cat = "Junk files", Name = "Crash dumps", Kind = "files", Desc = "Memory dumps left by crashes.", Paths = new[] { @"%LOCALAPPDATA%\CrashDumps", @"%SystemRoot%\Minidump" } },
        new() { Id = "thumbs", Cat = "Junk files", Name = "Thumbnail cache", Kind = "files", Desc = "Explorer thumbnail cache; rebuilt on demand.", Paths = new[] { @"%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db" } },
        new() { Id = "wu-cache", Cat = "Junk files", Name = "Windows Update cache", Kind = "files", Admin = true, Desc = "Downloaded update payloads. Needs admin.", Paths = new[] { @"%SystemRoot%\SoftwareDistribution\Download" } },
        new() { Id = "chrome-cache", Cat = "Browser cache", Name = "Chrome cache", Kind = "files", Desc = "Cached web files for Chrome.", Paths = new[] { @"%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache", @"%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache" } },
        new() { Id = "edge-cache", Cat = "Browser cache", Name = "Edge cache", Kind = "files", Desc = "Cached web files for Edge.", Paths = new[] { @"%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache", @"%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache" } },
        new() { Id = "firefox-cache", Cat = "Browser cache", Name = "Firefox cache", Kind = "files", Desc = "Cached web files for Firefox.", Paths = new[] { @"%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2" } },
        new() { Id = "recyclebin", Cat = "Junk files", Name = "Recycle Bin", Kind = "recyclebin", Desc = "Permanently empties the Recycle Bin." },
        new() { Id = "mru-run", Cat = "Recent-items traces", Name = "Run dialog history", Kind = "regmru", Undoable = true, Desc = "Commands you typed into Win+R.", Reg = new[] { @"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU" } },
        new() { Id = "mru-recentdocs", Cat = "Recent-items traces", Name = "Recent documents", Kind = "regmru", Undoable = true, Desc = "The list of files you opened recently.", Reg = new[] { @"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs" } },
        new() { Id = "mru-typedpaths", Cat = "Recent-items traces", Name = "Explorer typed paths", Kind = "regmru", Undoable = true, Desc = "Paths typed into the Explorer address bar.", Reg = new[] { @"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths" } },
        new() { Id = "mru-opensave", Cat = "Recent-items traces", Name = "Open/Save dialog history", Kind = "regmru", Undoable = true, Desc = "Recent folders in file Open/Save dialogs.", Reg = new[] { @"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\OpenSavePidlMRU", @"HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedPidlMRU" } },
        new() { Id = "mru-muicache", Cat = "Recent-items traces", Name = "Program run trace (MuiCache)", Kind = "regmru", Undoable = true, Desc = "A trace of programs you have launched.", Reg = new[] { @"HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache" } },
    };

    public static (long bytes, int count) Measure(CleanTarget t)
    {
        long bytes = 0; int count = 0;
        try
        {
            if (t.Kind == "files")
                foreach (var p in t.Paths) { var (b, c) = MeasurePattern(Env(p)); bytes += b; count += c; }
            else if (t.Kind == "regmru")
                foreach (var r in t.Reg) if (RegKeyExists(r)) count++;
        }
        catch { }
        return (bytes, count);
    }

    public static long Clean(CleanTarget t, Operation op)
    {
        long freed = 0;
        if (t.Kind == "files")
            foreach (var p in t.Paths) { var (b, _) = MeasurePattern(Env(p)); freed += b; DeletePattern(Env(p)); }
        else if (t.Kind == "recyclebin")
            EmptyRecycleBin();
        else if (t.Kind == "regmru")
        {
            var backupDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TheOptimiser", "backups");
            Directory.CreateDirectory(backupDir);
            int bi = 0;
            foreach (var r in t.Reg)
            {
                if (!RegKeyExists(r)) continue;
                var bk = Path.Combine(backupDir, $"mru_{t.Id}_{DateTime.Now:yyyyMMddHHmmss}_{bi++}_{Guid.NewGuid().ToString("N")[..6]}.reg".Replace(" ", "_"));
                if (RunReg($"export \"{r}\" \"{bk}\" /y") != 0 || !File.Exists(bk)) continue;   // no backup -> don't delete
                op.Items.Add(new JournalItem { Kind = "regkey-export", Backup = bk });
                RunReg($"delete \"{r}\" /f");
            }
        }
        return freed;
    }

    public static (long freed, Operation op) CleanSelected(IEnumerable<CleanTarget> targets)
    {
        var op = new Operation { Title = "Clean" };
        long freed = 0;
        foreach (var t in targets) { try { freed += Clean(t, op); } catch { } }
        JournalStore.Save(op);   // skips if nothing is undoable
        return (freed, op);
    }

    // ---- helpers ----
    private static IEnumerable<string> Expand(string pattern)
    {
        var root = Path.GetPathRoot(pattern) ?? "";
        var rest = pattern[root.Length..];
        var segs = rest.Split('\\', StringSplitOptions.RemoveEmptyEntries);
        IEnumerable<string> current = new[] { root };
        for (int i = 0; i < segs.Length; i++)
        {
            var seg = segs[i]; bool last = i == segs.Length - 1;
            var next = new List<string>();
            foreach (var dir in current)
            {
                try
                {
                    if (seg.Contains('*'))
                        next.AddRange(last ? Directory.GetFileSystemEntries(dir, seg) : Directory.GetDirectories(dir, seg));
                    else
                    {
                        var combined = Path.Combine(dir, seg);
                        if (last) { if (File.Exists(combined) || Directory.Exists(combined)) next.Add(combined); }
                        else if (Directory.Exists(combined)) next.Add(combined);
                    }
                }
                catch { }
            }
            current = next;
        }
        return current;
    }

    private static (long, int) MeasurePattern(string pattern)
    {
        long b = 0; int c = 0;
        foreach (var e in Expand(pattern))
        {
            if (Skip(e)) continue;
            if (Directory.Exists(e))
                foreach (var f in SafeFiles(e)) { try { b += new FileInfo(f).Length; c++; } catch { } }
            else if (File.Exists(e)) { try { b += new FileInfo(e).Length; c++; } catch { } }
        }
        return (b, c);
    }

    private static void DeletePattern(string pattern)
    {
        foreach (var e in Expand(pattern))
        {
            if (Skip(e)) continue;
            try
            {
                if (Directory.Exists(e))
                {
                    foreach (var f in Directory.GetFiles(e)) try { File.Delete(f); } catch { }
                    foreach (var d in Directory.GetDirectories(e)) try { Directory.Delete(d, true); } catch { }
                }
                else if (File.Exists(e)) File.Delete(e);
            }
            catch { }
        }
    }

    private static IEnumerable<string> SafeFiles(string dir)
    {
        try { return Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories); } catch { return Array.Empty<string>(); }
    }

    // Never follow a junction/symlink (a planted reparse point under a cache root would redirect deletes
    // to anywhere when elevated) and never operate on a bare drive root.
    private static bool Skip(string p)
    {
        if (p.Length <= 3) return true;   // "C:\"
        try { return (File.GetAttributes(p) & FileAttributes.ReparsePoint) != 0; } catch { return true; }
    }

    [DllImport("shell32.dll")] private static extern int SHEmptyRecycleBin(IntPtr hwnd, string? rootPath, uint flags);
    private static void EmptyRecycleBin() { try { SHEmptyRecycleBin(IntPtr.Zero, null, 0x1 | 0x2 | 0x4); } catch { } }

    private static (RegistryKey? root, string sub) SplitReg(string reg)
    {
        int i = reg.IndexOf('\\');
        var hive = i > 0 ? reg[..i] : reg;
        var sub = i > 0 ? reg[(i + 1)..] : "";
        RegistryKey? root = hive.ToUpperInvariant() switch { "HKCU" => Registry.CurrentUser, "HKLM" => Registry.LocalMachine, "HKCR" => Registry.ClassesRoot, _ => null };
        return (root, sub);
    }

    private static bool RegKeyExists(string reg)
    {
        var (root, sub) = SplitReg(reg);
        if (root == null) return false;
        try { using var k = root.OpenSubKey(sub); return k != null; } catch { return false; }
    }

    private static readonly string RegExe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "reg.exe");
    private static int RunReg(string args)
    {
        try { var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(RegExe, args) { CreateNoWindow = true, UseShellExecute = false }); p?.WaitForExit(); return p?.ExitCode ?? -1; } catch { return -1; }
    }
}
