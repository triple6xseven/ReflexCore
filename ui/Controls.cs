using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace ReflexCore.Studio;

// Переключатель-тумблер (цвета берёт из темы).
class Sw : Grid {
    public bool On;
    public event Action<bool> Changed;           // только от действий пользователя
    readonly Border track = new(), thumb = new();
    readonly TranslateTransform tt = new();
    readonly TextBlock mark=new(){Text="✓",FontSize=18,FontWeight=FontWeights.Bold,HorizontalAlignment=HorizontalAlignment.Left,Margin=new Thickness(3,0,0,0),VerticalAlignment=VerticalAlignment.Center,IsHitTestVisible=false};

    public Sw(bool on) {
        On = on; Width = 46; Height = 26; Cursor = Cursors.Hand; Background = Brushes.Transparent;
        track.SetResourceReference(Border.CornerRadiusProperty,"SwitchCorner");
        track.BorderThickness=new Thickness(1);track.SetResourceReference(Border.BorderBrushProperty,"Sub");
        thumb.Width = 20; thumb.Height = 20; thumb.SetResourceReference(Border.CornerRadiusProperty,"ThumbCorner"); thumb.SetResourceReference(Border.BackgroundProperty,"OnAccent");
        thumb.HorizontalAlignment = HorizontalAlignment.Left; thumb.Margin = new Thickness(3); thumb.RenderTransform = tt;
        Children.Add(track); Children.Add(thumb);
        mark.SetResourceReference(TextBlock.ForegroundProperty,"Text");Children.Add(mark);Loaded+=(_,_)=>RefreshSkin();
        Paint(false);
        Focusable=true;
        KeyDown+=(_,e)=>{if(e.Key is Key.Space or Key.Enter){On=!On;Paint(true);Changed?.Invoke(On);e.Handled=true;}};
        MouseLeftButtonUp += (_, _) => { On = !On; Paint(true); Changed?.Invoke(On); Fx.Pop(this); };
    }

    public void Put(bool v) { On = v; Paint(false); }
    public void RefreshSkin(){
        int kind=TryFindResource("ControlKind") is int k?k:0;
        track.SetResourceReference(Border.BackgroundProperty,kind==1?"PopupSurface":On?"Accent":"Track");
        mark.SetResourceReference(TextBlock.ForegroundProperty,kind==1?"XPCheck":"Text");
        mark.Visibility=kind==1&&On?Visibility.Visible:Visibility.Collapsed;
        thumb.Visibility=kind==1?Visibility.Collapsed:Visibility.Visible;
        track.Width=kind==1?24:46;track.Height=kind is 1 or 3?22:26;track.HorizontalAlignment=HorizontalAlignment.Left;track.VerticalAlignment=VerticalAlignment.Center;
        thumb.Width=kind==3?12:kind==4?16:20;thumb.Height=kind==4?16:20;
        thumb.LayoutTransform=kind==4?new RotateTransform(45):null;
    }

    void Paint(bool anim) {
        RefreshSkin();
        track.SetResourceReference(Border.BackgroundProperty, TryFindResource("ControlKind") is int kind&&kind==1?"PopupSurface":On ? "Accent" : "Track");
        double to = On ? 20 : 0;
        if (anim) {
            IEasingFunction ez = Fx.Fun && Fx.Click ? new BackEase { Amplitude = 0.9, EasingMode = EasingMode.EaseOut } : new CubicEase { EasingMode = EasingMode.EaseOut };
            tt.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(to, TimeSpan.FromMilliseconds(Fx.Fun && Fx.Click ? 380 : 140)) { EasingFunction = ez });
        } else {
            tt.BeginAnimation(TranslateTransform.XProperty, null); tt.X = to;
        }
    }
}

// Ползунок: в режиме бесполезных анимаций ручка живёт на пружине (инерция, перелёт, растяжение).
// Само значение при этом точное и меняется мгновенно.
class Sld : Grid {
    public double Min, Max, Val;
    public event Action<double> Changed;         // только от действий пользователя
    public static int Wheel = 0;                     // 0 = выкл, 1 = колесо, 2 = Ctrl + колесо
    const double TW = 20;
    readonly Border track = new(), fill = new(), thumb = new();
    readonly TranslateTransform tt = new(); readonly ScaleTransform sc = new();
    double vis, vel, tgt; bool drag, run;

    public Sld(double min, double max, double val) {
        Min = min; Max = max; Val = val; Height = 28; MinWidth = 120; Background = Brushes.Transparent; Cursor = Cursors.Hand;

        track.Height = 6; track.CornerRadius = new CornerRadius(3); track.VerticalAlignment = VerticalAlignment.Center;
        track.SetResourceReference(Border.BackgroundProperty, "Track");

        fill.Height = 6; fill.CornerRadius = new CornerRadius(3); fill.VerticalAlignment = VerticalAlignment.Center; fill.HorizontalAlignment = HorizontalAlignment.Left;
        fill.SetResourceReference(Border.BackgroundProperty, "Accent");

        thumb.Width = TW; thumb.Height = TW; thumb.CornerRadius = new CornerRadius(TW / 2); thumb.BorderThickness = new Thickness(3);
        thumb.HorizontalAlignment = HorizontalAlignment.Left; thumb.VerticalAlignment = VerticalAlignment.Center;
        thumb.SetResourceReference(Border.BackgroundProperty, "Card"); thumb.SetResourceReference(Border.BorderBrushProperty, "Accent2");
        var tg = new TransformGroup(); tg.Children.Add(sc); tg.Children.Add(tt);
        thumb.RenderTransform = tg; thumb.RenderTransformOrigin = new Point(.5, .5);

        Children.Add(track); Children.Add(fill); Children.Add(thumb);

        SizeChanged += (_, _) => { Target(); vis = tgt; Draw(); };
        MouseLeftButtonDown += (_, e) => { drag = true; CaptureMouse(); Pick(e.GetPosition(this).X); };
        MouseMove += (_, e) => { if (drag) Pick(e.GetPosition(this).X); };
        MouseLeftButtonUp += (_, _) => { drag = false; ReleaseMouseCapture(); };
        MouseEnter += (_, _) => { if (Wheel != 0) thumb.BorderThickness = new Thickness(5); };
        MouseLeave += (_, _) => { thumb.BorderThickness = new Thickness(3); };
        MouseWheel += (_, e) => {
            if (Wheel == 0) return;
            if (Wheel == 2 && (Keyboard.Modifiers & ModifierKeys.Control) == 0) return;
            double st = (Keyboard.Modifiers & ModifierKeys.Shift) != 0 ? 1 : Math.Max(1, Math.Round((Max - Min) / 100));
            Nudge(e.Delta > 0 ? st : -st);
            e.Handled = true;
        };
    }

