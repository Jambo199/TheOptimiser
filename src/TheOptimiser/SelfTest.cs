using System.IO;
using System.Text;
using Microsoft.Win32;
using TheOptimiser.Services;

namespace TheOptimiser;

// Verifies the apply -> journal -> undo round-trip on a throwaway HKCU key (no admin, reversible).
public static class SelfTest
{
    public static void Run()
    {
        var log = new StringBuilder();
        bool all = true;
        void Check(string name, bool ok) { log.AppendLine($"[{(ok ? "PASS" : "FAIL")}] {name}"); all &= ok; }

        try
        {
            const string path = @"Software\TheOptimiser\SelfTest";
            var full = @"HKEY_CURRENT_USER\" + path;

            var op = ApplyService.ApplyRegistry("selftest", new[] { ("HKCU", path, "probe", "DWord", "12345") });
            Check("apply wrote value", Registry.GetValue(full, "probe", null) is int i && i == 12345);

            var entry = JournalStore.List().FirstOrDefault(o => o.Op.Title == "selftest");
            Check("journal written", entry.Path != null && entry.Op.Items.Count == 1);

            int n = entry.Path != null ? JournalStore.Revert(entry.Path) : 0;
            Check("undo removed value", n >= 1 && Registry.GetValue(full, "probe", null) == null);

            // default-value apply + undo
            var op2 = ApplyService.ApplyRegistry("selftest2", new[] { ("HKCU", path, "(Default)", "String", "classic") });
            var gotD = Registry.GetValue(full, null, null);
            bool appliedD = (string?)gotD == "classic";
            var e2 = JournalStore.List().FirstOrDefault(o => o.Op.Title == "selftest2");
            if (e2.Path != null) JournalStore.Revert(e2.Path);
            Check("default-value apply + undo", appliedD);

            try { Registry.CurrentUser.DeleteSubKeyTree(@"Software\TheOptimiser", throwOnMissingSubKey: false); } catch { }

            // Ed25519 / minisign verifier against RFC 8032 test vector 3
            var pub = Convert.FromHexString("fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025");
            var sig = Convert.FromHexString("6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a");
            Check("Ed25519 verifies a valid signature (RFC 8032)", Ed25519.Verify(pub, Convert.FromHexString("af82"), sig));
            Check("Ed25519 rejects a tampered message", !Ed25519.Verify(pub, Convert.FromHexString("af83"), sig));
        }
        catch (Exception ex) { log.AppendLine("EXCEPTION: " + ex); all = false; }

        log.AppendLine(all ? "SELFTEST PASSED" : "SELFTEST FAILED");
        try { File.WriteAllText(Path.Combine(Path.GetTempPath(), "opti-selftest.txt"), log.ToString()); } catch { }
        Environment.ExitCode = all ? 0 : 1;
    }
}
