namespace TheOptimiser.Models;

// One user-facing tweak = one description, which may set several registry values.
// Collapses the 478 registry writes into ~252 real tweaks.
public sealed class TweakGroup
{
    public required string Description { get; init; }
    public required string Category { get; init; }
    public required string[] Sources { get; init; }
    public required List<Tweak> Items { get; init; }
    public bool FreshInstall { get; init; }   // sourced from a fresh-install playbook (Atlas / Revision)
    public bool Recommended { get; init; }     // catalog flags it as a default-on tweak
    public bool Selected { get; set; }

    public int KeyCount => Items.Count;

    public void SetSelected(bool value)
    {
        Selected = value;
        foreach (var t in Items) t.Selected = value;
    }

    public static List<TweakGroup> Build(IEnumerable<Tweak> tweaks)
    {
        var freshSources = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Atlas", "Revision", "ReviOS" };
        var groups = new List<TweakGroup>();
        foreach (var g in tweaks.GroupBy(t => t.Description))
        {
            var items = g.ToList();
            var sources = items.SelectMany(i => i.Sources).Distinct().OrderBy(s => s).ToArray();
            groups.Add(new TweakGroup
            {
                Description = g.Key,
                Category = items[0].Category,
                Sources = sources,
                Items = items,
                FreshInstall = sources.Any(freshSources.Contains),
                Recommended = items.Any(i => i.DefaultSelected),
                Selected = items.All(i => i.Selected)
            });
        }
        return groups;
    }
}
