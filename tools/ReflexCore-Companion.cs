using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
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

    internal sealed class CharacterAssetPack : IDisposable
    {
        private readonly Image[,] poses=new Image[2,6];
        private readonly bool[,] tried=new bool[2,6];
        internal static readonly string Folder=Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"ReflexCore","companion");
        internal Image Get(CompanionMood mood,bool stockings)
        {
            int variant=stockings?0:1,index=(int)mood;
            if(tried[variant,index])return poses[variant,index];
            tried[variant,index]=true;
            string folder=Path.Combine(Folder,stockings?"stockings":"bare-legs");
            foreach(string key in new[]{mood.ToString().ToLowerInvariant(),"idle"})
            {
                try
                {
                    var info=new FileInfo(Path.Combine(folder,key+".png"));
                    if(!info.Exists || info.Length>4*1024*1024)continue;
                    using(var stream=info.OpenRead())
                    using(var source=Image.FromStream(stream))
                        if(source.Width<=1600 && source.Height<=1600)
                            return poses[variant,index]=new Bitmap(source);
                }
                catch(IOException){} catch(ArgumentException){} catch(UnauthorizedAccessException){}
            }
            return null;
        }
        public void Dispose(){foreach(Image image in poses)if(image!=null)image.Dispose();}
    }

    internal sealed class CompanionViewModel
    {
        internal string Stage="Idle", Host="", Gpus="", Throughput="";
        internal int Pending;
        internal bool ShowTelemetry=true;
        internal string Bubble(double seconds,bool compact)
        {
            var messages=ShowTelemetry
                ?new[]{Stage,Host.Replace("    ","  ·  "),Gpus,Throughput,"Queue: "+Pending+" jobs"}
                :new[]{Stage,"Queue: "+Pending+" jobs"};
            string value=compact?Stage:messages[(int)(seconds/3.6)%messages.Length];
            if(String.IsNullOrWhiteSpace(value))return Stage;
            if(value.Contains(Environment.NewLine))
            {
                var lines=value.Split(new[]{Environment.NewLine},StringSplitOptions.RemoveEmptyEntries);
                if(lines.Length!=0)value=lines[(int)(seconds/18)%lines.Length];
            }
            return value;
        }
    }

    internal sealed class CompanionAnimationController
    {
        private readonly Stopwatch clock=Stopwatch.StartNew();
        private double reacted=-10;
        internal double Seconds {get{return clock.Elapsed.TotalSeconds;}}
        internal bool Reacting {get{return Seconds-reacted<1.1;}}
        internal void React(){reacted=Seconds;}
        internal float Bob(CompanionMood mood,bool hover)
        {
            double rate=mood==CompanionMood.Working?6:3;
            return (float)(Math.Sin(Seconds*rate)*(Reacting?5:2))-(hover?2:0);
        }
        internal bool Blink {get{return Seconds%4.7>4.52;}}
    }

    internal sealed class CompanionCanvas : Control
    {
        internal readonly CompanionViewModel Model=new CompanionViewModel();
        private readonly CompanionAnimationController animation=new CompanionAnimationController();
        private readonly CharacterAssetPack assets=new CharacterAssetPack();
        private readonly System.Windows.Forms.Timer timer=new System.Windows.Forms.Timer{Interval=85};
        internal bool Compact, Stockings=true;
        private bool hover;
        private readonly bool loadSprites;
        internal CompanionCanvas(bool useSprites=true)
        {
            loadSprites=useSprites;
            DoubleBuffered=true; Dock=DockStyle.Fill; BackColor=Color.Magenta; ForeColor=Color.White;
            timer.Tick+=(s,e)=>Invalidate();
            VisibleChanged+=(s,e)=>{if(Visible)timer.Start();else timer.Stop();};
            MouseEnter+=(s,e)=>{hover=true;animation.React();};
            MouseLeave+=(s,e)=>hover=false;
            MouseClick+=(s,e)=>{if(e.Button==MouseButtons.Left)animation.React();};
        }

        internal static void SelfTest()
        {
            if(CompanionStateMachine.Resolve("Vision — Thinking")!=CompanionMood.Thinking ||
               CompanionStateMachine.Resolve("Step verified")!=CompanionMood.Success ||
               CompanionStateMachine.Resolve("Error")!=CompanionMood.Warning)
                throw new InvalidOperationException("Companion state mapping failed.");
            using(var canvas=new CompanionCanvas(false){Size=new Size(292,271)})
            using(var bitmap=new Bitmap(292,271))
            {
                canvas.Model.Pending=2;
                if(canvas.Model.Bubble(15,false)!="Queue: 2 jobs")throw new InvalidOperationException("Companion queue rotation failed.");
                canvas.Model.ShowTelemetry=false;canvas.Model.Host="CPU 42%";
                if(canvas.Model.Bubble(4,false)!="Queue: 2 jobs")throw new InvalidOperationException("Combined widget repeated telemetry.");
                canvas.DrawToBitmap(bitmap,new Rectangle(Point.Empty,bitmap.Size));
                if(bitmap.GetPixel(22,30).ToArgb()==Color.Magenta.ToArgb() ||
                   bitmap.GetPixel(145,100).ToArgb()==Color.Magenta.ToArgb())
                    throw new InvalidOperationException("Companion did not draw its bubble and avatar.");
            }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            Graphics g=e.Graphics;
            g.SmoothingMode=SmoothingMode.AntiAlias;
            var mood=CompanionStateMachine.Resolve(Model.Stage);
            Color accent=mood==CompanionMood.Warning?Color.Salmon:mood==CompanionMood.Success?Color.MediumSpringGreen:Color.FromArgb(116,237,219);
            float bob=animation.Bob(mood,hover), mid=Width/2f;
            using(var panel=new SolidBrush(Color.FromArgb(19,29,44)))
            using(var edge=new Pen(accent,1))
            using(var tint=new SolidBrush(accent))
            using(var bubble=Round(new RectangleF(7,7,Width-15,48),14))
            {
                g.FillPath(panel,bubble);g.DrawPath(edge,bubble);
                g.FillPolygon(panel,new[]{new PointF(mid-8,53),new PointF(mid+7,53),new PointF(mid,63)});
                g.FillEllipse(tint,17,17,6,6);
                TextRenderer.DrawText(g,"REFLEX  /  "+mood.ToString().ToUpperInvariant(),Font,new Rectangle(28,11,Width-42,16),accent,TextFormatFlags.EndEllipsis);
                string line=animation.Reacting?"Ready when you are.":Model.Bubble(animation.Seconds,Compact);
                TextRenderer.DrawText(g,line,Font,new Rectangle(16,28,Width-32,22),Color.White,TextFormatFlags.EndEllipsis|TextFormatFlags.SingleLine);
                var frame=new RectangleF(mid-76,66+bob,152,Height-68);
                var sprite=loadSprites?assets.Get(mood,Stockings):null;
                if(sprite!=null)
                {
                    float scale=Math.Min(frame.Width/sprite.Width,frame.Height/sprite.Height);
                    g.DrawImage(sprite,mid-sprite.Width*scale/2,frame.Y,sprite.Width*scale,sprite.Height*scale);
                }
                else
                {
                    var saved=g.Save();
                    g.TranslateTransform(mid-62,66+bob);g.ScaleTransform(1,(Height-70)/194f);
                    DrawCharacter(g,accent,animation.Blink,mood,Stockings);
                    g.Restore(saved);
                }
            }
        }

        private static GraphicsPath Round(RectangleF r,float d)
        {
            var path=new GraphicsPath();
            path.AddArc(r.X,r.Y,d,d,180,90);path.AddArc(r.Right-d,r.Y,d,d,270,90);
            path.AddArc(r.Right-d,r.Bottom-d,d,d,0,90);path.AddArc(r.X,r.Bottom-d,d,d,90,90);path.CloseFigure();
            return path;
        }
        private static void Shape(Graphics g,Color color,params Point[] points)
        { using(var brush=new SolidBrush(color))g.FillPolygon(brush,points); }
        private static void Oval(Graphics g,Color color,int x,int y,int width,int height)
        { using(var brush=new SolidBrush(color))g.FillEllipse(brush,x,y,width,height); }
        private static void DrawCharacter(Graphics g,Color accent,bool blink,CompanionMood mood,bool stockings)
        {
            var hair=Color.FromArgb(212,224,245);var shade=Color.FromArgb(123,147,184);
            var skin=Color.FromArgb(255,213,200);var dark=Color.FromArgb(28,35,55);var deeper=Color.FromArgb(10,15,28);
            Oval(g,Color.FromArgb(42,61,76),18,185,92,7);
            Shape(g,shade,new Point(29,38),new Point(12,124),new Point(40,113),new Point(90,114),new Point(105,133),new Point(98,38));
            Oval(g,hair,23,2,79,78);
            Oval(g,skin,34,19,57,65);
            Shape(g,hair,new Point(29,47),new Point(41,13),new Point(67,6),new Point(91,16),new Point(97,57),new Point(76,34),new Point(68,26),new Point(52,48),new Point(53,31));
            Oval(g,dark,25,32,10,28);Oval(g,dark,91,32,10,28);
            Oval(g,accent,27,39,5,12);Oval(g,accent,94,39,5,12);
            Oval(g,Color.Salmon,40,57,8,4);Oval(g,Color.Salmon,77,57,8,4);
            foreach(int x in new[]{46,69})
            {
                Oval(g,deeper,x,45,12,blink?2:15);
                if(!blink){Oval(g,accent,x+2,48,8,10);Oval(g,Color.White,x+3,48,3,3);}
            }
            using(var pen=new Pen(Color.FromArgb(111,51,67),1.5f))
                g.DrawArc(pen,58,mood==CompanionMood.Warning?69:62,10,9,mood==CompanionMood.Warning?200:18,145);
            Shape(g,skin,new Point(54,72),new Point(72,72),new Point(73,94),new Point(53,94));
            Shape(g,dark,new Point(51,83),new Point(27,91),new Point(18,129),new Point(29,136),new Point(44,110),new Point(44,134),new Point(83,134),new Point(84,110),new Point(99,136),new Point(109,131),new Point(100,92),new Point(74,83),new Point(62,97));
            Shape(g,accent,new Point(52,84),new Point(62,97),new Point(74,84),new Point(70,98),new Point(62,105),new Point(54,97));
            Shape(g,deeper,new Point(44,127),new Point(82,127),new Point(91,147),new Point(36,147));
            foreach(int x in new[]{43,68})
            {
                Shape(g,stockings?dark:skin,new Point(x,144),new Point(x+16,144),new Point(x+12,183),new Point(x+1,183));
                if(stockings)Shape(g,accent,new Point(x,150),new Point(x+16,150),new Point(x+15,152),new Point(x,152));
                Oval(g,deeper,x-2,178,20,9);
            }
            Oval(g,skin,19,130,10,10);Oval(g,skin,98,130,10,10);
            Oval(g,accent,60,111,5,5);Oval(g,accent,60,120,5,2);
        }

        protected override void Dispose(bool disposing)
        {
            if(disposing){timer.Dispose();assets.Dispose();}
            base.Dispose(disposing);
        }
    }

    internal sealed partial class ActivityHud
    {
        private CompanionCanvas companion;
        private bool companionMode,combined,pinned,clickThrough,positioned,muted=true;
        private Point dragStart, windowStart;
        private bool dragging;
        private string preferences;
        private Action openStudio, hideWidget;

        internal void ConfigureCompanion(Action open,Action hide)
        {
            openStudio=open;hideWidget=hide;
            companion=new CompanionCanvas{Visible=false};
            Controls.Add(companion);
            preferences=Path.Combine(CharacterAssetPack.Folder,"widget-v1.txt");
            try
            {
                if(File.Exists(preferences) && new FileInfo(preferences).Length<128)
                {
                    string[] v=File.ReadAllText(preferences).Split(',');
                    if(v.Length==7)
                    {
                        companionMode=v[0]=="1"||v[0]=="2";combined=v[0]=="2";pinned=v[1]=="1";companion.Compact=v[2]=="1";companion.Stockings=v[3]!="0";muted=v[4]!="0";
                        int x,y;
                        if(Int32.TryParse(v[5],out x)&&Int32.TryParse(v[6],out y)&&Screen.FromPoint(new Point(x,y)).WorkingArea.Contains(x,y))
                        {Location=new Point(x,y);positioned=true;}
                    }
                }
            }
            catch(IOException){} catch(UnauthorizedAccessException){}
            companion.MouseDown+=(s,e)=>{if(e.Button==MouseButtons.Left){dragStart=Cursor.Position;if(!pinned){dragging=true;windowStart=Location;companion.Capture=true;}}};
            companion.MouseMove+=(s,e)=>{if(dragging){Location=new Point(windowStart.X+Cursor.Position.X-dragStart.X,windowStart.Y+Cursor.Position.Y-dragStart.Y);positioned=true;}};
            companion.MouseUp+=(s,e)=>{
                if(!dragging && e.Button!=MouseButtons.Left)return;
                dragging=false;companion.Capture=false;
                if(e.Button==MouseButtons.Left && Cursor.Position==dragStart){companion.Compact=!companion.Compact;if(!muted)System.Media.SystemSounds.Asterisk.Play();SetWidgetMode();}
                SaveWidget();
            };
            companion.ContextMenuStrip=new ContextMenuStrip();
            companion.ContextMenuStrip.Opening+=(s,e)=>{while(companion.ContextMenuStrip.Items.Count>0)companion.ContextMenuStrip.Items[0].Dispose();AddWidgetActions(companion.ContextMenuStrip.Items,true);};
            SetWidgetMode();
        }

        internal void AddWidgetActions(ToolStripItemCollection items,bool detailed=false)
        {
            string[] names={"Classic","AI Companion","Both"};
            for(int i=0;i<names.Length;i++)
            {
                int mode=i;
                var choice=new ToolStripMenuItem(names[i]){Checked=mode==(combined?2:companionMode?1:0)};
                choice.Click+=(s,e)=>{companionMode=mode!=0;combined=mode==2;SetWidgetMode();SaveWidget();};
                items.Add(choice);
            }
            if(!detailed)
            {
                var settings=new ToolStripMenuItem("Companion options");
                AddCompanionOptions(settings.DropDownItems);items.Add(settings);return;
            }
            items.Add(new ToolStripSeparator());AddCompanionOptions(items);
            items.Add("Open ReflexCore Studio",null,(s,e)=>openStudio());
            items.Add("Hide Widget",null,(s,e)=>hideWidget());
        }

        private void AddCompanionOptions(ToolStripItemCollection items)
        {
            items.Add(clickThrough?"Disable Click-through":"Enable Click-through",null,(s,e)=>{clickThrough=!clickThrough;RecreateHandle();});
            items.Add(companion.Compact?"Full Companion":"Compact Companion",null,(s,e)=>{companion.Compact=!companion.Compact;SetWidgetMode();SaveWidget();});
            items.Add(companion.Stockings?"Use Bare-legs Preset":"Use Stockings Preset",null,(s,e)=>{companion.Stockings=!companion.Stockings;SaveWidget();});
            items.Add(pinned?"Unlock Position":"Pin Position",null,(s,e)=>{pinned=!pinned;SaveWidget();});
            items.Add(muted?"Enable Reaction Sound":"Mute Reaction Sound",null,(s,e)=>{muted=!muted;if(!muted)System.Media.SystemSounds.Asterisk.Play();SaveWidget();});
        }

        private void SetWidgetMode()
        {
            if(companion==null)return;
            foreach(Control control in Controls)if(!ReferenceEquals(control,companion))control.Visible=!companionMode||combined;
            companion.Visible=companionMode;
            companion.BringToFront();
            companion.Model.ShowTelemetry=!combined;
            BackColor=companionMode&&!combined?Color.Magenta:Color.FromArgb(14,24,27);
            TransparencyKey=companionMode?Color.Magenta:Color.Empty;
            companion.Dock=DockStyle.None;
            if(companionMode)
            {
                companion.Size=new Size(companion.Compact?224:292,companion.Compact?218:271);
                int width=combined?420:companion.Width;
                companion.Location=new Point((width-companion.Width)/2,combined?speedLabel.Bottom+7:0);
                ClientSize=new Size(width,companion.Bottom);
            }
            else ClientSize=new Size(420,speedLabel.Bottom+7);
            Reposition();
        }

        private void SaveWidget()
        {
            try
            {
                Directory.CreateDirectory(CharacterAssetPack.Folder);
                File.WriteAllText(preferences,String.Join(",",new[]{combined?"2":companionMode?"1":"0",pinned?"1":"0",companion.Compact?"1":"0",companion.Stockings?"1":"0",muted?"1":"0",Left.ToString(),Top.ToString()}));
            }
            catch(IOException){} catch(UnauthorizedAccessException){}
        }
        internal void RefreshCompanion(int pending,string queueState)
        {
            if(companion==null || !companionMode)return;
            var model=companion.Model;
            model.Stage=stageLabel.Text=="Idle" && queueState=="running"?"Running queued task":stageLabel.Text;
            model.Host=hostLabel.Text;model.Gpus=gpuLabel.Text;model.Throughput=speedLabel.Text;model.Pending=pending;
        }
    }
}
