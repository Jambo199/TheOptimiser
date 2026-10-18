using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using TheOptimiser.Models;
using TheOptimiser.Services;

namespace TheOptimiser;

public partial class MainWindow : Window
{
    private readonly Catalog _cat;
    private List<TweakGroup> _tweakGroups = new();
    private readonly List<AdvOption> _advUpdates = new();
    private string _section = "Tweaks";
    private string _category = "All";
    private string _source = "All";
    private bool _fresh;
    private Action? _pending;
    private Dictionary<string, AppInfo> _appx = new();
    private bool _appxScanned;
    private List<InstalledProgram> _programs = new();
    private bool _programsLoaded;
    private string _programsView = "list";   // "list" (compact) | "card"
    private readonly System.Windows.Threading.DispatcherTimer _searchTimer = new() { Interval = TimeSpan.FromMilliseconds(160) };
    private List<CleanTarget> _cleanTargets = new();
    private bool _cleanScanned;
    private InstalledProgram? _leftoverApp;
    private List<Leftover> _leftovers = new();
    private readonly Dictionary<string, SolidColorBrush> _colors = new();
    private static readonly string[] Palette =
        { "#FF1E3A34", "#FF24314A", "#FF3A2E48", "#FF2E3A2E", "#FF3A3528", "#FF2E2E3E", "#FF24323A", "#FF3A2E2E", "#FF34352E" };

    private sealed class AdvOption
    {
        public string Name = ""; public string Desc = ""; public bool Selected; public bool Danger;
        public List<(string hive, string path, string name, string type, string value)> Writes = new();
    }

    public MainWindow()
    {
        InitializeComponent();
        _cat = CatalogService.Load();
        _tweakGroups = TweakGroup.Build(_cat.Registry);
        BuildUpdateOptions();

        BuildTweakChips();
        ShowTweaks();

        BtnMin.Click += (_, _) => WindowState = WindowState.Minimized;
        BtnMax.Click += (_, _) => WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        BtnClose.Click += (_, _) => Close();
        // debounce search so the list isn't rebuilt on every keystroke
        _searchTimer.Tick += (_, _) => { _searchTimer.Stop(); Repopulate(); };
        SearchBox.TextChanged += (_, _) => { _searchTimer.Stop(); _searchTimer.Start(); };
        SmoothScroll.Fps = PrimaryRefreshHz();
        SmoothScroll.Enable(MainScroll);

        BtnRecommended.Click += (_, _) => ApplyPreset(g => g.Recommended);
        BtnMinimal.Click += (_, _) => ApplyPreset(g => g.Category == "Essential Tweaks");
        BtnClear.Click += (_, _) => ApplyPreset(_ => false);
        FreshToggle.Checked += (_, _) => { _fresh = true; PopulateTweaks(); };
        FreshToggle.Unchecked += (_, _) => { _fresh = false; PopulateTweaks(); };

        NavTweaks.Checked += (_, _) => ShowTweaks();
        NavDebloat.Checked += (_, _) => ShowDebloat();
        NavInstall.Checked += (_, _) => ShowInstall();
        NavServices.Checked += (_, _) => ShowServices();
        NavExpert.Checked += (_, _) => ShowExpert();
        NavUndo.Checked += (_, _) => ShowUndo();
        NavPrograms.Checked += (_, _) => ShowPrograms();
        NavClean.Checked += (_, _) => ShowClean();
        NavUpdates.Checked += (_, _) => ShowUpdates();

        BtnApply.Click += (_, _) => OnApply();
        BtnConfirmNo.Click += (_, _) => { ConfirmOverlay.Visibility = Visibility.Collapsed; _pending = null; };
        BtnConfirmYes.Click += (_, _) => { ConfirmOverlay.Visibility = Visibility.Collapsed; var p = _pending; _pending = null; p?.Invoke(); };

        bool admin = AdminHelper.IsAdmin();
        AdminText.Text = admin ? "administrator" : "standard user";
        AdminDot.Fill = admin ? Res("Accent2") : Res("Danger");
        BtnElevate.Visibility = admin ? Visibility.Collapsed : Visibility.Visible;
        BtnElevate.Click += (_, _) => { if (AdminHelper.RelaunchElevated()) Close(); };

        ScanAppxInBackground();
    }

    private SolidColorBrush Res(string key) => (SolidColorBrush)FindResource(key);

    private void SetApply(bool visible, string label = "Apply")
    {
        BtnApply.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        BtnApply.Content = label;
    }

    private void BuildUpdateOptions()
    {
        const string wu = @"SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate";
        var cv = @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion";
        var displayVer = Microsoft.Win32.Registry.GetValue(cv, "DisplayVersion", "")?.ToString() ?? "";
        var productName = Microsoft.Win32.Registry.GetValue(cv, "ProductName", "")?.ToString() ?? "";
        var prod = productName.Contains("Windows 10") ? "Windows 10" : "Windows 11";

        _advUpdates.Add(new AdvOption
        {
            Name = "Block feature updates",
            Desc = "Stay on your current Windows version - no big version upgrades (e.g. 23H2 -> 24H2). Monthly security patches still arrive.",
            Writes =
            {
                ("HKLM", wu, "TargetReleaseVersion", "DWord", "1"),
                ("HKLM", wu, "TargetReleaseVersionInfo", "String", string.IsNullOrEmpty(displayVer) ? "24H2" : displayVer),
                ("HKLM", wu, "ProductVersion", "String", prod),
            }
        });
        _advUpdates.Add(new AdvOption
        {
            Name = "Block driver updates",
            Desc = "Stop Windows Update from pushing drivers. You keep installing and updating drivers yourself.",
            Writes =
            {
                ("HKLM", wu, "ExcludeWUDriversInQualityUpdate", "DWord", "1"),
                ("HKLM", @"SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching", "SearchOrderConfig", "DWord", "0"),
                ("HKLM", @"SOFTWARE\Policies\Microsoft\Windows\DriverSearching", "DontSearchWindowsUpdate", "DWord", "1"),
                ("HKLM", @"SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata", "PreventDeviceMetadataFromNetwork", "DWord", "1"),
            }
        });
        _advUpdates.Add(new AdvOption
        {
            Name = "Block security & quality updates",
            Desc = "Also stops the monthly security patches. Not recommended - leaves your PC unpatched.",
            Danger = true,
            Writes =
            {
                ("HKLM", wu + @"\AU", "NoAutoUpdate", "DWord", "1"),
                ("HKLM", wu + @"\AU", "AUOptions", "DWord", "1"),
            }
        });
    }

