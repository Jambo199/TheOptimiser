using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace TheOptimiser;

// Smooth wheel scrolling that runs on the render (composition) thread - the same reason the toggle
// animations are smooth. The ScrollViewer offset is set instantly (so the scrollbar stays correct),
// then the content is visually caught up by animating a TranslateTransform.Y from the old position
// back to zero at DesiredFrameRate = the monitor refresh. No per-frame UI-thread scrolling, no cache.
// Works because the list is fully realised (non-virtualised), so the shifted content has no gaps.
public static class SmoothScroll
{
    private const double Step = 0.45;             // wheel travel per notch (120 * this) - lower = slower
    private const double GlideMs = 210;           // catch-up time per notch - longer = gentler motion
    public static int Fps { get; set; } = 120;    // set to the monitor refresh rate at startup

    public static void Enable(ScrollViewer sv)
    {
        if (sv.Content is not UIElement content) return;
        var tt = new TranslateTransform();
        content.RenderTransform = tt;
        double target = sv.VerticalOffset;

        sv.PreviewMouseWheel += (_, e) =>
        {
            if (sv.ScrollableHeight <= 0) return;
            e.Handled = true;

            double real = sv.VerticalOffset;
            if (Math.Abs(target - real) > sv.ViewportHeight) target = real;   // resync after a thumb drag
            double visual = real - tt.Y;                                      // where the content appears right now
            target = Math.Clamp(target - e.Delta * Step, 0, sv.ScrollableHeight);

            sv.ScrollToVerticalOffset(target);                                // jump the offset; scrollbar correct
            var anim = new DoubleAnimation(target - visual, 0, new Duration(TimeSpan.FromMilliseconds(GlideMs)))
            {
                EasingFunction = new SineEase { EasingMode = EasingMode.EaseOut }   // gentlest start of the ease-outs
            };
            Timeline.SetDesiredFrameRate(anim, Fps);
            tt.BeginAnimation(TranslateTransform.YProperty, anim, HandoffBehavior.SnapshotAndReplace);
        };

        sv.ScrollChanged += (_, e) =>
        {
            if (e.ExtentHeightChange != 0)   // content changed (section switch / filter): clear any glide
            {
                tt.BeginAnimation(TranslateTransform.YProperty, null);
                tt.Y = 0;
                target = sv.VerticalOffset;
            }
        };
    }
}
