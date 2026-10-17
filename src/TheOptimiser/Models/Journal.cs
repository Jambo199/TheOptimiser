namespace TheOptimiser.Models;

// One reversible change recorded for undo.
public sealed class JournalItem
{
    public string Kind { get; set; } = "";      // registry | service | appx

    // registry
    public string? Hive { get; set; }
    public string? Path { get; set; }
    public string? Name { get; set; }
    public bool ExistedKey { get; set; }
    public bool Existed { get; set; }
    public string? PrevValue { get; set; }
    public string? PrevKind { get; set; }

    // service
    public string? ServiceName { get; set; }
    public string? PrevStartup { get; set; }

    // file-move (leftover folder moved to backup) / regkey-export (.reg backup) / regmru
    public string? Backup { get; set; }

    // appx (not auto-undoable)
    public string? AppxId { get; set; }
}

// One Apply = one operation = one journal file.
public sealed class Operation
{
    public string Op { get; set; } = Guid.NewGuid().ToString("N")[..12];
    public string Title { get; set; } = "";
    public string Started { get; set; } = DateTime.Now.ToString("o");
    public List<JournalItem> Items { get; set; } = new();
}
