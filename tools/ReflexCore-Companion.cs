using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace ReflexCore.Bridge
{
    internal enum CompanionMood { Idle, Observing, Thinking, Working, Success, Warning }

    internal static class CompanionStateMachine
    {
        internal static CompanionMood Resolve(string stage)
        {
            string value=stage.ToLowerInvariant();
            if(value.Contains("error")||value.Contains("failed")||value.Contains("stopped"))return CompanionMood.Warning;
            if(value.Contains("verified")||value.Contains("completed"))return CompanionMood.Success;
            if(value.Contains("think")||value.Contains("decid")||value.Contains("plan"))return CompanionMood.Thinking;
            if(value.Contains("observ")||value.Contains("captur"))return CompanionMood.Observing;
            return value=="idle"?CompanionMood.Idle:CompanionMood.Working;
        }
    }

    internal sealed partial class ActivityHud
    {
        private bool pinned,clickThrough,positioned,dragging;
        private Point dragStart,windowStart;
        private string classicPreferences;
        internal bool feedWhenHidden;
        internal bool ClassicVisible {get{return Visible;}}

        internal void ConfigureClassicWidget()
        {
            string directory=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","companion");
            classicPreferences=Path.Combine(directory,"classic-v1.txt");
            try
            {
                var file=new FileInfo(File.Exists(classicPreferences)?classicPreferences:Path.Combine(directory,"widget-v1.txt"));
                if(file.Exists&&file.Length<128)
                {
                    string[] values=File.ReadAllText(file.FullName).Split(',');
                    if(values.Length==4 || values.Length==7)
                    {
                        pinned=values[1]=="1";
                        clickThrough=values.Length==4 && values[0]=="1";
                        int x,y;
                        if(Int32.TryParse(values[values.Length-2],out x)&&Int32.TryParse(values[values.Length-1],out y)&&
                            Screen.FromPoint(new Point(x,y)).WorkingArea.Contains(x,y))
                        {Location=new Point(x,y);positioned=true;}
                    }
                }
            }
            catch(IOException){} catch(UnauthorizedAccessException){}
            foreach(Control control in Controls)BindWidgetDrag(control);
            BindWidgetDrag(this);
            LayoutClassic();
        }

        private void BindWidgetDrag(Control surface)
        {
            surface.MouseDown+=(s,e)=>{
                if(e.Button!=MouseButtons.Left || pinned)return;
                dragStart=Cursor.Position;windowStart=Location;
                dragging=true;surface.Capture=true;
            };
            surface.MouseMove+=(s,e)=>{
                if(!dragging || !surface.Capture || Cursor.Position==dragStart)return;
                Location=new Point(windowStart.X+Cursor.Position.X-dragStart.X,windowStart.Y+Cursor.Position.Y-dragStart.Y);
                positioned=true;
            };
            surface.MouseCaptureChanged+=(s,e)=>{if(!surface.Capture)dragging=false;};
            surface.MouseUp+=(s,e)=>{
                if(e.Button!=MouseButtons.Left || !dragging)return;
                dragging=false;surface.Capture=false;
                Reposition();SaveClassicPreferences();
            };
        }

        internal object CompanionSnapshot(int pending,string queueState,bool metrics,bool paused,int[][] bounds,int[] foreground)
        {
            string stage=EffectiveStage(queueState);
            return new {
                schema="reflexcore.companion.live.v1",stage=CompanionStateMachine.Resolve(stage).ToString().ToLowerInvariant(),
                message=stage,pending=pending,metrics=new[]{hostLabel.Text,gpuLabel.Text,speedLabel.Text},
                show_metrics=metrics,classic_visible=!metrics,paused=paused,bounds=bounds,foreground=foreground,
                at_unix_ms=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
            };
        }

        private string EffectiveStage(string queueState)
        {
            if(stageLabel.Text!="Idle")return stageLabel.Text;
            if(queueState=="running")return "Running queued task";
            if(queueState=="completed")return "Task completed";
            if(queueState=="failed" || queueState=="error")return "Task failed";
            return "Idle";
        }
        internal void ResetWidgetPosition(){positioned=false;Reposition();SaveClassicPreferences();}

        internal void ConfigureClassic(double opacity,bool host,bool gpus,bool ollama)
        {
            if(Math.Abs(Opacity-opacity)>.01)Opacity=opacity;
            hostMetric=host;gpuMetric=gpus;ollamaMetric=ollama;
            LayoutClassic();
        }

        internal void AddClassicActions(ToolStripItemCollection items)
        {
            items.Add(clickThrough?"Disable Classic click-through":"Enable Classic click-through",null,(s,e)=>{
                clickThrough=!clickThrough;RecreateHandle();SaveClassicPreferences();
            });
            items.Add(pinned?"Unlock Classic position":"Pin Classic position",null,(s,e)=>{
                pinned=!pinned;SaveClassicPreferences();
            });
            items.Add("Reset Classic position",null,(s,e)=>ResetWidgetPosition());
        }

        private void LayoutClassic()
        {
            hostLabel.Visible=hostMetric;
            gpuLabel.Visible=gpuMetric;
            speedLabel.Visible=ollamaMetric;
            gpuLabel.Top=hostMetric?79:55;
            speedLabel.Top=gpuMetric?gpuLabel.Bottom+2:gpuLabel.Top;
            int bottom=ollamaMetric?speedLabel.Bottom+7:gpuMetric?gpuLabel.Bottom+7:gpuLabel.Top;
            ClientSize=new Size(420,bottom);
            foreach(Control label in Controls)label.Width=396;
            Reposition();
        }

        private void SaveClassicPreferences()
        {
            if(classicPreferences==null)return;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(classicPreferences));
                string coordinate=positioned?Left.ToString()+","+Top.ToString():",";
                File.WriteAllText(classicPreferences,(clickThrough?"1":"0")+","+(pinned?"1":"0")+","+coordinate);
            }
            catch(IOException){} catch(UnauthorizedAccessException){}
        }
    }
}
