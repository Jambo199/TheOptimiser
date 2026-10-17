using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace TheOptimiser;

// Smooth, continuous wheel scrolling for a pixel-scrolling (CanContentScroll=False) ScrollViewer.
// Wheel notches accumulate into a target offset; every frame we ease the ScrollViewer a fraction
// of the way there (exponential smoothing), so rapid notches blend into one continuous glide
// instead of a series of separate eased hops (which felt rigid).
public static class SmoothScroll
{
    private sealed class State { public double Target; public bool Running; }

    private const double Step = 1.8;    // wheel travel per notch (120 * this) - bigger = more momentum
    private const double Ease = 0.12;   // fraction of remaining distance moved per frame - smaller = longer, smoother glide

    public static void Enable(ScrollViewer sv)
    {
        var st = new State { Target = sv.VerticalOffset };

        void Tick(object? sender, EventArgs e)
        {
            double cur = sv.VerticalOffset;
            double diff = st.Target - cur;
            if (Math.Abs(diff) < 0.4)
            {
                sv.ScrollToVerticalOffset(st.Target);
                CompositionTarget.Rendering -= Tick;
                st.Running = false;
                return;
            }
            sv.ScrollToVerticalOffset(cur + diff * Ease);
        }

        sv.PreviewMouseWheel += (_, e) =>
        {
            if (sv.ScrollableHeight <= 0) return;
            e.Handled = true;
            if (!st.Running) st.Target = sv.VerticalOffset;          // start from where we actually are
            st.Target = Math.Clamp(st.Target - e.Delta * Step, 0, sv.ScrollableHeight);
            if (!st.Running) { st.Running = true; CompositionTarget.Rendering += Tick; }
        };

        // resync the target when the user drags the thumb or the content resizes
        sv.ScrollChanged += (_, _) => { if (!st.Running) st.Target = sv.VerticalOffset; };
    }
}
