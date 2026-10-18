using System.IO;
using System.Text;
using TheOptimiser.Services;

namespace TheOptimiser;

// --validate: dry-run over every catalog tweak (and service write) to confirm the hive, path and value
// all parse/coerce the way Apply would - without touching the registry. Catches malformed catalog data
// that would otherwise throw mid-apply. It does NOT judge whether a tweak is safe for Windows; that's a
// property of the catalog's content (assembled from established tools), not something code can check.
public static class CatalogValidate
{
    public static void Run()
    {
        var cat = CatalogService.Load();
        var log = new StringBuilder();
        int ok = 0, bad = 0;

        foreach (var t in cat.Registry)
        {
            var err = RegistryService.Validate(t.Hive, t.Path, t.Name, t.Type, t.Value);
            if (err == null) ok++;
            else { bad++; log.AppendLine($"[BAD] {t.Hive}\\{t.Path}\\{t.Name} ({t.Type}={t.Value}): {err}  -- \"{t.Description}\""); }
        }
        foreach (var s in cat.Services)
        {
            var w = ApplyService.ServiceWrite(s);
            var err = RegistryService.Validate(w.hive, w.path, w.name, w.type, w.value);
            if (err == null) ok++;
            else { bad++; log.AppendLine($"[BAD svc] {s.Name}: {err}"); }
        }

        var head = $"Validated {ok + bad} writes ({cat.Registry.Length} tweaks + {cat.Services.Length} services): {ok} OK, {bad} bad.\n";
        Console.Write(head + log);
        try { File.WriteAllText(Path.Combine(Path.GetTempPath(), "opti-validate.txt"), head + log); } catch { }
        Environment.ExitCode = bad == 0 ? 0 : 1;
    }
}
