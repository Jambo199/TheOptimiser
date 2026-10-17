using System.Windows.Media;

namespace TheOptimiser.Models;

public sealed class InstalledProgram
{
    public string Name = "";
    public string Publisher = "";
    public string Version = "";
    public string Location = "";
    public string Uninstall = "";
    public string Quiet = "";
    public string DisplayIcon = "";
    public string Id = "";
    public ImageSource? Logo;   // the program's own icon, extracted at runtime
}

public sealed class Leftover
{
    public string Kind = "";    // registry | folder
    public string Path = "";
    public string Score = "";   // High | Medium | Low
    public string Detail = "";
    public bool Selected;       // High/Medium pre-ticked
}
