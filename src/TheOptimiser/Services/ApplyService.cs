using System.Diagnostics;
using System.Security.Principal;
using TheOptimiser.Models;
using Windows.Management.Deployment;

namespace TheOptimiser.Services;

public static class ApplyService
{
    // Transactional: writes all values; on any failure rolls them all back and rethrows (e.g. HKLM without admin).
    public static Operation ApplyRegistry(string title, IEnumerable<(string hive, string path, string name, string type, string value)> writes)
    {
        var op = new Operation { Title = title };
        try
        {
            foreach (var w in writes)
                op.Items.Add(RegistryService.Set(w.hive, w.path, w.name, w.type, w.value));
        }
        catch
        {
            for (int i = op.Items.Count - 1; i >= 0; i--) { try { RegistryService.Undo(op.Items[i]); } catch { } }
            throw;
        }
        JournalStore.Save(op);
        return op;
    }

    // A service startup change is just its Start registry value -> reversible through the same journal.
    public static (string hive, string path, string name, string type, string value) ServiceWrite(ServiceTweak s) =>
        ("HKLM", @"SYSTEM\CurrentControlSet\Services\" + s.Name, "Start", "DWord", StartupValue(s.Startup));

    private static string StartupValue(string s) => s.Replace(" ", "") switch
    {
        "Disabled" => "4",
        "Manual" or "DemandStart" => "3",
        "Automatic" or "Auto" or "AutomaticDelayed" or "AutomaticDelayedStart" => "2",
        "Boot" => "0",
        "System" => "1",
        _ => "3"
    };

    // Appx removal for the current user - best effort, not auto-undoable.
    public static async Task<int> RemoveAppxAsync(IEnumerable<string> ids)
    {
        int n = 0;
        try
        {
            var pm = new PackageManager();
            string sid = WindowsIdentity.GetCurrent().User?.Value ?? "";
            var byName = pm.FindPackagesForUser(sid)
                .GroupBy(p => p.Id.Name, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(g => g.Key, g => g.First().Id.FullName, StringComparer.OrdinalIgnoreCase);
            foreach (var id in ids)
                if (byName.TryGetValue(id, out var full))
                    try { await pm.RemovePackageAsync(full); n++; } catch { }
        }
        catch { }
        return n;
    }

    // winget installs - best effort, not undoable.
    public static int WingetInstall(IEnumerable<string> ids)
    {
        int n = 0;
        foreach (var id in ids)
            try
            {
                Process.Start(new ProcessStartInfo("winget", $"install --id {id} --accept-source-agreements --accept-package-agreements -e") { UseShellExecute = true });
                n++;
            }
            catch { }
        return n;
    }
}
