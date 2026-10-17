using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace TheOptimiser;

// Renders the main window's content to a PNG without showing a window (offscreen),
// so the design can be reviewed headlessly.
public static class PreviewRenderer
{
    public static void Render(string path, string section = "Tweaks", string? search = null, int w = 1280, int h = 840)
    {
        var win = new MainWindow();
        win.SelectSection(section);
        if (!string.IsNullOrEmpty(search)) win.SetSearch(search);
        if (section is "Debloat" or "Install") win.PreselectForPreview();
        var root = (FrameworkElement)win.Content;
        root.Width = w; root.Height = h;
        root.Measure(new Size(w, h));
        root.Arrange(new Rect(0, 0, w, h));
        root.UpdateLayout();

        var rtb = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(root);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(rtb));
        using var fs = File.Create(path);
        enc.Save(fs);
        Console.WriteLine("wrote " + path);
    }
}
