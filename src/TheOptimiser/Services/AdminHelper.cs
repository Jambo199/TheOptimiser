using System.Diagnostics;
using System.Security.Principal;

namespace TheOptimiser.Services;

public static class AdminHelper
{
    public static bool IsAdmin()
    {
        try
        {
            using var id = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }

    // Relaunch ourselves elevated (UAC). Returns false if the user declines.
    public static bool RelaunchElevated()
    {
        try
        {
            var exe = Environment.ProcessPath!;
            Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true, Verb = "runas" });
            return true;
        }
        catch { return false; }
    }
}