    // ---- installed Appx scan ----
    private async void ScanAppxInBackground()
    {
        var map = await Task.Run(() => InstalledApps.ScanAppxAsync());
        _appx = map; _appxScanned = true;
        if (_section == "Debloat") ShowDebloat();
    }

    public void ScanAppxSync()
    {
        _appx = Task.Run(() => InstalledApps.ScanAppxAsync()).GetAwaiter().GetResult();
        _appxScanned = true;
    }

    // ---- installed programs (Win32) ----
    private async void LoadProgramsInBackground()
    {
        var progs = await Task.Run(() => { var l = InstalledPrograms.Scan(); InstalledPrograms.LoadIcons(l); return l; });
        _programs = progs; _programsLoaded = true;
        if (_section == "Programs") PopulatePrograms();
    }

    public void ScanProgramsSync()
    {
        _programs = Task.Run(() => { var l = InstalledPrograms.Scan(); InstalledPrograms.LoadIcons(l); return l; }).GetAwaiter().GetResult();
        _programsLoaded = true;
    }

    private void ShowPrograms()
    {
        _section = "Programs";
        SectionTitle.Text = "Uninstall programs";
        SectionSub.Text = _programsLoaded ? $"{_programs.Count} installed programs - uninstall, then clean its leftovers" : "reading installed programs...";
        FilterPanel.Visibility = Visibility.Collapsed;
        SetApply(false);
        if (!_programsLoaded) LoadProgramsInBackground();
        PopulatePrograms();
    }

    private void PopulatePrograms()
    {
        ListHost.Children.Clear();
        var q = (SearchBox.Text ?? "").Trim();
        var items = _programs.Where(p => q.Length == 0 || Match(p.Name, q) || Match(p.Publisher, q)).ToList();
        if (_programsLoaded) SectionSub.Text = $"{_programs.Count} installed programs - uninstall, then clean its leftovers";
        ListHost.Children.Add(BuildProgramsHeader(items.Count));
        bool compact = _programsView == "list";
        foreach (var p in items) { var prog = p; ListHost.Children.Add(BuildProgramRow(prog, compact)); }
        UpdateCount();
    }

