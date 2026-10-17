namespace TheOptimiser.Services;

public static class About
{
    public const string Version = "3.0.0";

    // In-app changelog (newest first), shipped with the build.
    public static readonly (string Version, string Date, string[] Changes)[] Changelog =
    {
        ("3.0.0", "2026-10-17", new[]
        {
            "Rewritten from PowerShell to a native C#/.NET WPF app - faster section switching and a card-based UI.",
            "Tweaks grouped into logical cards with Recommended/Minimal presets and per-source filters.",
            "Real installed-app icons (your own, extracted at runtime) across Debloat, Install and Uninstall.",
        }),
        ("2.1.0", "2026-10-16", new[]
        {
            "In-app update banner and Changelog view.",
        }),
        ("2.0.0", "2026-10-16", new[]
        {
            "Clean - winapp2-style junk rules plus recent-item (MRU) trace clears; registry clears are backed up and undoable.",
            "Uninstall programs with a High/Med/Low leftover scan (informed by reverse-engineering Revo Uninstaller Pro).",
            "Per-operation transactional journals for undo.",
            "Signed updates - a pure minisign / Ed25519 verifier (RFC 8032).",
        }),
        ("1.0.0", "2026-10-15", new[]
        {
            "478 deduplicated registry tweaks from 18 reverse-engineered open-source tools.",
            "Debloat (Store apps), Install (winget), Services, Expert menu and undo.",
        }),
    };
}
