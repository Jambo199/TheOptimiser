using Microsoft.Win32;
using TheOptimiser.Models;

namespace TheOptimiser.Services;

public static class RegistryService
{
    private static RegistryKey Root(string hive) => hive.ToUpperInvariant() switch
    {
        "HKLM" => Registry.LocalMachine,
        "HKCU" => Registry.CurrentUser,
        "HKCR" => Registry.ClassesRoot,
        "HKU" => Registry.Users,
        "HKCC" => Registry.CurrentConfig,
        _ => throw new ArgumentException("unknown hive: " + hive)
    };

    private static string ValName(string name) => (name is "(Default)" or "(default)" or "") ? "" : name;

    // Writes one value, capturing the prior state for undo. HKLM throws without admin -> caller rolls back.
    public static JournalItem Set(string hive, string path, string name, string type, string value)
    {
        var root = Root(hive);
        var vname = ValName(name);
        var item = new JournalItem { Kind = "registry", Hive = hive, Path = path, Name = name };

        using (var ro = root.OpenSubKey(path, writable: false))
        {
            if (ro != null)
            {
                item.ExistedKey = true;
                var cur = ro.GetValue(vname, null);
                if (cur != null)
                {
                    item.Existed = true;
                    item.PrevValue = ValToString(cur);
                    item.PrevKind = ro.GetValueKind(vname).ToString();
                }
            }
        }

        using var key = root.CreateSubKey(path, writable: true)!;
        key.SetValue(vname, Coerce(type, value), KindOf(type));
        return item;
    }

    public static void Undo(JournalItem b)
    {
        var root = Root(b.Hive!);
        var vname = ValName(b.Name!);
        using var key = root.OpenSubKey(b.Path!, writable: true);
        if (key == null) return;
        if (!b.Existed)
        {
            try { key.DeleteValue(vname, throwOnMissingValue: false); } catch { }
        }
        else
        {
            key.SetValue(vname, Coerce(b.PrevKind ?? "String", b.PrevValue ?? ""), KindOf(b.PrevKind ?? "String"));
        }
    }

    private static RegistryValueKind KindOf(string t) => t switch
    {
        "DWord" => RegistryValueKind.DWord,
        "QWord" => RegistryValueKind.QWord,
        "Binary" => RegistryValueKind.Binary,
        "ExpandString" => RegistryValueKind.ExpandString,
        "MultiString" => RegistryValueKind.MultiString,
        _ => RegistryValueKind.String
    };

    private static object Coerce(string t, string v) => t switch
    {
        "DWord" => unchecked((int)long.Parse(v)),
        "QWord" => long.Parse(v),
        "Binary" => ParseBytes(v),
        "MultiString" => v.Split('\n'),
        _ => v
    };

    private static byte[] ParseBytes(string v) =>
        v.Split(new[] { ',', ' ' }, StringSplitOptions.RemoveEmptyEntries).Select(x => Convert.ToByte(x, 16)).ToArray();

    private static string ValToString(object v) => v switch
    {
        byte[] b => string.Join(",", b.Select(x => x.ToString("X2"))),
        string[] m => string.Join("\n", m),
        _ => v.ToString() ?? ""
    };
}
