using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using TheOptimiser.Models;

namespace TheOptimiser.Services;

// Leftover hunt after an uninstall, scored High/Med/Low - the roots and tiering are from a
// reverse-engineering pass over Revo Uninstaller Pro. Removals are backed up and undoable.
public static class Leftovers
{
    private static readonly HashSet<string> Stop = new(StringComparer.OrdinalIgnoreCase)
    { "the","inc","ltd","llc","corp","corporation","company","co","software","technologies","technology","group","app","application","windows","microsoft","program","version","x64","x86","64","32","bit" };

    private static readonly HashSet<string> Generic = new(StringComparer.OrdinalIgnoreCase)
    { "install","installer","uninstall","manager","update","updater","setup","launcher","service","services","runtime","framework","sdk","tools","toolkit","common","shared","studio","suite","client","server","helper","assistant","driver","drivers","package","packages","plugin","extension","advanced","micro","devices","corporation","systems","solutions","global","online","cloud","desktop" };

    public static string[] Tokens(string name, string publisher)
    {
        var raw = new List<string>();
        foreach (var s in new[] { name, publisher })
            if (!string.IsNullOrEmpty(s))
                raw.AddRange(Regex.Split(s, "[^A-Za-z0-9]+").Where(x => x.Length >= 3));
        return raw.Where(x => !Stop.Contains(x)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public static string? Score(string text, string[] tokens, string appName)
    {
        var t = text.ToLowerInvariant();
        if (!string.IsNullOrEmpty(appName) && t.Contains(appName.ToLowerInvariant())) return "High";
        var hit = tokens.Where(k => t.Contains(k.ToLowerInvariant())).ToList();
        if (hit.Count >= 2) return "High";
        if (hit.Count == 1) { var tok = hit[0]; return (tok.Length >= 5 && !Generic.Contains(tok)) ? "Medium" : "Low"; }
        return null;
    }

    public static List<Leftover> Find(InstalledProgram app)
    {
        var tokens = Tokens(app.Name, app.Publisher);
        var found = new List<Leftover>();
        void Add(string kind, string path, string? score, string detail)
        {
            if (score != null) found.Add(new Leftover { Kind = kind, Path = path, Score = score, Detail = detail, Selected = score == "High" });
        }

        (RegistryKey root, string path)[] regRoots =
        {
            (Registry.CurrentUser, "SOFTWARE"),
            (Registry.LocalMachine, "SOFTWARE"),
            (Registry.LocalMachine, @"SOFTWARE\WOW6432Node"),
            (Registry.CurrentUser, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
            (Registry.LocalMachine, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
            (Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"),
            (Registry.CurrentUser, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run"),
            (Registry.LocalMachine, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run"),
            (Registry.LocalMachine, @"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths"),
        };
        foreach (var (root, path) in regRoots)
        {
            using var key = root.OpenSubKey(path);
            if (key == null) continue;
            var prefix = (root == Registry.LocalMachine ? "HKLM" : "HKCU") + "\\" + path + "\\";
            try
            {
                foreach (var leaf in key.GetSubKeyNames())
                {
                    var score = Score(leaf, tokens, app.Name);
                    if (score != null) Add("registry", prefix + leaf, score, "key: " + leaf);
                }
            }
            catch { }
        }

        var fsRoots = new List<string?>
        {
            app.Location,
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), @"Microsoft\Windows\Start Menu\Programs"),
        };
        foreach (var root in fsRoots.Where(r => !string.IsNullOrWhiteSpace(r)).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!Directory.Exists(root)) continue;
            if (!string.IsNullOrEmpty(app.Location) && string.Equals(root, app.Location, StringComparison.OrdinalIgnoreCase))
            {
                Add("folder", root!, "High", "the program's own install folder");
                continue;
            }
            try
            {
                foreach (var d in Directory.GetDirectories(root!))
                {
                    var name = Path.GetFileName(d);
                    var score = Score(name, tokens, app.Name);
                    if (score != null) Add("folder", d, score, "folder: " + name);
                }
            }
            catch { }
        }

        var order = new Dictionary<string, int> { ["High"] = 0, ["Medium"] = 1, ["Low"] = 2 };
        var seen = new HashSet<string>();
        return found
            .OrderBy(f => order[f.Score]).ThenBy(f => f.Path, StringComparer.OrdinalIgnoreCase)
            .Where(f => seen.Add((f.Kind + "|" + f.Path).ToLowerInvariant()))
            .ToList();
    }

    // Remove selected leftovers, backing each up so the whole lot is undoable.
    public static Operation Remove(IEnumerable<Leftover> items, string appName)
    {
        var op = new Operation { Title = "Leftovers - " + appName };
        var backupDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TheOptimiser", "backups");
        Directory.CreateDirectory(backupDir);

        foreach (var it in items)
        {
            try
            {
                if (it.Kind == "registry")
                {
                    var bk = Path.Combine(backupDir, $"left_{DateTime.Now:yyyyMMddHHmmss}_{Guid.NewGuid().ToString("N")[..6]}.reg");
                    RunReg($"export \"{it.Path}\" \"{bk}\" /y");
                    if (File.Exists(bk)) op.Items.Add(new JournalItem { Kind = "regkey-export", Backup = bk });
                    RunReg($"delete \"{it.Path}\" /f");
                }
                else
                {
                    var dest = Path.Combine(backupDir, $"left_{DateTime.Now:yyyyMMddHHmmss}_{Guid.NewGuid().ToString("N")[..6]}_{Path.GetFileName(it.Path)}");
                    Directory.Move(it.Path, dest);
                    op.Items.Add(new JournalItem { Kind = "file-move", Path = it.Path, Backup = dest });
                }
            }
            catch { }
        }
        JournalStore.Save(op);
        return op;
    }

    private static void RunReg(string args)
    {
        try { var p = Process.Start(new ProcessStartInfo("reg", args) { CreateNoWindow = true, UseShellExecute = false }); p?.WaitForExit(); }
        catch { }
    }
}
