using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Interop;
using Forms = System.Windows.Forms;

namespace ReflexCore.Studio;

// The same damped spring as the zxcLagLab WPF gallery, applied to native pages.
sealed class HostedWheel : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    struct ScreenPoint { public int X,Y; }
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(ScreenPoint point);
    readonly Forms.Control root;
    readonly Func<bool> enabled;
    Forms.ScrollableControl active;
    double position, target, velocity;
    bool running;
    int appliedOffset;
    public HostedWheel(Forms.Control root,Func<bool> enabled)
    {
        this.root=root;this.enabled=enabled;
        ComponentDispatcher.ThreadFilterMessage+=Wheel;
    }
    void Wheel(ref MSG message,ref bool handled)
    {
        if(handled||!enabled()||message.message!=0x020a)return;
        long keys=message.wParam.ToInt64();
        if((keys&8)!=0)return;
        Forms.ScrollableControl recipient=null;
        long pointer=message.lParam.ToInt64();
        var hwnd=WindowFromPoint(new ScreenPoint{X=unchecked((short)pointer),Y=unchecked((short)(pointer>>16))});
        for(var control=Forms.Control.FromChildHandle(hwnd);control!=null;control=control.Parent)
        {
            if(control is Forms.ComboBox || control is Forms.UpDownBase || control is Forms.ListView ||
                control is Forms.ListBox || control is Forms.DataGridView)return;
            if(recipient==null && control is Forms.ScrollableControl scroll && scroll.AutoScroll && scroll.VerticalScroll.Visible)
                recipient=scroll;
            if(control!=root)continue;
            if(recipient==null)return;
            if(active!=recipient || !running || -recipient.AutoScrollPosition.Y!=appliedOffset)
            {
                active=recipient;
                position=target=appliedOffset=-recipient.AutoScrollPosition.Y;velocity=0;
            }
            int delta=unchecked((short)(keys>>16));
            target=Bounds.Clamp(target-delta/120.0*96*((keys&4)!=0?2:1),0,Limit());
            handled=true;
            if(!running){running=true;Ticker.Add(Step);}
            return;
        }
    }
    int Limit()=>Math.Max(0,active.VerticalScroll.Maximum-active.VerticalScroll.LargeChange+1);
    bool Step(double dt)
    {
        if(active==null || active.IsDisposed || !active.Visible || !enabled() ||
            -active.AutoScrollPosition.Y!=appliedOffset){running=false;return false;}
        target=Bounds.Clamp(target,0,Limit());
        (position,velocity)=Motion.Advance(position,velocity,target,dt,210);
        running=Math.Abs(position-target)>.35 || Math.Abs(velocity)>2;
        int next=(int)Math.Round(running?Bounds.Clamp(position,0,Limit()):target);
        if(next!=appliedOffset)active.AutoScrollPosition=new System.Drawing.Point(-active.AutoScrollPosition.X,next);
        appliedOffset=-active.AutoScrollPosition.Y;
        return running;
    }
    public void Dispose(){ComponentDispatcher.ThreadFilterMessage-=Wheel;active=null;}
}

static class Motion
{
    public static (double position, double velocity) Advance(double position, double velocity, double target, double dt, double durationMs)
    {
        double w = 6 / Math.Max(0.1, durationMs / 1000), delta = position - target, c = velocity + w * delta, e = Math.Exp(-w * Math.Max(0, dt));
        double next = target + (delta + c * dt) * e, v = (velocity - w * c * dt) * e;
        if ((target - position) * (target - next) < 0) return (target, 0);
        return (next, v);
    }
}

sealed class SmoothWheel
{
    readonly ScrollViewer viewer;
    readonly Func<bool> enabled;
    readonly Func<double> duration;
    double target, position, velocity, requestedOffset;
    bool running, applying;
    public static bool Busy { get; private set; }
    static int active;
    public SmoothWheel(ScrollViewer viewer, Func<bool> enabled, Func<double> duration)
    {
        this.viewer = viewer; this.enabled = enabled; this.duration = duration;
        viewer.PreviewMouseWheel += Wheel;
        viewer.ScrollChanged += (_, e) => { if (!running || applying) return; if (Math.Abs(e.VerticalChange) > 0.01 && Math.Abs(viewer.VerticalOffset - position) > 2) Stop(); };
        viewer.Unloaded += (_, _) => Stop();
    }
    void Stop() { if (!running) return; running = false; velocity = 0; active = Math.Max(0, active - 1); Busy = active > 0; }
    void Wheel(object sender, MouseWheelEventArgs e)
    {
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) return;
        // Leave drop-downs, lists, sliders and nested scrolling surfaces in charge of their own input.
        for (DependencyObject node = e.OriginalSource as DependencyObject; node != null && node != viewer; node = Parent(node))
        {
            if (node is ComboBox or ListBox or Slider or ScrollViewer || node is Sld && Sld.Wheel == 1) return;
        }
        if (viewer.ScrollableHeight <= 0) return;
        double movement = e.Delta / 120.0 * 96 * (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? 2 : 1);
        e.Handled = true;
        if (!enabled())
        {
            Stop();
            viewer.ScrollToVerticalOffset(Bounds.Clamp(viewer.VerticalOffset - movement, 0, viewer.ScrollableHeight));
            return;
        }
        if (!running) { requestedOffset = position = viewer.VerticalOffset; target = position; velocity = 0; }
        target = Bounds.Clamp(target - movement, 0, viewer.ScrollableHeight);
        if (running) return; running = true; active++; Busy = true; Ticker.Add(Step);
    }
    static DependencyObject Parent(DependencyObject node) => node is System.Windows.Media.Visual or System.Windows.Media.Media3D.Visual3D ? VisualTreeHelper.GetParent(node) : LogicalTreeHelper.GetParent(node);
    bool Step(double dt)
    {
        if (!running) return false;
        if (!enabled() || !viewer.IsVisible) { Stop(); return false; }
        target = Bounds.Clamp(target, 0, viewer.ScrollableHeight);
        (position, velocity) = Motion.Advance(position, velocity, target, dt, duration());
        bool settled = Math.Abs(target - position) < 0.15 && Math.Abs(velocity) < 2;
        if (settled) { position = target; Stop(); }
        // ScrollViewer queues layout work. Skip movement smaller than half a device pixel,
        // but always apply the exact target at the end.
        if (settled || Math.Abs(position - requestedOffset) * VisualTreeHelper.GetDpi(viewer).DpiScaleY >= .5)
        {
            requestedOffset = position;
            applying = true; viewer.ScrollToVerticalOffset(position); applying = false;
        }
        return running;
    }
}
