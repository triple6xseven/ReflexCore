using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;

namespace ReflexCore.Studio;

// Один общий «тикер» кадров для всех анимаций: пружины ползунков, частицы, падающий фон.
static class Ticker {
    static readonly List<Func<double, bool>> Items = new();
    static bool on, ticking; static long last;

    public static void Add(Func<double, bool> f) {
        if (!Items.Contains(f)) Items.Add(f);
        if (!on) { on = true; last = Stopwatch.GetTimestamp(); CompositionTarget.Rendering += Tick; }
    }

    static void Tick(object s, EventArgs e) {
        AdvanceFrame();
    }

    // A window resize can synchronously pump another Rendering event. Callbacks
    // may also register animations; additions start on the following frame.
    internal static void AdvanceFrame() {
        if (ticking) return;
        ticking = true;
        long n = Stopwatch.GetTimestamp();
        double dt = Math.Min(0.05, (n - last) / (double)Stopwatch.Frequency); last = n;
        try {
            var frame = Items.ToArray();
            foreach (var callback in frame) {
                bool keep = false;
                try { keep = callback(dt); }
                catch (InvalidOperationException) { /* Detached visual. */ }
                if (!keep) Items.Remove(callback);
            }
        } finally {
            ticking = false;
            if (Items.Count == 0) { CompositionTarget.Rendering -= Tick; on = false; }
        }
    }
}

// Режим «бесполезных анимаций».

static class Bounds {
    internal static double Clamp(double value,double min,double max) => Math.Max(min,Math.Min(max,value));
    internal static int Clamp(int value,int min,int max) => Math.Max(min,Math.Min(max,value));
}
static class Fx {
    internal static bool Fun, Click = true, Spring = true;
    public static void Pop(FrameworkElement e) {
        if (!Fun || !Click) return;
        var st=new ScaleTransform(1,1); e.RenderTransformOrigin=new Point(.5,.5);e.RenderTransform=st;
        var anim=new DoubleAnimation(.90,1,TimeSpan.FromMilliseconds(150));
        st.BeginAnimation(ScaleTransform.ScaleXProperty,anim);st.BeginAnimation(ScaleTransform.ScaleYProperty,anim);
    }
}