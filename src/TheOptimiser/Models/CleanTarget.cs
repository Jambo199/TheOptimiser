namespace TheOptimiser.Models;

public sealed class CleanTarget
{
    public string Id = "";
    public string Cat = "";
    public string Name = "";
    public string Desc = "";
    public string Kind = "";      // files | recyclebin | regmru
    public bool Undoable;         // registry MRU clears are backed up; file deletes are not
    public bool Admin;
    public string[] Paths = [];   // files: env-expandable path patterns
    public string[] Reg = [];     // regmru: reg.exe-style keys (HKCU\...)
    public bool Selected;
    public long Bytes;            // filled by a scan
    public int Count;
}
