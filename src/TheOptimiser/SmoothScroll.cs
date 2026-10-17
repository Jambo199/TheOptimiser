using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Animation;

namespace TheOptimiser;

// Animated mouse-wheel scrolling for a pixel-scrolling (CanContentScroll=False) ScrollViewer.
// VerticalOffset is read-only, so we animate an attached proxy whose callback drives it.
public static class SmoothScroll
{
    private static readonly DependencyProperty OffsetProperty = DependencyProperty.RegisterAttached(
        "Offset", typeof(double), typeof(SmoothScroll),
        new PropertyMetadata(0.0, (d, e) => ((ScrollViewer)d).ScrollToVerticalOffset((double)e.NewValue)));

    private static readonly Dictionary<ScrollViewer, double> Target = new();

    public static void Enable(ScrollViewer sv) => sv.PreviewMouseWheel += OnWheel;

    private static void OnWheel(object sender, MouseWheelEventArgs e)
    {
        var sv = (ScrollViewer)sender;
        if (sv.ScrollableHeight <= 0) return;
        e.Handled = true;

        double current = sv.VerticalOffset;
        // accumulate across rapid notches; resync if the user dragged the thumb meanwhile
        double start = Target.TryGetValue(sv, out var t) ? t : current;
        if (Math.Abs(start - current) > sv.ViewportHeight) start = current;

        double target = Math.Clamp(start - e.Delta, 0, sv.ScrollableHeight);
        Target[sv] = target;

        var anim = new DoubleAnimation(current, target, TimeSpan.FromMilliseconds(200))
        {
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
        };
        sv.BeginAnimation(OffsetProperty, anim, HandoffBehavior.SnapshotAndReplace);
    }
}
