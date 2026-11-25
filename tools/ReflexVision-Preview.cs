using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ReflexCore.Vision
{
    public static class Preview
    {
        private const string StopName = @"Local\ReflexVisionStop";
        public static bool Stop()
        {
            try { using (var signal = EventWaitHandle.OpenExisting(StopName)) return signal.Set(); }
            catch (WaitHandleCannotBeOpenedException) { return false; }
        }

        public static string Run(string project, int pid, long window, int width, bool cpu, int samples, bool fixture, string lobbyLease = null)
        {
            using (var mutex = new Mutex(false, @"Local\ReflexVisionPreview"))
            {
                bool acquired;
                try { acquired = mutex.WaitOne(0); } catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new InvalidOperationException("ReflexVision is already running.");
                try
                {
                    using (var stop = new EventWaitHandle(false, EventResetMode.ManualReset, StopName))
                    using (var fixtureWindow = fixture ? new BenchmarkScene() : null)
                    {
                        stop.Reset();
                        if (fixture)
                        {
                            fixtureWindow.Show();
                            fixtureWindow.Activate();
                            Application.DoEvents();
                            pid = Process.GetCurrentProcess().Id;
                            window = fixtureWindow.Handle.ToInt64();
                        }
                        string relay = fixture || !String.IsNullOrEmpty(lobbyLease) ? null : Path.Combine(project, "data", "bridge", "reflexvision.json");
                        using (var form = new PreviewWindow(pid, new IntPtr(window), width, cpu, samples, stop, relay, fixtureWindow, project))
                        {
                            form.LobbyLease = lobbyLease;
                            if (!String.IsNullOrEmpty(lobbyLease)) form.StartLobbyDetector(project);
                            Application.Run(form);
                            return form.Report();
                        }
                    }
                }
                finally { mutex.ReleaseMutex(); }
            }
        }

        public static string SelfTest()
        {
            using (var surface = new Surface(320, 200))
            using (var stop = new EventWaitHandle(false, EventResetMode.ManualReset, StopName + "_SelfTest"))
            {
                var detector = new ColorRegions();
                var tracker = new Tracker();
                var observations = new List<Detection>();
                var results = new List<Track>();
                using (var g = Graphics.FromImage(surface.Image))
                {
                    g.Clear(Color.Navy);
                    detector.Detect(surface, observations);
                    if (observations.Count != 0) throw new InvalidOperationException("Detected a blank fixture.");
                    g.FillRectangle(Brushes.Firebrick, 45, 28, 42, 30);
                    detector.Detect(surface, observations);
                    if (observations.Count != 1 || observations[0].Kind != "red_cue") throw new InvalidOperationException("Fixture cue not detected.");
                    if (!new Rectangle(42, 26, 48, 34).Contains(observations[0].Box))
                        throw new InvalidOperationException("Fixture cue bounds are inaccurate.");
                    tracker.Update(observations, 0, results);
                    if (results.Count != 0) throw new InvalidOperationException("Unconfirmed cue emitted.");
                    g.Clear(Color.Navy);
                    g.FillRectangle(Brushes.Firebrick, 49, 30, 42, 30);
                    detector.Detect(surface, observations);
                    tracker.Update(observations, 70, results);
                    if (results.Count != 1) throw new InvalidOperationException("Moving cue lost.");
                    using (var renderer = new Overlay { Size = new Size(320, 200), Frame = surface })
                    using (var rendered = new Bitmap(320, 200))
                    {
                        renderer.Visible.Add(results[0]);
                        renderer.DrawToBitmap(rendered, new Rectangle(0, 0, 320, 200));
                        Rectangle bounds = results[0].Object.Box;
                        if (rendered.GetPixel(bounds.Left, bounds.Top + 4).ToArgb() != Overlay.TrackColor.ToArgb())
                            throw new InvalidOperationException("Preview did not draw a track border.");
                    }
                    int id = results[0].Id;
                    g.Clear(Color.Navy);
                    detector.Detect(surface, observations);
                    tracker.Update(observations, 120, results);
                    if (results.Count != 0) throw new InvalidOperationException("Missing cue still visible.");
                    g.FillRectangle(Brushes.Firebrick, 54, 30, 42, 30);
                    detector.Detect(surface, observations);
                    tracker.Update(observations, 180, results);
                    if (results.Count != 1 || results[0].Id != id) throw new InvalidOperationException("Track ID did not survive short occlusion.");
                    tracker.Update(observations, 600, results);
                    if (results.Count != 0) throw new InvalidOperationException("Stale track was accepted.");
                    tracker.Update(observations, 670, results);
                    if (results.Count != 1 || results[0].Id == id) throw new InvalidOperationException("Expired ID was reused.");
                }
                using (var independent = EventWaitHandle.OpenExisting(StopName + "_SelfTest")) independent.Set();
                if (!stop.WaitOne(0)) throw new InvalidOperationException("Independent stop signal was not delivered.");
            }
            if (!PreviewWindow.ShouldPublish("paused", "live", 0) ||
                PreviewWindow.ShouldPublish("paused", "paused", 9999) ||
                !PreviewWindow.ShouldPublish("live", "paused", 0) ||
                PreviewWindow.ShouldPublish("live", "live", 124) ||
                !PreviewWindow.ShouldPublish("live", "live", 125))
                throw new InvalidOperationException("Capture state transition publication regressed.");
            using (var source = new Surface(5, 3))
            using (var scaled = new Surface(3, 2))
            {
                if (!source.IsBlack()) throw new InvalidOperationException("Blank DIB was not detected.");
                Marshal.WriteInt32(source.Pixels, (5 + 3) * 4, 1);
                if (source.IsBlack()) throw new InvalidOperationException("Sparse, dim frame was rejected.");
                scaled.ScaleFrom(source);
                if (Marshal.ReadInt32(scaled.Pixels, (3 + 2) * 4) != 1)
                    throw new InvalidOperationException("CPU scale changed source-to-destination mapping.");
            }
            var pixels = Enumerable.Repeat((byte)255, 100 * 100 * 4).ToArray();
            PlayerDetector.MaskOverlay(pixels, 100, 100);
            if (pixels[0] != 0 || pixels[(23 * 100 + 17) * 4] != 0 || pixels[92 * 100 * 4] != 0 ||
                pixels[(23 * 100 + 18) * 4] != 255 || pixels[91 * 100 * 4] != 255)
                throw new InvalidOperationException("Player radar/HUD mask changed the active scene.");
            string root=Path.Combine(Path.GetTempPath(),"ReflexVision-Stop-"+Guid.NewGuid().ToString("N"));
            string bridge=Path.Combine(root,"data","bridge");
            string relay=Path.Combine(bridge,"reflexvision.json");
            string signal=Path.Combine(bridge,"global-stop.signal");
            Directory.CreateDirectory(bridge);
            try {
                using(var stop=new EventWaitHandle(false,EventResetMode.ManualReset)){
                    using(var form=new PreviewWindow(0,IntPtr.Zero,320,false,0,stop,relay,null,root)){
                        IntPtr handle=form.Handle;
                        File.WriteAllText(signal,"test");
                        form.CheckFrameForTest();
                        var report=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(relay));
                        if(!Object.Equals(report["status"],"stopped"))
                            throw new InvalidOperationException("Emergency signal did not publish a stopped relay.");
                    }
                }
            } finally {
                File.Delete(signal);File.Delete(relay);File.Delete(relay+".next");
                Directory.Delete(bridge);Directory.Delete(Path.Combine(root,"data"));Directory.Delete(root);
            }
            return "ReflexVision self-test passed: tracker, radar/HUD mask, independent stop and emergency relay.";
        }
    }

    internal sealed class BenchmarkScene : Form
    {
        private int frame;
        internal BenchmarkScene()
        {
            Text = "ReflexVision benchmark scene";
            ClientSize = new Size(800, 540);
            StartPosition = FormStartPosition.Manual;
            Location = new Point(40, 60);
            BackColor = Color.FromArgb(28, 41, 56);
            TopMost = true;
            DoubleBuffered = true;
        }
        internal void Advance() { frame++; Refresh(); }
        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (frame % 80 < 66) e.Graphics.FillRectangle(Brushes.Firebrick, 110 + frame % 80 * 2, 140, 82, 58);
            e.Graphics.DrawString("100", Font, Brushes.Gold, 40, Height * .91f);
        }
    }

    internal sealed class Overlay : Control
    {
        internal static readonly Color TrackColor = Color.FromArgb(203, 131, 255);
        internal Surface Frame;
        internal readonly List<Track> Visible = new List<Track>();
        internal Overlay() { DoubleBuffered = true; BackColor = Color.FromArgb(14, 20, 27); }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            if (Frame == null) return;
            float scale = Math.Min(ClientSize.Width / (float)Frame.Width, ClientSize.Height / (float)Frame.Height);
            var target = new RectangleF((ClientSize.Width - Frame.Width * scale) / 2,
                (ClientSize.Height - Frame.Height * scale) / 2, Frame.Width * scale, Frame.Height * scale);
            e.Graphics.DrawImage(Frame.Image, target);
            using (var border = new Pen(TrackColor))
            using (var label = new SolidBrush(TrackColor))
            foreach (var track in Visible)
            {
                Rectangle bounds = track.Object.Box;
                float x = target.X + bounds.X * scale, y = target.Y + bounds.Y * scale;
                e.Graphics.DrawRectangle(border, x, y, bounds.Width * scale, bounds.Height * scale);
                string kind = track.Object.Kind == "red_cue" ? "Scene cue" : track.Object.Kind.Replace("hud_", "HUD ");
                string text = kind + " #" + track.Id;
                if (!track.Object.Kind.StartsWith("hud_", StringComparison.Ordinal)) text += "  " + track.Object.Score.ToString("0.00");
                SizeF size = e.Graphics.MeasureString(text, Font);
                float labelX = Math.Max(target.Left, Math.Min(x, target.Right - size.Width));
                float labelY = Math.Max(target.Top, y - size.Height);
                e.Graphics.FillRectangle(Brushes.Black, labelX, labelY, Math.Min(size.Width, target.Right - labelX), size.Height);
                e.Graphics.DrawString(text, Font, label, labelX, labelY);
            }
        }
    }

    // One inference at a time. Copy the DIB before returning to the capture loop.
    internal sealed class PlayerDetector : IDisposable
    {
        private readonly Process child;
        private Task<double[][]> pending;
        private long submitted;
        private Size dimensions;
        internal long LastResult { get; private set; }

        private PlayerDetector(Process process) { child = process; }

        internal static PlayerDetector TryStart(string project)
        {
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ReflexCore", "vision");
            string script = Path.Combine(project, "tools", "reflexvision_players.py");
            if (!File.Exists(Path.Combine(root, "yolox_tiny.onnx")) || !File.Exists(script)) return null;
            try
            {
                return new PlayerDetector(Process.Start(new ProcessStartInfo {
                    FileName = "py.exe", Arguments = "-3 \"" + script + "\" \"" + root + "\"",
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true,
                    RedirectStandardOutput = true
                }));
            }
            catch (System.ComponentModel.Win32Exception) { return null; }
        }

        internal bool Update(Surface frame, long now, List<Detection> output)
        {
            if (child.HasExited) return false;
            if (pending != null)
            {
                if (!pending.IsCompleted) return now - submitted < 5000;
                if (pending.Status != TaskStatus.RanToCompletion) return false;
                if (now - submitted < 350 && dimensions == new Size(frame.Width, frame.Height))
                {
                    LastResult = now;
                    foreach (var box in pending.Result)
                    {
                        if (box.Length != 5 || box.Any(value => Double.IsNaN(value) || Double.IsInfinity(value))) continue;
                        if (box[0] < 0 || box[1] < 0 || box[2] < 1 || box[3] < 1 ||
                            box[0]+box[2] > frame.Width || box[1]+box[3] > frame.Height || box[4] < 0 || box[4] > 1) continue;
                        output.Add(new Detection("player", new Rectangle((int)box[0],(int)box[1],(int)box[2],(int)box[3]),(float)box[4]));
                    }
                }
                pending = null;
            }
            if (now - submitted < 82) return true;
            submitted = now;
            dimensions = new Size(frame.Width, frame.Height);
            int width = frame.Width, height = frame.Height;
            var pixels = new byte[width * height * 4];
            Marshal.Copy(frame.Pixels, pixels, 0, pixels.Length);
            MaskOverlay(pixels, width, height);
            pending = Task.Run(() =>
            {
                var input = new BinaryWriter(child.StandardInput.BaseStream);
                input.Write(width); input.Write(height); input.Write(pixels); input.Flush();
                string response = child.StandardOutput.ReadLine();
                if (response == "READY") response = child.StandardOutput.ReadLine();
                if (response == null || response.Length > 4096) throw new IOException("Invalid player detector response");
                return new JavaScriptSerializer().Deserialize<double[][]>(response) ?? new double[0][];
            });
            return true;
        }

        internal static void MaskOverlay(byte[] pixels, int width, int height)
        {
            // Keep the original image and coordinate space for the independent HUD detector.
            int radarBytes = width * 18 / 100 * 4;
            for (int y = 0; y < height * 24 / 100; y++)
                Array.Clear(pixels, y * width * 4, radarBytes);
            int hudStart = height * 92 / 100 * width * 4;
            Array.Clear(pixels, hudStart, pixels.Length - hudStart);
        }

        internal void Invalidate() { dimensions = Size.Empty; LastResult = 0; }

        public void Dispose()
        {
            try { if (!child.HasExited) child.Kill(); }
            catch (InvalidOperationException) {}
            catch (System.ComponentModel.Win32Exception) {}
            child.Dispose();
        }
    }

    internal sealed class PreviewWindow : Form
    {
        [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr handle, int id, uint modifiers, uint key);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr handle, int id);
        private const int StopHotkey = 6801;

        private readonly Overlay overlay = new Overlay();
        private readonly Label status = new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft };
        private readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 65 };
        private readonly GameCapture capture;
        private readonly IDetector detector = new ColorRegions();
        private PlayerDetector players;
        private readonly List<Detection> playerBoxes = new List<Detection>(16);
        private readonly Tracker playerTracker = new Tracker();
        private readonly List<Track> playerTracks = new List<Track>(16);
        private readonly Tracker tracker = new Tracker();
        private readonly List<Detection> detections = new List<Detection>(24);
        private readonly EventWaitHandle stop;
        private readonly string relay, globalStop;
        private readonly DateTime startedUtc = DateTime.UtcNow;
        private readonly bool cpu;
        private readonly int samples;
        private readonly BenchmarkScene fixture;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private readonly JavaScriptSerializer json = new JavaScriptSerializer();
        private readonly Process process = Process.GetCurrentProcess();
        private readonly List<double> latency = new List<double>();
        private double startedAt, finishedAt, startedCpu, finishedCpu;
        private long peakWorkingSet, workingSet;
        private int frames, framesWithTracks;
        private long sequence, lastPublish, lastPlayerResult, lastStatusUpdate;
        private string publishedMode;
        private Size lastFrameSize;
        private double frameCost;
        private bool finalized, hotkey;
        private Rectangle placed;
        internal void StartLobbyDetector(string project) { players = PlayerDetector.TryStart(project); }
        internal string LobbyLease { get; set; }

        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                var parameters = base.CreateParams;
                parameters.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE keeps the game in the foreground.
                return parameters;
            }
        }

        internal PreviewWindow(int pid, IntPtr hwnd, int width, bool cpuScale, int count, EventWaitHandle signal, string relayPath, BenchmarkScene synthetic, string project)
        {
            capture = new GameCapture(hwnd, (uint)pid, width, cpuScale, synthetic != null);
            // A loopback server and a foreground window do not prove the local client is in a match.
            // Keep live player inference disabled until a client scene source can confirm it.
            globalStop = synthetic == null ? Path.Combine(project, "data", "bridge", "global-stop.signal") : null;
            cpu = cpuScale; stop = signal; relay = relayPath; samples = count; fixture = synthetic;
            Text = "ReflexVision - live preview";
            TopMost = true; StartPosition = FormStartPosition.Manual;
            ClientSize = new Size(384, 300);
            MinimumSize = new Size(260, 220);
            BackColor = Color.FromArgb(23, 32, 43); ForeColor = Color.White;
            var footer = new Panel { Dock = DockStyle.Bottom, Height = 40, Padding = new Padding(8) };
            var cancel = new Button { Text = "Stop Capture", Dock = DockStyle.Right, Width = 105, ForeColor = Color.Black };
            cancel.Click += (sender, args) => Close();
            footer.Controls.Add(status);
            footer.Controls.Add(cancel);
            if (synthetic == null) {
                var focus = new Button { Text = "Focus game", Dock = DockStyle.Right, Width = 85, ForeColor = Color.Black };
                focus.Click += (sender, args) => capture.FocusGame();
                footer.Controls.Add(focus);
            }
            overlay.Dock = DockStyle.Fill;
            Controls.Add(overlay);
            Controls.Add(footer);
            CaptureBounds();
            if (relay != null)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(relay));
                Publish("paused", null);
            }
            Shown += (sender, args) =>
            {
                hotkey = RegisterHotKey(Handle, StopHotkey, 0x4003, 0x79);
                if (samples > 0 && !String.IsNullOrEmpty(LobbyLease)) capture.FocusGame();
                timer.Start();
            };
            timer.Tick += (sender, args) => OnFrame();
        }

        protected override void WndProc(ref Message message)
        {
            if (message.Msg == 0x0312 && message.WParam.ToInt32() == StopHotkey)
            {
                try
                {
                    if (globalStop != null)
                    {
                        Directory.CreateDirectory(Path.GetDirectoryName(globalStop));
                        File.WriteAllText(globalStop, DateTime.UtcNow.ToString("o"));
                    }
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
                Close();
            }
            base.WndProc(ref message);
        }

        // Keep the preview outside the capture rectangle. Only the foreground game is sampled.
        private Rectangle CaptureBounds()
        {
            Rectangle game = capture.Bounds();
            if (game.IsEmpty) return Rectangle.Empty;
            if (placed != game || Bounds.IntersectsWith(game))
            {
                Rectangle screen = Screen.FromRectangle(game).WorkingArea;
                int right = screen.Right - game.Right;
                int left = game.Left - screen.Left;
                int slot = Math.Max(left, right) - 14;
                if (slot >= MinimumSize.Width)
                {
                    Width = Math.Min(410, slot);
                    Left = right >= left ? game.Right + 7 : game.Left - Width - 7;
                    Top = Math.Max(screen.Top, Math.Min(game.Top, screen.Bottom - Height));
                }
                else
                {
                    int bottom = screen.Bottom - game.Bottom;
                    int top = game.Top - screen.Top;
                    int vertical = Math.Max(bottom, top) - 14;
                    if (vertical >= MinimumSize.Height)
                    {
                        Height = Math.Min(340, vertical);
                        Top = bottom >= top ? game.Bottom + 7 : game.Top - Height - 7;
                        Left = screen.Left + 8;
                    }
                }
                placed = game;
            }
            return Bounds.IntersectsWith(game) ? Rectangle.Empty : game;
        }

        internal void CheckFrameForTest() { OnFrame(); }

        private void OnFrame()
        {
            if (stop.WaitOne(0) || (samples > 0 && clock.Elapsed.TotalSeconds > 55)) { Close(); return; }
            try
            {
                if (globalStop != null && File.GetLastWriteTimeUtc(globalStop) >= startedUtc) { Close(); return; }
                if (!String.IsNullOrEmpty(LobbyLease) && File.GetLastWriteTimeUtc(LobbyLease) < DateTime.UtcNow.AddSeconds(-3)) { Close(); return; }
                if (fixture != null) fixture.Advance();
                var frameStart = Stopwatch.GetTimestamp();
                long frameUnixMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                Surface surface = capture.Grab(CaptureBounds());
                if (surface == null)
                {
                    if (overlay.Frame != null)
                    {
                        overlay.Frame = null;
                        overlay.Visible.Clear();
                        ResetTracking();
                        frameCost = 0;
                        overlay.Invalidate();
                    }
                    if (status.Text != capture.LastPause) status.Text = capture.LastPause;
                    timer.Interval = 180;
                    if (relay != null && ShouldPublish("paused", publishedMode, clock.ElapsedMilliseconds - lastPublish))
                        Publish("paused", null);
                    return;
                }

                var size = new Size(surface.Width, surface.Height);
                if (size != lastFrameSize)
                {
                    ResetTracking();
                    lastFrameSize = size;
                    lastStatusUpdate = clock.ElapsedMilliseconds - 250;
                }
                detector.Detect(surface, detections);
                tracker.Update(detections, clock.ElapsedMilliseconds, overlay.Visible);
                if (players != null)
                {
                    playerBoxes.Clear();
                    if (!players.Update(surface, clock.ElapsedMilliseconds, playerBoxes))
                    {
                        players.Dispose(); players = null;
                        playerTracks.Clear();
                    }
                    else if (players.LastResult != lastPlayerResult)
                    {
                        lastPlayerResult = players.LastResult;
                        playerTracker.Update(playerBoxes, lastPlayerResult, playerTracks);
                    }
                    else if (clock.ElapsedMilliseconds - lastPlayerResult > 250) playerTracks.Clear();
                    overlay.Visible.AddRange(playerTracks);
                }
                overlay.Frame = surface;
                overlay.Refresh();
                double elapsed = (Stopwatch.GetTimestamp() - frameStart) * 1000.0 / Stopwatch.Frequency;
                frames++;
                if (samples > 0)
                {
                    timer.Interval = 50;
                    if (frames == 8) { startedAt = clock.Elapsed.TotalMilliseconds; startedCpu = process.TotalProcessorTime.TotalMilliseconds; }
                    if (frames > 8)
                    {
                        latency.Add(elapsed);
                        if (overlay.Visible.Count > 0) framesWithTracks++;
                        if (latency.Count >= samples) { finalized = true; Close(); return; }
                    }
                }
                else
                {
                    frameCost = frameCost == 0 ? elapsed : frameCost * .8 + elapsed * .2;
                    bool throttled = timer.Interval == 125 ? frameCost >= 16 : frameCost > 24;
                    timer.Interval = throttled ? 125 : detections.Count > 0 ? 65 : 100;
                }

                if (relay != null && ShouldPublish("live", publishedMode, clock.ElapsedMilliseconds - lastPublish))
                    Publish("live", surface, frameUnixMs);
                if (!finalized && clock.ElapsedMilliseconds - lastStatusUpdate >= 250)
                {
                    lastStatusUpdate = clock.ElapsedMilliseconds;
                    status.Text = (!String.IsNullOrEmpty(LobbyLease) ? (players == null ? "Lobby Â· player detector unavailable" : "Lobby Â· visual player candidates") : players == null ? "Color / HUD Â· player scene unverified" : "YOLOX players + HUD") + " | " + elapsed.ToString("0.0") + " ms" +
                        (hotkey ? " | Ctrl+Alt+F10" : "");
                }
            }
            catch (InvalidOperationException) { Close(); }
            catch (System.ComponentModel.Win32Exception) { Close(); }
        }

        private void ResetTracking()
        {
            tracker.Clear();
            playerTracker.Clear();
            playerTracks.Clear();
            lastFrameSize = Size.Empty;
            lastPlayerResult = 0;
            if (players != null) players.Invalidate();
        }

        internal static bool ShouldPublish(string next, string published, long elapsed)
        {
            return next != published || (next == "live" && elapsed >= 125);
        }

        private void Publish(string mode, Surface image, long captured = 0)
        {
            string temporary = relay + ".next";
            try
            {
                var objects = image == null ? new object[0] : overlay.Visible.Where(track => track.Object.Kind != "player").Select(track => (object)new
                {
                    id = track.Id, kind = track.Object.Kind, confidence = track.Object.Score,
                    x = track.Object.Box.X, y = track.Object.Box.Y,
                    width = track.Object.Box.Width, height = track.Object.Box.Height
                }).ToArray();
                File.WriteAllText(temporary, json.Serialize(new
                {
                    schema = "reflexcore.vision.v1", sequence = ++sequence, status = mode,
                    captured_unix_ms = image == null ? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() : captured,
                    width = image == null ? 0 : image.Width, height = image == null ? 0 : image.Height, objects = objects
                }));
                if (File.Exists(relay)) File.Replace(temporary, relay, null);
                else File.Move(temporary, relay);
                publishedMode = mode;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            finally { lastPublish = clock.ElapsedMilliseconds; }
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            timer.Stop();
            if (hotkey) UnregisterHotKey(Handle, StopHotkey);
            if (relay != null) Publish("stopped", null);
            finishedAt = clock.Elapsed.TotalMilliseconds;
            process.Refresh();
            finishedCpu = process.TotalProcessorTime.TotalMilliseconds;
            peakWorkingSet = process.PeakWorkingSet64;
            workingSet = process.WorkingSet64;
            overlay.Frame = null;
            base.OnFormClosed(e);
        }

        private static double Percentile(List<double> sorted, double fraction)
        {
            return sorted.Count == 0 ? 0 : Math.Round(sorted[(int)Math.Ceiling(sorted.Count * fraction) - 1], 2);
        }

        internal string Report()
        {
            if (samples <= 0) return "";
            latency.Sort();
            double interval = finishedAt - startedAt;
            return json.Serialize(new
            {
                schema = "reflexcore.vision.benchmark.v1",
                source = fixture != null ? "visible_fixture" : "cs16",
                capture = cpu ? "gdi_copy_cpu_scale" : "gdi_scaled_blit",
                completed = finalized, pause_reason = capture.LastPause, frames = latency.Count, frames_with_tracks = framesWithTracks,
                fps = interval > 0 && latency.Count > 0 ? Math.Round(latency.Count * 1000 / interval, 2) : 0,
                p50_ms = Percentile(latency, .5), p95_ms = Percentile(latency, .95),
                process_cpu_core_pct = interval > 0 && latency.Count > 0 ? Math.Round((finishedCpu - startedCpu) * 100 / interval, 2) : 0,
                process_peak_mib = Math.Round(peakWorkingSet / 1048576.0, 2),
                process_working_set_mib = Math.Round(workingSet / 1048576.0, 2),
                inference_gpu_backend = false
            });
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) { timer.Dispose(); capture.Dispose(); process.Dispose(); if (players != null) players.Dispose(); }
            base.Dispose(disposing);
        }
    }
}