    public void Nudge(double d) {
        double v = Math.Round(Bounds.Clamp(Val + d, Min, Max));
        if (v == Val) return;
        Val = v; Move(); Changed?.Invoke(Val);
    }

    public void Put(double v) { Val = Math.Round(Bounds.Clamp(v, Min, Max)); Move(); }

    void Pick(double x) {
        double f = Bounds.Clamp((x - TW / 2) / Math.Max(1, ActualWidth - TW), 0, 1);
        double v = Math.Round(Min + f * (Max - Min));
        if (v == Val) return;
        Val = v; Move(); Changed?.Invoke(Val);
    }

    void Target() { tgt = (Max > Min ? (Val - Min) / (Max - Min) : 0) * Math.Max(0, ActualWidth - TW); }
    void Draw() { tt.X = vis; fill.Width = Math.Max(0, vis + TW / 2); }
    void Move() { Target(); if (Fx.Fun && Fx.Spring && ActualWidth > 0) Kick(); else { vis = tgt; Draw(); } }
    void Kick() { if (!run) { run = true; Ticker.Add(Step); } }

    bool Step(double dt) {
        const double k = 260, c = 15;
        double a = k * (tgt - vis) - c * vel;
        vel += a * dt; vis += vel * dt;
        double st = 1 + Math.Min(0.8, Math.Abs(vel) / 900);
        sc.ScaleX = st; sc.ScaleY = 1 / st;
        Draw();
        if (Math.Abs(vel) < 2 && Math.Abs(tgt - vis) < 0.3) {
            vis = tgt; vel = 0; sc.ScaleX = 1; sc.ScaleY = 1; Draw(); run = false; return false;
        }
        return true;
    }
}

// Раскладка карточками в несколько колонок. Колонки считаются по ширине окна;
// при смене положения карточки плавно переезжают.
class Flow : Panel {
    public int Force = 0;                 // 0 = авто, иначе фиксированное число колонок
    public int MinCols = 1;
    public int MaxCols = 2;
    public double MinW = 430, Gap = 12;
    public bool Anim = true;
    readonly Dictionary<UIElement, Point> last = new();

    public void Reset() { last.Clear(); }

    int Cols(double w) { int n = Force > 0 ? Force : (int)(w / MinW); return Bounds.Clamp(Math.Max(n, MinCols), 1, Math.Max(1, Math.Min(MaxCols,InternalChildren.Count))); }

    protected override Size MeasureOverride(Size a) {
        double w = double.IsInfinity(a.Width) ? 480 : a.Width;
        int n = Cols(w); double cw = (w - Gap * (n - 1)) / n;
        var hs = new double[n];
        int index=0;
        foreach (UIElement c in InternalChildren) {
            c.Measure(new Size(cw, double.PositiveInfinity));
            int k = index++ % n;
            hs[k] += c.DesiredSize.Height + Gap;
        }
        return new Size(w, Math.Max(0, hs.Max() - Gap));
    }

    protected override Size ArrangeOverride(Size f) {
        int n = Cols(f.Width); double cw = (f.Width - Gap * (n - 1)) / n;
        var hs = new double[n];
        int index=0;
        foreach (UIElement c in InternalChildren) {
            int k = index++ % n;
            var p = new Point(k * (cw + Gap), hs[k]);
            c.Arrange(new Rect(p, new Size(cw, c.DesiredSize.Height)));
            hs[k] += c.DesiredSize.Height + Gap;
            Slide(c, p);
        }
        return f;
    }

    void Slide(UIElement c, Point p) {
        if (c.RenderTransform is not TranslateTransform tt) { tt = new TranslateTransform(); c.RenderTransform = tt; }
        // Only animate a change of column. Continuous resize follows the native
        // arrange pass immediately instead of restarting a spring every frame.
        if (Anim && !SmoothWheel.Busy && last.TryGetValue(c, out var o) && Math.Abs(o.X - p.X) > MinW / 2) {
            double fx = o.X + tt.X - p.X, fy = o.Y + tt.Y - p.Y;
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            tt.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(fx, 0, TimeSpan.FromMilliseconds(320)) { EasingFunction = ease });
            tt.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(fy, 0, TimeSpan.FromMilliseconds(320)) { EasingFunction = ease });
        }
        else if(tt.HasAnimatedProperties||tt.X!=0||tt.Y!=0) { tt.BeginAnimation(TranslateTransform.XProperty,null); tt.BeginAnimation(TranslateTransform.YProperty,null); tt.X=tt.Y=0; }
        last[c] = p;
    }
}

