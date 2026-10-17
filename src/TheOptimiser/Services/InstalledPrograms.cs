using Microsoft.Win32;
using TheOptimiser.Models;

namespace TheOptimiser.Services;

public static class InstalledPrograms
{
    // Enumerate Win32 desktop programs from the three Uninstall roots (same roots Revo reads).
    public static List<InstalledProgram> Scan()
    {
        var list = new List<InstalledProgram>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        (RegistryKey root, string path)[] roots =
        {
            (Registry.LocalMachine, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
            (Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"),
            (Registry.CurrentUser, @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
        };

        foreach (var (root, path) in roots)
        {
            using var key = root.OpenSubKey(path);
            if (key == null) continue;
            foreach (var sub in key.GetSubKeyNames())
            {
                using var k = key.OpenSubKey(sub);
                if (k == null) continue;
                if (k.GetValue("DisplayName") is not string name || string.IsNullOrWhiteSpace(name)) continue;
                if (k.GetValue("SystemComponent") is int sc && sc == 1) continue;
                if (k.GetValue("ParentKeyName") != null || k.GetValue("ParentDisplayName") != null) continue;

                var ver = k.GetValue("DisplayVersion") as string ?? "";
                if (!seen.Add(name + "|" + ver)) continue;

                list.Add(new InstalledProgram
                {
                    Name = name,
                    Publisher = k.GetValue("Publisher") as string ?? "",
                    Version = ver,
                    Location = k.GetValue("InstallLocation") as string ?? "",
                    Uninstall = k.GetValue("UninstallString") as string ?? "",
                    Quiet = k.GetValue("QuietUninstallString") as string ?? "",
                    DisplayIcon = k.GetValue("DisplayIcon") as string ?? "",
                    Id = name
                });
            }
        }
        return list.OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    public static void LoadIcons(IEnumerable<InstalledProgram> programs)
    {
        foreach (var p in programs)
            try { p.Logo = IconExtractor.From(p.DisplayIcon, p.Location, p.Uninstall); } catch { }
    }

    // Run a program's uninstaller and wait for it to finish.
    public static void RunUninstaller(InstalledProgram p)
    {
        var cmd = !string.IsNullOrWhiteSpace(p.Quiet) ? p.Quiet : p.Uninstall;
        if (string.IsNullOrWhiteSpace(cmd)) return;

        string exe, args;
        var m = System.Text.RegularExpressions.Regex.Match(cmd, "^\\s*\"([^\"]+)\"\\s*(.*)$");
        if (m.Success) { exe = m.Groups[1].Value; args = m.Groups[2].Value; }
        else
        {
            var m2 = System.Text.RegularExpressions.Regex.Match(cmd, @"^\s*(\S+\.exe)\s*(.*)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            if (m2.Success) { exe = m2.Groups[1].Value; args = m2.Groups[2].Value; }
            else { exe = "cmd.exe"; args = "/c " + cmd; }
        }
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo(exe, args) { UseShellExecute = true };
            var proc = System.Diagnostics.Process.Start(psi);
            proc?.WaitForExit();
        }
        catch { }
    }
}