    // Header row for Programs: "INSTALLED PROGRAMS n" on the left, a List/Card view switch on the right.
    private UIElement BuildProgramsHeader(int count)
    {
        var g = new Grid { Margin = new Thickness(3, 8, 10, 10) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.Children.Add(new TextBlock { Text = $"INSTALLED PROGRAMS    {count}", Foreground = Res("Accent2"), FontSize = 11.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        var views = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var label in new[] { "List", "Card" })
        {
            var m = label.ToLowerInvariant();
            var chip = new ToggleButton { Style = (Style)FindResource("Chip"), Content = label, IsChecked = _programsView == m, Margin = new Thickness(0, 0, 6, 0) };
            chip.Checked += (_, _) => { if (_programsView != m) { _programsView = m; PopulatePrograms(); } };
            chip.Unchecked += (s, _) => { if (_programsView == m) ((ToggleButton)s).IsChecked = true; };
            views.Children.Add(chip);
        }
        Grid.SetColumn(views, 1); g.Children.Add(views);
        return g;
    }

    private Border BuildProgramRow(InstalledProgram p, bool compact)
    {
        var meta = string.Join(compact ? "    " : "     ", new[] { p.Publisher, p.Version }.Where(x => !string.IsNullOrWhiteSpace(x)));
        var btn = new Button { Style = (Style)FindResource("Minor"), Content = "Uninstall", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0) };
        btn.Click += (_, _) => StartUninstall(p);

        if (compact)
        {
            var card = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(10, 4, 8, 4), Margin = new Thickness(0, 0, 10, 3), Background = Res("Card"), BorderThickness = new Thickness(1), BorderBrush = Res("Stroke") };
            var g = new Grid();
            foreach (var w in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto })
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = w });
            var ic = MakeProgramIcon(p, 22, 11);
            ic.Margin = new Thickness(0, 0, 10, 0);
            Grid.SetColumn(ic, 0); g.Children.Add(ic);
            var name = new TextBlock { Text = p.Name, Foreground = Res("Text"), FontSize = 12.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetColumn(name, 1); g.Children.Add(name);
            var mt = new TextBlock { Text = meta, Foreground = Res("Muted"), FontSize = 11, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 12, 0), TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 280 };
            Grid.SetColumn(mt, 2); g.Children.Add(mt);
            Grid.SetColumn(btn, 3); g.Children.Add(btn);
            card.Child = g;
            return card;
        }
        else
        {
            var card = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(14, 10, 12, 10), Margin = new Thickness(0, 0, 10, 8), Background = Res("Card"), BorderThickness = new Thickness(1.2), BorderBrush = Res("Stroke") };
            var g = new Grid();
            foreach (var w in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto })
                g.ColumnDefinitions.Add(new ColumnDefinition { Width = w });
            var ic = MakeProgramIcon(p, 34, 14);
            ic.Margin = new Thickness(0, 0, 13, 0);
            Grid.SetColumn(ic, 0); g.Children.Add(ic);
            var sp = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            sp.Children.Add(new TextBlock { Text = p.Name, Foreground = Res("Text"), FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
            sp.Children.Add(new TextBlock { Text = meta, Foreground = Res("Muted"), FontSize = 11, Margin = new Thickness(0, 2, 10, 0), TextTrimming = TextTrimming.CharacterEllipsis });
            Grid.SetColumn(sp, 1); g.Children.Add(sp);
            Grid.SetColumn(btn, 2); g.Children.Add(btn);
            card.Child = g;
            return card;
        }
    }

    private Border MakeProgramIcon(InstalledProgram p, double size, double fontSize)
    {
        var icon = new Border { Width = size, Height = size, CornerRadius = new CornerRadius(size / 4.25), VerticalAlignment = VerticalAlignment.Center };
        if (p.Logo != null) icon.Background = new ImageBrush(p.Logo) { Stretch = Stretch.Uniform };
        else { icon.Background = ColorFor(p.Name); icon.Child = new TextBlock { Text = Initial(p.Name), Foreground = Res("Text"), FontSize = fontSize, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }; }
        return icon;
    }

    private void StartUninstall(InstalledProgram p)
    {
        ShowConfirm($"Uninstall '{p.Name}'? I'll run its uninstaller, then scan for leftovers (nothing else is removed without your OK).",
            () => _ = DoUninstallAsync(p));
    }

    private async Task DoUninstallAsync(InstalledProgram p)
    {
        Status($"Uninstalling {p.Name}...");
        await Task.Run(() => InstalledPrograms.RunUninstaller(p));
        Status("Scanning for leftovers...");
        _leftoverApp = p;
        _leftovers = await Task.Run(() => Leftovers.Find(p));
        ShowLeftovers();
    }

    // ---- leftover review ----
    private void ShowLeftovers()
    {
        _section = "Leftovers";
        SectionTitle.Text = "Leftovers - " + (_leftoverApp?.Name ?? "");
        SectionSub.Text = "ticked items are removed and backed up (undoable); grey = low confidence, left unticked";
        FilterPanel.Visibility = Visibility.Collapsed;
        SetApply(true, "Remove selected");
        PopulateLeftovers();
    }

    private void PopulateLeftovers()
    {
        ListHost.Children.Clear();
        if (_leftovers.Count == 0)
        {
            ListHost.Children.Add(new TextBlock { Text = "No leftovers found - this program removed itself cleanly.", Foreground = Res("Muted"), FontSize = 13, Margin = new Thickness(6, 16, 0, 0) });
            UpdateCount(); return;
        }
        foreach (var tier in new[] { "High", "Medium", "Low" })
        {
            var rows = _leftovers.Where(l => l.Score == tier).ToList();
            if (rows.Count == 0) continue;
            var color = tier == "High" ? Res("Accent2") : tier == "Medium" ? Res("Accent") : Res("Muted");
            ListHost.Children.Add(new TextBlock { Text = $"{tier} confidence   {rows.Count}".ToUpper(), Foreground = color, FontSize = 11.5, FontWeight = FontWeights.SemiBold, Margin = new Thickness(3, 10, 0, 8) });
            foreach (var l in rows) { var lf = l; ListHost.Children.Add(BuildLeftoverRow(lf)); }
        }
        UpdateCount();
    }

    private Border BuildLeftoverRow(Leftover l)
    {
        var card = new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 7, 12, 7), Margin = new Thickness(0, 0, 10, 4), Background = Res("Card"), BorderThickness = new Thickness(1), BorderBrush = Res("Stroke") };
        var g = new Grid();
        foreach (var w in new[] { GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star) })
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = w });
        var cb = new CheckBox { Style = (Style)FindResource("Toggle"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0), IsChecked = l.Selected };
        cb.Checked += (_, _) => { l.Selected = true; UpdateCount(); };
        cb.Unchecked += (_, _) => { l.Selected = false; UpdateCount(); };
        Grid.SetColumn(cb, 0); g.Children.Add(cb);
        var kind = new TextBlock { Text = l.Kind, Foreground = Res("Muted"), FontSize = 10.5, VerticalAlignment = VerticalAlignment.Center, Width = 64 };
        Grid.SetColumn(kind, 1); g.Children.Add(kind);
        var path = new TextBlock { Text = l.Path, Foreground = Res("Text"), FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = l.Path };
        Grid.SetColumn(path, 2); g.Children.Add(path);
        card.Child = g;
        return card;
    }

    private void DoRemoveLeftovers()
    {
        var sel = _leftovers.Where(l => l.Selected).ToList();
        var op = Leftovers.Remove(sel, _leftoverApp?.Name ?? "program");
        Status($"Removed {op.Items.Count} leftover item(s) - backed up, undoable from Undo.");
        _programsLoaded = false; LoadProgramsInBackground();
        ShowPrograms();
    }

    public void SetSearch(string s) => SearchBox.Text = s;

    public void PreselectForPreview(int n = 2)
    {
        var q = (SearchBox.Text ?? "").Trim();
        if (_section == "Debloat")
            foreach (var a in _cat.Debloat.Where(a => q == "" || Match(a.Name, q) || Match(a.Id, q)).Take(n)) a.Selected = true;
        else if (_section == "Install")
            foreach (var a in _cat.Install.Where(a => q == "" || Match(a.Name, q) || Match(a.Id, q)).Take(n)) a.Selected = true;
        Repopulate();
    }

    public void SelectSection(string section)
    {
        if (section is "Debloat" or "Install") ScanAppxSync();
        if (section == "Programs") ScanProgramsSync();
        var nav = section switch
        {
            "Debloat" => NavDebloat, "Programs" => NavPrograms, "Install" => NavInstall,
            "Clean" => NavClean, "Services" => NavServices, "Undo" => NavUndo,
            "Updates" => NavUpdates, "Expert" => NavExpert, _ => NavTweaks
        };
        nav.IsChecked = true;
    }

    private void Repopulate()
    {
        switch (_section)
        {
            case "Tweaks": PopulateTweaks(); break;
            case "Debloat": PopulateDebloat(); break;
            case "Install": PopulateInstall(); break;
            case "Programs": PopulatePrograms(); break;
            case "Leftovers": PopulateLeftovers(); break;
            case "Clean": PopulateClean(); break;
            case "Expert": PopulateExpert(); break;
        }
    }

    // ---- sections ----
    private void ShowTweaks()
    {
        _section = "Tweaks";
        SectionTitle.Text = "Tweaks";
        SectionSub.Text = $"{_tweakGroups.Count} tweaks - toggle what you want, then apply";
        FilterPanel.Visibility = Visibility.Visible;
        SetApply(true);
        PopulateTweaks();
    }

    private void ShowDebloat()
    {
        _section = "Debloat";
        SectionTitle.Text = "Debloat";
        SectionSub.Text = _appxScanned ? "built-in Store apps installed on this PC - tap to select, then Apply" : "scanning installed apps...";
        FilterPanel.Visibility = Visibility.Collapsed;
        SetApply(true);
        PopulateDebloat();
    }

    private void ShowInstall()
    {
        _section = "Install";
        SectionTitle.Text = "Install apps";
        SectionSub.Text = "install software with winget";
        FilterPanel.Visibility = Visibility.Collapsed;
        SetApply(true);
        PopulateInstall();
    }

    private void ShowExpert()
    {
        _section = "Expert";
        SectionTitle.Text = "Expert / advanced";
        SectionSub.Text = "Windows Update control - pick any combination";
        FilterPanel.Visibility = Visibility.Collapsed;
        SetApply(true);
        PopulateExpert();
    }

    private void ShowPlaceholder(string name)
    {
        _section = name;
        SectionTitle.Text = name;
        SectionSub.Text = "being ported to the new C# build";
        FilterPanel.Visibility = Visibility.Collapsed;
        SetApply(false);
        ListHost.Children.Clear();
        ListHost.Children.Add(new TextBlock { Text = $"“{name}” is coming in a later build slice.", Foreground = Res("Muted"), FontSize = 13, Margin = new Thickness(6, 20, 0, 0) });
        UpdateCount();
    }

    // ---- presets ----
    private void ApplyPreset(Func<TweakGroup, bool> pick)
    {
        foreach (var g in _tweakGroups) g.SetSelected(pick(g));
        PopulateTweaks();
    }

    // ---- filter chips (Tweaks) ----
    private void BuildTweakChips()
    {
        var cats = new List<string> { "All" };
        cats.AddRange(_tweakGroups.Select(g => g.Category).Distinct().OrderBy(s => s));
        foreach (var c in cats)
            CategoryChips.Children.Add(MakeChip(CategoryChips, c, c == _category, v => { _category = v; PopulateTweaks(); }));

        var srcs = new List<string> { "All" };
        srcs.AddRange(_tweakGroups.SelectMany(g => g.Sources).Distinct().OrderBy(s => s));
        foreach (var s in srcs)
            SourceChips.Children.Add(MakeChip(SourceChips, s, s == _source, v => { _source = v; PopulateTweaks(); }));
    }

    private ToggleButton MakeChip(WrapPanel panel, string label, bool on, Action<string> onPick)
    {
        var tb = new ToggleButton { Style = (Style)FindResource("Chip"), Content = label, IsChecked = on, Tag = label };
        tb.Checked += (s, _) =>
        {
            var self = (ToggleButton)s;
            foreach (ToggleButton o in panel.Children) if (!ReferenceEquals(o, self)) o.IsChecked = false;
            onPick((string)self.Tag);
        };
        tb.Unchecked += (s, _) => { if (!panel.Children.OfType<ToggleButton>().Any(x => x.IsChecked == true)) ((ToggleButton)s).IsChecked = true; };
        return tb;
    }

    // ---- populate ----
    private void PopulateTweaks()
    {
        ListHost.Children.Clear();
        var q = (SearchBox.Text ?? "").Trim();
        IEnumerable<TweakGroup> groups = _tweakGroups;
        if (_category != "All") groups = groups.Where(g => g.Category == _category);
        if (_source != "All") groups = groups.Where(g => g.Sources.Contains(_source));
        if (_fresh) groups = groups.Where(g => g.FreshInstall);
        if (q.Length > 0) groups = groups.Where(g => Match(g.Description, q));

        foreach (var catGrp in groups.GroupBy(g => g.Category).OrderBy(x => x.Key))
        {
            AddHeader(catGrp.Key, catGrp.Count());
            var wrap = new WrapPanel();
            foreach (var grp in catGrp)
            {
                var g = grp;
                wrap.Children.Add(BuildCard(ShortTitle(g.Description), g.Description, null, Initial(g.Category), ColorFor(g.Category),
                    g.Selected, null, on => { g.SetSelected(on); UpdateCount(); }, asTile: false, freshInstall: g.FreshInstall));
            }
            ListHost.Children.Add(wrap);
        }
        UpdateCount();
    }

    private void PopulateDebloat()
    {
        ListHost.Children.Clear();
        if (!_appxScanned)
        {
            ListHost.Children.Add(new TextBlock { Text = "Scanning installed apps...", Foreground = Res("Muted"), FontSize = 13, Margin = new Thickness(6, 16, 0, 0) });
            UpdateCount(); return;
        }
        var q = (SearchBox.Text ?? "").Trim();
        IEnumerable<DebloatApp> items = _cat.Debloat.Where(a => _appx.TryGetValue(a.Id, out var info) && info.Installed);
        if (q.Length > 0) items = items.Where(a => Match(a.Name, q) || Match(a.Id, q));
        var list = items.ToList();
        if (list.Count == 0)
        {
            ListHost.Children.Add(new TextBlock { Text = q.Length > 0 ? "No installed built-in apps match your search." : "None of these built-in Store apps are installed on this PC.", Foreground = Res("Muted"), FontSize = 13, Margin = new Thickness(6, 16, 0, 0) });
            UpdateCount(); return;
        }
        var safetyLabel = new Dictionary<string, string> { ["safe"] = "Safe to remove", ["optional"] = "Optional", ["unsafe"] = "Caution - part of Windows" };
        foreach (var key in new[] { "safe", "optional", "unsafe" })
        {
            var grp = list.Where(a => a.Safety == key).ToList();
            if (grp.Count == 0) continue;
            AddHeader(safetyLabel[key], grp.Count);
            var wrap = new WrapPanel();
            foreach (var a in grp)
            {
                var app = a;
                _appx.TryGetValue(app.Id, out var info);
                wrap.Children.Add(BuildCard(app.Name, app.Description, info?.Logo, Initial(app.Name), ColorFor(app.Name),
                    app.Selected, null, on => { app.Selected = on; UpdateCount(); }, asTile: true));
            }
            ListHost.Children.Add(wrap);
        }
        UpdateCount();
    }

    private void PopulateInstall()
    {
        ListHost.Children.Clear();
        var q = (SearchBox.Text ?? "").Trim();
        IEnumerable<InstallApp> items = _cat.Install;
        if (q.Length > 0) items = items.Where(a => Match(a.Name, q) || Match(a.Id, q));
        foreach (var grp in items.GroupBy(a => a.Category).OrderBy(g => g.Key))
        {
            AddHeader(grp.Key, grp.Count());
            var wrap = new WrapPanel();
            foreach (var a in grp)
            {
                var app = a;
                wrap.Children.Add(BuildCard(app.Name, app.Description, null, Initial(app.Name), ColorFor(app.Category),
                    app.Selected, null, on => { app.Selected = on; UpdateCount(); }, asTile: true));
            }
            ListHost.Children.Add(wrap);
        }
        UpdateCount();
    }

    private void PopulateExpert()
    {
        ListHost.Children.Clear();
        AddHeader("Windows Update", _advUpdates.Count);
        foreach (var o in _advUpdates)
        {
            var opt = o;
            ListHost.Children.Add(BuildToggleRow(opt.Name, opt.Desc, opt.Selected, opt.Danger, on => { opt.Selected = on; UpdateCount(); }));
        }
        ListHost.Children.Add(new TextBlock
        {
            Text = "Group-policy changes. Pick any combination - these three compose every update scenario (e.g. “security only” = feature + driver). Your monthly security patches stay on unless you tick the last one.",
            Foreground = Res("Muted"), FontSize = 11.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 14, 20, 0), LineHeight = 18
        });
        UpdateCount();
    }

    // ---- card builders ----
    private static readonly SolidColorBrush SelBg = Hex("#FF112019");
    private static SolidColorBrush Hex(string h) { var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(h)); b.Freeze(); return b; }
    private static readonly Geometry CheckGeom = FreezeGeom(Geometry.Parse("M 0 5 L 4 9 L 11 1"));
    private static Geometry FreezeGeom(Geometry g) { g.Freeze(); return g; }

    private Border BuildCard(string title, string desc, ImageSource? logo, string letter, Brush letterBg,
                             bool selected, bool? installed, Action<bool> onToggle, bool asTile = false, bool freshInstall = false)
    {
        bool sel = selected;
        var card = new Border
        {
            Width = 210, MinHeight = 92, CornerRadius = new CornerRadius(10),
            Padding = new Thickness(13, 11, 13, 11), Margin = new Thickness(0, 0, 12, 12),
            Background = (sel && asTile) ? SelBg : Res("Card"), BorderThickness = new Thickness(1.2),
            BorderBrush = sel ? Res("Accent") : Res("Stroke"),
            Opacity = (!sel && installed == false) ? 0.6 : 1.0
        };
        var g = new Grid();
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var top = new Grid();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var icon = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(8) };
        if (logo != null) icon.Background = new ImageBrush(logo) { Stretch = Stretch.UniformToFill };
        else
        {
            icon.Background = letterBg;
            icon.Child = new TextBlock { Text = letter, Foreground = Res("Text"), FontSize = 12.5, FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        }
        top.Children.Add(icon);

        if (installed == true)
            top.Children.Add(new Ellipse { Width = 8, Height = 8, Fill = Res("Accent2"), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(23, -2, 0, 0), ToolTip = "Installed" });

        if (freshInstall)
        {
            var pill = new Border { CornerRadius = new CornerRadius(7), Background = Hex("#FF241E12"), BorderBrush = Res("Amber"), BorderThickness = new Thickness(1), Padding = new Thickness(7, 1, 7, 1), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
            pill.Child = new TextBlock { Text = "fresh install", Foreground = Res("Amber"), FontSize = 9.5, FontWeight = FontWeights.SemiBold };
            Grid.SetColumn(pill, 1);
            top.Children.Add(pill);
        }

        if (!asTile)
        {
            var cb = new CheckBox { Style = (Style)FindResource("Toggle"), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center, IsChecked = sel };
            cb.Checked += (_, _) => { card.BorderBrush = Res("Accent"); onToggle(true); };
            cb.Unchecked += (_, _) => { card.BorderBrush = Res("Stroke"); onToggle(false); };
            Grid.SetColumn(cb, 1);
            top.Children.Add(cb);
        }
        g.Children.Add(top);

        var sp = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 10, 0, 0) };
        Grid.SetRow(sp, 1);
        sp.Children.Add(new TextBlock { Text = title, Foreground = Res("Text"), FontSize = 12.5, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        sp.Children.Add(new TextBlock { Text = desc, Foreground = Res("Muted"), FontSize = 11, TextWrapping = TextWrapping.Wrap, MaxHeight = 30, TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 3, 0, 0) });
        g.Children.Add(sp);

        if (asTile)
        {
            var badgeScale = new ScaleTransform(sel ? 1 : 0.3, sel ? 1 : 0.3);
            var badge = new Border { Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = Res("Accent"), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Opacity = sel ? 1 : 0, RenderTransformOrigin = new Point(0.5, 0.5), RenderTransform = badgeScale };
            badge.Child = new Viewbox { Width = 11, Height = 11, Child = new System.Windows.Shapes.Path { Data = CheckGeom, Stroke = Brushes.White, StrokeThickness = 2, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round } };
            Grid.SetRowSpan(badge, 2);
            g.Children.Add(badge);

            void ApplySel()
            {
                card.Background = sel ? SelBg : Res("Card");
                card.BorderBrush = sel ? Res("Accent") : Res("Stroke");
                card.Opacity = (!sel && installed == false) ? 0.6 : 1.0;
                var dur = TimeSpan.FromMilliseconds(170);
                IEasingFunction ease = sel ? new BackEase { EasingMode = EasingMode.EaseOut, Amplitude = 0.5 } : new CubicEase { EasingMode = EasingMode.EaseIn };
                var op = new DoubleAnimation(sel ? 1 : 0, dur) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } };
                var sx = new DoubleAnimation(sel ? 1 : 0.3, dur) { EasingFunction = ease };
                var sy = new DoubleAnimation(sel ? 1 : 0.3, dur) { EasingFunction = ease };
                foreach (var a in new[] { op, sx, sy }) Timeline.SetDesiredFrameRate(a, SmoothScroll.Fps);
                badge.BeginAnimation(UIElement.OpacityProperty, op);
                badgeScale.BeginAnimation(ScaleTransform.ScaleXProperty, sx);
                badgeScale.BeginAnimation(ScaleTransform.ScaleYProperty, sy);
            }
            card.Cursor = Cursors.Hand;
            card.MouseEnter += (_, _) => { if (!sel) card.Background = Res("CardHover"); };
            card.MouseLeave += (_, _) => { if (!sel) card.Background = Res("Card"); };
            card.MouseLeftButtonUp += (_, _) => { sel = !sel; ApplySel(); onToggle(sel); };
        }

        card.Child = g;
        return card;
    }

    private Border BuildToggleRow(string title, string desc, bool selected, bool danger, Action<bool> onToggle)
    {
        var card = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(16, 13, 16, 13), Margin = new Thickness(0, 0, 10, 10), Background = Res("Card"), BorderThickness = new Thickness(1.2), BorderBrush = selected ? Res("Accent") : Res("Stroke") };
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var sp = new StackPanel();
        sp.Children.Add(new TextBlock { Text = title, Foreground = danger ? Res("Danger") : Res("Text"), FontSize = 13.5, FontWeight = FontWeights.SemiBold });
        sp.Children.Add(new TextBlock { Text = desc, Foreground = Res("Muted"), FontSize = 11.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 30, 0), LineHeight = 17 });
        g.Children.Add(sp);
        var cb = new CheckBox { Style = (Style)FindResource("Toggle"), VerticalAlignment = VerticalAlignment.Center, IsChecked = selected };
        cb.Checked += (_, _) => { card.BorderBrush = Res("Accent"); onToggle(true); };
        cb.Unchecked += (_, _) => { card.BorderBrush = Res("Stroke"); onToggle(false); };
        Grid.SetColumn(cb, 1);
        g.Children.Add(cb);
        card.Child = g;
        return card;
    }

    // ---- services screen ----
    private void ShowServices()
    {
        _section = "Services";
        SectionTitle.Text = "Services";
        SectionSub.Text = "change service startup types";
        FilterPanel.Visibility = Visibility.Collapsed;
        SetApply(true);
        PopulateServices();
    }

    private void PopulateServices()
    {
        ListHost.Children.Clear();
        AddHeader("Services", _cat.Services.Length);
        foreach (var s in _cat.Services)
        {
            var svc = s;
            ListHost.Children.Add(BuildToggleRow($"{svc.Name}   {svc.Original} → {svc.Startup}",
                ServiceInfo.Describe(svc.Name),
                svc.Selected, false, on => { svc.Selected = on; UpdateCount(); }));
        }
        UpdateCount();
    }

    // ---- clean screen ----
    private void ShowClean()
    {
        _section = "Clean";
        SectionTitle.Text = "Clean";
        SectionSub.Text = _cleanScanned ? "ticked items are removed; recent-items traces are backed up (undoable)" : "measuring...";
        FilterPanel.Visibility = Visibility.Collapsed;
        SetApply(true, "Clean selected");
        if (_cleanTargets.Count == 0) _cleanTargets = Cleaner.Targets();
        if (!_cleanScanned) ScanCleanInBackground();
        PopulateClean();
    }

    private async void ScanCleanInBackground()
    {
        var targets = _cleanTargets;
        await Task.Run(() => { foreach (var t in targets) { var (b, c) = Cleaner.Measure(t); t.Bytes = b; t.Count = c; } });
        _cleanScanned = true;
        if (_section == "Clean")
        {
            SectionSub.Text = "ticked items are removed; recent-items traces are backed up (undoable)";
            PopulateClean();
        }
    }

    private void PopulateClean()
    {
        ListHost.Children.Clear();
        foreach (var cat in _cleanTargets.Select(t => t.Cat).Distinct())
        {
            var rows = _cleanTargets.Where(t => t.Cat == cat).ToList();
            AddHeader(cat, rows.Count);
            foreach (var t in rows)
            {
                var ct = t;
                ListHost.Children.Add(BuildToggleRow(ct.Name, ct.Desc + CleanMeta(ct), ct.Selected, false,
                    on => { ct.Selected = on; UpdateCount(); }));
            }
        }
        UpdateCount();
    }

    private string CleanMeta(CleanTarget t)
    {
        if (!_cleanScanned) return "";
        if (t.Kind == "files") return t.Bytes > 0 ? $"   ·   {Mb(t.Bytes)}  ({t.Count} files)" : "   ·   nothing to clear";
        if (t.Kind == "regmru") return t.Count > 0 ? $"   ·   {t.Count} key(s) present" : "   ·   nothing stored";
        return "";   // recyclebin - not sized
    }

    private async void DoClean()
    {
        var sel = _cleanTargets.Where(t => t.Selected).ToList();
        Status("Cleaning...");
        var (freed, op) = await Task.Run(() => Cleaner.CleanSelected(sel));
        foreach (var t in sel) t.Selected = false;
        _cleanScanned = false;
        Status($"Freed {Mb(freed)}" + (op.Items.Count > 0 ? $" - {op.Items.Count} trace(s) backed up, undoable from Undo." : "."));
        ShowClean();   // re-measure
    }

    private static string Mb(long bytes) =>
        bytes >= 1L << 30 ? $"{bytes / (double)(1 << 30):0.0} GB" : $"{bytes / (double)(1 << 20):0.0} MB";

    // ---- undo screen ----
    private void ShowUndo()
    {
        _section = "Undo";
        SectionTitle.Text = "Undo";
        SectionSub.Text = "roll back a previous operation";
        FilterPanel.Visibility = Visibility.Collapsed;
        SetApply(false);
        PopulateUndo();
    }

    private void PopulateUndo()
    {
        ListHost.Children.Clear();
        var ops = JournalStore.List();
        if (ops.Count == 0)
            ListHost.Children.Add(new TextBlock { Text = "No operations to undo yet.", Foreground = Res("Muted"), FontSize = 13, Margin = new Thickness(6, 16, 0, 0) });
        foreach (var (path, op) in ops)
        {
            var p = path;
            var when = ""; try { when = DateTime.Parse(op.Started).ToString("yyyy-MM-dd HH:mm"); } catch { }
            ListHost.Children.Add(BuildUndoRow(op.Title, $"{op.Items.Count} change(s)     {when}",
                () => { int n = JournalStore.Revert(p); Status($"Reverted {n} change(s)."); PopulateUndo(); }));
        }
        UpdateCount();
    }

    private Border BuildUndoRow(string title, string meta, Action onRevert, string btnLabel = "Revert")
    {
        var card = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(16, 12, 14, 12), Margin = new Thickness(0, 0, 10, 10), Background = Res("Card"), BorderThickness = new Thickness(1.2), BorderBrush = Res("Stroke") };
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var sp = new StackPanel();
        sp.Children.Add(new TextBlock { Text = title, Foreground = Res("Text"), FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        sp.Children.Add(new TextBlock { Text = meta, Foreground = Res("Muted"), FontSize = 11, Margin = new Thickness(0, 3, 10, 0) });
        g.Children.Add(sp);
        var btn = new Button { Style = (Style)FindResource("Minor"), Content = btnLabel, VerticalAlignment = VerticalAlignment.Center };
        btn.Click += (_, _) => onRevert();
        Grid.SetColumn(btn, 1);
        g.Children.Add(btn);
        card.Child = g;
        return card;
    }

    // ---- updates screen ----
    private void ShowUpdates()
    {
        _section = "Updates";
        SectionTitle.Text = "Updates";
        SectionSub.Text = $"you're on v{About.Version} - signed update check and changelog";
        FilterPanel.Visibility = Visibility.Collapsed;
        SetApply(false);
        PopulateUpdates();
    }

    private void PopulateUpdates()
    {
        ListHost.Children.Clear();
        AddHeader("Signed updates", 1);
        var src = UpdateChecker.ConfiguredUrl() ?? "not configured";
        ListHost.Children.Add(BuildUndoRow(
            "Check for updates (minisign / Ed25519 verified)",
            $"Manifests are verified with a minisign Ed25519 signature before anything is trusted - the scheme eclean uses. Source: {src}",
            () => _ = DoUpdateCheck(), "Check now"));
        ListHost.Children.Add(new TextBlock
        {
            Text = $"To enable, drop an update.json ({{\"url\":\"...\",\"pubkey\":\"<minisign public key>\"}}) at {UpdateChecker.ConfigPath}. The manifest is signed with minisign (legacy Ed mode), its .minisig sits beside it, and verification is fully offline. A bad or missing signature is ignored and nothing is downloaded or run for you.",
            Foreground = Res("Muted"), FontSize = 11.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(3, 2, 20, 14), LineHeight = 17
        });

        AddHeader("Changelog", About.Changelog.Length);
        foreach (var (ver, date, changes) in About.Changelog)
            ListHost.Children.Add(BuildChangelogCard(ver, date, changes));
        UpdateCount();
    }

    private async Task DoUpdateCheck()
    {
        Status("Checking for updates...");
        var r = await UpdateChecker.CheckAsync();
        Status(r.Message);
    }

    private Border BuildChangelogCard(string ver, string date, string[] changes)
    {
        var card = new Border { CornerRadius = new CornerRadius(10), Padding = new Thickness(16, 12, 16, 12), Margin = new Thickness(0, 0, 10, 10), Background = Res("Card"), BorderThickness = new Thickness(1.2), BorderBrush = Res("Stroke") };
        var sp = new StackPanel();
        var head = new StackPanel { Orientation = Orientation.Horizontal };
        head.Children.Add(new TextBlock { Text = "v" + ver, Foreground = Res("Accent2"), FontSize = 14, FontWeight = FontWeights.SemiBold });
        head.Children.Add(new TextBlock { Text = date, Foreground = Res("Muted"), FontSize = 11.5, Margin = new Thickness(10, 3, 0, 0) });
        sp.Children.Add(head);
        foreach (var c in changes)
            sp.Children.Add(new TextBlock { Text = "•  " + c, Foreground = Res("Text"), FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 20, 0), LineHeight = 17 });
        card.Child = sp;
        return card;
    }

    // ---- apply / confirm ----
    private void Status(string s) => StatusText.Text = s;

    private void ShowConfirm(string msg, Action action)
    {
        ConfirmText.Text = msg;
        _pending = action;
        ConfirmOverlay.Visibility = Visibility.Visible;
    }

    private void OnApply()
    {
        switch (_section)
        {
            case "Tweaks":
                {
                    var groups = _tweakGroups.Where(g => g.Selected).ToList();
                    if (groups.Count == 0) { Status("Nothing selected."); return; }
                    var writes = groups.SelectMany(g => g.Items).Select(t => (t.Hive, t.Path, t.Name, t.Type, t.Value)).ToList();
                    ShowConfirm($"Apply {groups.Count} tweak(s)? This writes {writes.Count} registry value(s).",
                        () => DoRegistry($"Tweaks ({groups.Count})", writes));
                    break;
                }
            case "Expert":
                {
                    var opts = _advUpdates.Where(o => o.Selected).ToList();
                    if (opts.Count == 0) { Status("Nothing selected."); return; }
                    var writes = opts.SelectMany(o => o.Writes).ToList();
                    ShowConfirm($"Apply {opts.Count} Windows Update change(s)? These are Group Policy settings.",
                        () => DoRegistry($"Windows Update ({opts.Count})", writes));
                    break;
                }
            case "Services":
                {
                    var svcs = _cat.Services.Where(s => s.Selected).ToList();
                    if (svcs.Count == 0) { Status("Nothing selected."); return; }
                    var writes = svcs.Select(ApplyService.ServiceWrite).ToList();
                    ShowConfirm($"Change startup type on {svcs.Count} service(s)?",
                        () => DoRegistry($"Services ({svcs.Count})", writes));
                    break;
                }
            case "Debloat":
                {
                    var apps = _cat.Debloat.Where(a => a.Selected).ToList();
                    if (apps.Count == 0) { Status("Nothing selected."); return; }
                    ShowConfirm($"Remove {apps.Count} app(s)? This can't be auto-undone (reinstall from the Store).",
                        () => _ = DoRemoveAsync(apps));
                    break;
                }
            case "Install":
                {
                    var apps = _cat.Install.Where(a => a.Selected).ToList();
                    if (apps.Count == 0) { Status("Nothing selected."); return; }
                    ShowConfirm($"Install {apps.Count} app(s) via winget?", () =>
                    {
                        int n = ApplyService.WingetInstall(apps.Select(a => a.Id));
                        foreach (var a in apps) a.Selected = false;
                        Status($"Started {n} winget install(s).");
                        PopulateInstall();
                    });
                    break;
                }
            case "Leftovers":
                {
                    var sel = _leftovers.Where(l => l.Selected).ToList();
                    if (sel.Count == 0) { Status("Nothing ticked."); return; }
                    ShowConfirm($"Remove {sel.Count} leftover item(s)? They're backed up and can be undone.", DoRemoveLeftovers);
                    break;
                }
            case "Clean":
                {
                    var sel = _cleanTargets.Where(t => t.Selected).ToList();
                    if (sel.Count == 0) { Status("Nothing selected."); return; }
                    var size = sel.Where(t => t.Kind == "files").Sum(t => t.Bytes);
                    bool needsAdmin = sel.Any(t => t.Admin) && !AdminHelper.IsAdmin();
                    var msg = $"Clean {sel.Count} item(s)?"
                        + (size > 0 ? $" Frees about {Mb(size)}." : "")
                        + " Junk and cache files are deleted permanently; recent-items traces are backed up."
                        + (needsAdmin ? " Some items need admin and will be skipped." : "");
                    ShowConfirm(msg, DoClean);
                    break;
                }
        }
    }

    private void DoRegistry(string title, List<(string, string, string, string, string)> writes)
    {
        try
        {
            var op = ApplyService.ApplyRegistry(title, writes);
            ClearSelections();
            Repopulate();
            Status($"Applied {op.Items.Count} value(s) as one undoable operation.");
        }
        catch (UnauthorizedAccessException)
        {
            Status("Needs administrator - rolled back, nothing changed. Use 'Run as administrator'.");
        }
        catch (Exception ex)
        {
            Status("Failed - rolled back, nothing changed. " + ex.Message);
        }
    }

    private async Task DoRemoveAsync(List<DebloatApp> apps)
    {
        Status("Removing apps...");
        int n = await ApplyService.RemoveAppxAsync(apps.Select(a => a.Id));
        foreach (var a in apps) a.Selected = false;
        _appxScanned = false;
        ScanAppxInBackground();
        PopulateDebloat();
        Status($"Removed {n} app(s). (Reinstall from the Store to undo.)");
    }

    private void ClearSelections()
    {
        switch (_section)
        {
            case "Tweaks": foreach (var g in _tweakGroups.Where(g => g.Selected).ToList()) g.SetSelected(false); break;
            case "Expert": foreach (var o in _advUpdates) o.Selected = false; break;
            case "Services": foreach (var s in _cat.Services) s.Selected = false; break;
        }
    }

    // ---- helpers ----
    private void AddHeader(string text, int count) => ListHost.Children.Add(new TextBlock
    {
        Text = text.ToUpper() + "    " + count,
        Foreground = Res("Accent2"), FontSize = 11.5, FontWeight = FontWeights.SemiBold, Margin = new Thickness(3, 8, 0, 10)
    });

    private void UpdateCount()
    {
        int n = _section switch
        {
            "Debloat" => _cat.Debloat.Count(a => a.Selected),
            "Install" => _cat.Install.Count(a => a.Selected),
            "Services" => _cat.Services.Count(s => s.Selected),
            "Expert" => _advUpdates.Count(o => o.Selected),
            "Leftovers" => _leftovers.Count(l => l.Selected),
            "Clean" => _cleanTargets.Count(t => t.Selected),
            "Programs" => 0,
            "Undo" => 0,
            _ => _tweakGroups.Count(g => g.Selected)
        };
        SelCount.Text = n + " selected";
    }

    private static bool Match(string s, string q) => s.Contains(q, StringComparison.OrdinalIgnoreCase);
    private static string Initial(string s) => s.Length > 0 ? s[..1].ToUpper() : "#";

    private SolidColorBrush ColorFor(string key)
    {
        if (_colors.TryGetValue(key, out var b)) return b;
        int h = 0; foreach (char c in key) h = h * 31 + c;
        var col = (Color)ColorConverter.ConvertFromString(Palette[Math.Abs(h) % Palette.Length]);
        b = new SolidColorBrush(col); b.Freeze(); _colors[key] = b;
        return b;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")] private static extern int GetDeviceCaps(IntPtr hdc, int index);
    private static int PrimaryRefreshHz()
    {
        try { var dc = GetDC(IntPtr.Zero); int hz = GetDeviceCaps(dc, 116 /* VREFRESH */); ReleaseDC(IntPtr.Zero, dc); return hz > 1 ? hz : 120; }
        catch { return 120; }
    }

    private static string ShortTitle(string d)
    {
        var s = d.Split('.', '!', '—')[0].Trim();
        return s.Length > 60 ? s[..58].Trim() + "..." : s;
    }
}
