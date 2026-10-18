using System.IO;
using System.Text.Json;
using TheOptimiser.Models;

namespace TheOptimiser.Services;

public static class JournalStore
{
    private static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TheOptimiser", "journals");

    private static readonly JsonSerializerOptions Opts = new() { WriteIndented = true };

    private static string BackupsDir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TheOptimiser", "backups");
    private static readonly string RegExe = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "reg.exe");

    // Defence in depth: on revert only ever touch backup files we created, under our own backups dir.
    private static bool UnderBackups(string? p)
    {
        if (string.IsNullOrEmpty(p)) return false;
        try { return Path.GetFullPath(p).StartsWith(Path.GetFullPath(BackupsDir) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }

    public static void Save(Operation op)
    {
        if (op.Items.Count == 0) return;
        Directory.CreateDirectory(Dir);
        var f = Path.Combine(Dir, $"op_{DateTime.Now:yyyyMMdd_HHmmss}_{op.Op}.json");
        File.WriteAllText(f, JsonSerializer.Serialize(op, Opts));
    }

    public static List<(string Path, Operation Op)> List()
    {
        var res = new List<(string, Operation)>();
        if (!Directory.Exists(Dir)) return res;
        foreach (var f in Directory.GetFiles(Dir, "op_*.json").OrderByDescending(x => x))
        {
            try { var op = JsonSerializer.Deserialize<Operation>(File.ReadAllText(f)); if (op != null) res.Add((f, op)); }
            catch { }
        }
        return res;
    }

    public static int Revert(string path)
    {
        int n = 0;
        Operation? op = null;
        try { op = JsonSerializer.Deserialize<Operation>(File.ReadAllText(path)); } catch { }
        var items = op?.Items;   // a hand-crafted journal with "Items": null must not crash the UI
        if (items != null)
            for (int i = items.Count - 1; i >= 0; i--)
            {
                var it = items[i];
                try
                {
                    switch (it.Kind)
                    {
                        case "registry": RegistryService.Undo(it); n++; break;
                        case "file-move":
                            if (UnderBackups(it.Backup) && Directory.Exists(it.Backup) && it.Path != null)
                            {
                                var parent = System.IO.Path.GetDirectoryName(it.Path);
                                if (parent != null) Directory.CreateDirectory(parent);
                                Directory.Move(it.Backup!, it.Path); n++;
                            }
                            break;
                        case "regkey-export":
                            if (UnderBackups(it.Backup) && File.Exists(it.Backup))
                            {
                                var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(RegExe, $"import \"{it.Backup}\"") { CreateNoWindow = true, UseShellExecute = false });
                                p?.WaitForExit();
                                if (p?.ExitCode == 0) n++;   // don't claim success on a failed import
                            }
                            break;
                        // appx removals can't be auto-undone (reinstall from the Store)
                    }
                }
                catch { }
            }
        try { File.Delete(path); } catch { }
        return n;
    }
}
