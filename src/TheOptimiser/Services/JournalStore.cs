using System.IO;
using System.Text.Json;
using TheOptimiser.Models;

namespace TheOptimiser.Services;

public static class JournalStore
{
    private static string Dir => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TheOptimiser", "journals");

    private static readonly JsonSerializerOptions Opts = new() { WriteIndented = true };

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
        if (op != null)
            for (int i = op.Items.Count - 1; i >= 0; i--)
            {
                var it = op.Items[i];
                try
                {
                    switch (it.Kind)
                    {
                        case "registry": RegistryService.Undo(it); n++; break;
                        case "file-move":
                            if (it.Backup != null && Directory.Exists(it.Backup) && it.Path != null)
                            {
                                var parent = System.IO.Path.GetDirectoryName(it.Path);
                                if (parent != null) Directory.CreateDirectory(parent);
                                Directory.Move(it.Backup, it.Path); n++;
                            }
                            break;
                        case "regkey-export":
                            if (it.Backup != null && File.Exists(it.Backup))
                            {
                                var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("reg", $"import \"{it.Backup}\"") { CreateNoWindow = true, UseShellExecute = false });
                                p?.WaitForExit(); n++;
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
