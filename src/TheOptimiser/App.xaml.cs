using System.Windows;

namespace TheOptimiser;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        if (e.Args.Length >= 1 && e.Args[0] == "--selftest")
        {
            SelfTest.Run();
            Shutdown();
            return;
        }

        if (e.Args.Length >= 1 && e.Args[0] == "--validate")
        {
            CatalogValidate.Run();
            Shutdown();
            return;
        }

        // headless preview: TheOptimiser.exe --preview <png> [section]
        if (e.Args.Length >= 2 && e.Args[0] == "--preview")
        {
            try { PreviewRenderer.Render(e.Args[1], e.Args.Length >= 3 ? e.Args[2] : "Tweaks", e.Args.Length >= 4 ? e.Args[3] : null); }
            catch (Exception ex) { Console.Error.WriteLine(ex); Environment.ExitCode = 1; }
            Shutdown();
            return;
        }

        new MainWindow().Show();
    }
}
