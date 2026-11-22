// ReflexCore UnifiedShell Preview 1: UI-only adapter; no zxcLagLab code is claimed as imported.
// Explicit finite status enums. No private UI text, screenshots, API keys or prompts are persisted.
using System;
using System.Collections.Generic;
using System.IO;
using System.Drawing;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace ReflexCore.Control
{
    // TCM_ADJUSTRECT keeps the already-working TabPages, but removes their dated tab strip.
    internal sealed class ReflexTabHost : TabControl
    {
        public ReflexTabHost()
        {
            TabStop = false;
            Multiline = false;
            SizeMode = TabSizeMode.Fixed;
            ItemSize = new Size(1, 1);
        }
        protected override void WndProc(ref Message m)
        {
            // Native WinForms keeps the content rectangle below tabs unless we override this.
            if (m.Msg == 0x1328 && !DesignMode)
            {
                m.Result = (IntPtr)1;
                return;
            }
            base.WndProc(ref m);
        }
    }

    public sealed class ShellModernizer
    {
        private readonly Form host;
        private readonly TabControl tabs;
        private readonly Panel oldHeader;
        private readonly Dictionary<TabPage, Button> links = new Dictionary<TabPage, Button>();
        private Color background, side, panel, ink, dim, green, selectedBg, border, hover;
        private ReflexImportedTheme theme;
        private TableLayoutPanel surface;
        private Panel top, sidebar, content, footer;
        private FlowLayoutPanel nav;
        private Label heading, subheading, brand, safeNote, stageLabel, routeLabel, bridgeLabel;
        private ComboBox themePicker;
        private Button collapseButton;
        private Panel separator;
        private bool collapsed;
        private System.Windows.Forms.Timer heartbeat;
        private readonly string root;

        private ShellModernizer(Form form, TabControl tabControl, Panel legacyHeader, string projectRoot)
        {
            host = form; tabs = tabControl; oldHeader = legacyHeader; root = projectRoot;
            SetThemeColors(ReflexThemeCatalog.Load());
        }

        private static Color Blend(Color a, Color b, double bWeight)
        {
            double x = Math.Max(0, Math.Min(1, bWeight));
            return Color.FromArgb((int)(a.R * (1-x) + b.R * x),
                                  (int)(a.G * (1-x) + b.G * x),
                                  (int)(a.B * (1-x) + b.B * x));
        }
        private void SetThemeColors(ReflexImportedTheme next)
        {
            theme = next;
            background = next.Bg;
            side = next.Dark ? Blend(next.Bg, next.Card, 0.45) : next.Card;
            panel = next.Card;
            ink = next.Text;
            dim = next.Sub;
            green = next.Accent;
            selectedBg = Blend(next.Card, next.Accent, next.Dark ? 0.26 : 0.15);
            border = next.Track;
            hover = Blend(next.Card, next.Accent, 0.16);
        }
        private void ApplyTheme(ReflexImportedTheme next, bool persist)
        {
            SetThemeColors(next);
            if (surface != null) surface.BackColor = background;
            host.BackColor = background;
            if (top != null) top.BackColor = side;
            if (sidebar != null) sidebar.BackColor = side;
            if (content != null) content.BackColor = background;
            if (footer != null) footer.BackColor = side;
            if (nav != null) nav.BackColor = side;
            tabs.BackColor = background;
            tabs.ForeColor = ink;
            foreach (TabPage page in tabs.TabPages) {
                page.BackColor = background;
                page.ForeColor = ink;
            }
            if (heading != null) heading.ForeColor = green;
            if (subheading != null) subheading.ForeColor = dim;
            if (brand != null) brand.ForeColor = dim;
            if (safeNote != null) safeNote.ForeColor = dim;
            if (stageLabel != null) stageLabel.ForeColor = green;
            if (bridgeLabel != null) bridgeLabel.ForeColor = dim;
            if (routeLabel != null) routeLabel.ForeColor = dim;
            if (collapseButton != null) {
                collapseButton.BackColor = panel;
                collapseButton.ForeColor = ink;
                collapseButton.FlatAppearance.BorderColor = border;
            }
            if (separator != null) separator.BackColor = border;
            if (themePicker != null) {
                themePicker.BackColor = panel;
                themePicker.ForeColor = ink;
            }
            SelectCurrent();
            // Theme is changed by the user only. No updates in the 1.4 s telemetry poll.
            if (persist) {
                try { ReflexThemeCatalog.Save(next); }
                catch (IOException) { /* Theme choice still applies to this session. */ }
                catch (UnauthorizedAccessException) { /* Settings path is not writable. */ }
            }
        }

        internal static void Attach(Form form, TabControl pages, Panel legacyHeader, string projectRoot)
        {
            if (form == null || pages == null || legacyHeader == null) throw new ArgumentNullException("shell");
            if (pages.TabPages.Count != 6) throw new InvalidOperationException("UnifiedShell expects the six existing Control Center pages.");
            new ShellModernizer(form, pages, legacyHeader, projectRoot).Build();
        }

        private static Label Text(string s, int size, bool heavy, Color color)
        {
            return new Label
            {
                Text = s, AutoSize = false, TextAlign = ContentAlignment.MiddleLeft,
                Font = new Font(heavy ? "Consolas" : "Segoe UI", size, heavy ? FontStyle.Bold : FontStyle.Regular),
                ForeColor = color, BackColor = Color.Transparent
            };
        }

        private void Build()
        {
            host.SuspendLayout();
            try
            {
                host.Controls.Remove(oldHeader);
                host.Controls.Remove(tabs);
                oldHeader.Dispose();

                surface = new TableLayoutPanel
                {
                    Dock = DockStyle.Fill, BackColor = background, ColumnCount = 2,
                    RowCount = 3, Margin = new Padding(0), Padding = new Padding(0)
                };
                surface.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 226));
                surface.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
                surface.RowStyles.Add(new RowStyle(SizeType.Absolute, 88));
                surface.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
                surface.RowStyles.Add(new RowStyle(SizeType.Absolute, 41));
                host.Controls.Add(surface);

                top = new Panel { Dock = DockStyle.Fill, BackColor = side, Margin = new Padding(0) };
                surface.Controls.Add(top, 0, 0); surface.SetColumnSpan(top, 2);
                heading = Text("REFLEXCORE", 23, true, green);
                heading.SetBounds(25, 12, 360, 39); top.Controls.Add(heading);
                subheading = Text("COGNITIVE RUNTIME   /   UNIFIED CONTROL", 9, false, dim);
                subheading.SetBounds(27, 49, 500, 23); top.Controls.Add(subheading);
                stageLabel = Text("STAGE  /  IDLE", 10, true, green);
                stageLabel.AutoEllipsis = true;
                stageLabel.SetBounds(0, 25, 220, 34); top.Controls.Add(stageLabel);
                themePicker = new ComboBox {
                    DropDownStyle = ComboBoxStyle.DropDownList,
                    Width = 195, Height = 27, FlatStyle = FlatStyle.Flat,
                    BackColor = panel, ForeColor = ink,
                    Font = new Font("Segoe UI", 9, FontStyle.Regular),
                    IntegralHeight = false, MaxDropDownItems = 15
                };
                foreach (var item in ReflexThemeCatalog.All) themePicker.Items.Add(item.Name);
                themePicker.SelectedItem = theme.Name;
                themePicker.SelectedIndexChanged += delegate(object sender, EventArgs e) {
                    ApplyTheme(ReflexThemeCatalog.Find(themePicker.SelectedItem as string), true);
                };
                top.Controls.Add(themePicker);
                var tip = new ToolTip();
                tip.SetToolTip(themePicker, "Original zxcLagLab 2.2 theme palettes. Shell only; existing functional panels are preserved.");
                top.Resize += delegate(object sender, EventArgs e) {
                    stageLabel.Left = Math.Max(540, top.ClientSize.Width - 220);
                    themePicker.Left = Math.Max(360, top.ClientSize.Width - 448);
                    themePicker.Top = 30;
                };
                // Layout positions are recalculated after the host is shown.
                stageLabel.Left = Math.Max(540, host.ClientSize.Width - 220);
                themePicker.Left = Math.Max(360, host.ClientSize.Width - 448);
                themePicker.Top = 30;

                sidebar = new Panel { BackColor = side, Dock = DockStyle.Fill, Margin = new Padding(0) };
                surface.Controls.Add(sidebar, 0, 1);
                brand = Text("WORKSPACE", 10, true, dim);
                brand.SetBounds(19, 17, 190, 26); sidebar.Controls.Add(brand);
                nav = new FlowLayoutPanel
                {
                    Dock = DockStyle.Fill, AutoScroll = true, WrapContents = false,
                    FlowDirection = FlowDirection.TopDown, Padding = new Padding(9, 55, 8, 12),
                    Margin = new Padding(0), BackColor = side
                };
                sidebar.Controls.Add(nav); brand.BringToFront();
                collapseButton = new Button {
                    Text = "<<", Width = 34, Height = 25, Left = 178, Top = 16,
                    FlatStyle = FlatStyle.Flat, TabStop = false,
                    BackColor = panel, ForeColor = ink,
                    Font = new Font("Consolas", 9, FontStyle.Bold)
                };
                collapseButton.FlatAppearance.BorderColor = border;
                collapseButton.Click += delegate(object sender, EventArgs e) { ToggleSidebar(); };
                sidebar.Controls.Add(collapseButton); collapseButton.BringToFront();

                AddLink(nav, tabs.TabPages[0], "01   АГЕНТ", "Задачи и управление");
                AddLink(nav, tabs.TabPages[1], "02   МОДЕЛИ", "Локальный Ollama");
                AddLink(nav, tabs.TabPages[2], "03   ДИАГНОСТИКА", "CPU / GPU / задержки");
                AddLink(nav, tabs.TabPages[3], "04   SHARED CONTROL", "Windows / CS16");
                AddLink(nav, tabs.TabPages[4], "05   CITADEL LAB", "Игровой полигон");
                AddLink(nav, tabs.TabPages[5], "06   OPENAI API", "Внешний backend");
                separator = new Panel { Width = 198, Height = 1, BackColor = Color.FromArgb(52, 75, 77), Margin = new Padding(5, 18, 3, 15) };
                nav.Controls.Add(separator);
                safeNote = Text("LOCAL FIRST  /  STOP: CTRL+ALT+P", 8, false, dim);
                safeNote.Width = 206; safeNote.Height = 45;safeNote.Margin = new Padding(8, 0, 0, 0);
                nav.Controls.Add(safeNote);

                content = new Panel { Dock = DockStyle.Fill, Padding = new Padding(14, 12, 14, 10), Margin = new Padding(0), BackColor = background };
                surface.Controls.Add(content, 1, 1);
                tabs.Dock = DockStyle.Fill; tabs.BackColor = background; tabs.ForeColor = ink;
                tabs.TabStop = false;
                tabs.Appearance = TabAppearance.FlatButtons;
                tabs.ItemSize = new Size(1, 1);
                tabs.SizeMode = TabSizeMode.Fixed;
                content.Controls.Add(tabs);
                foreach (TabPage page in tabs.TabPages)
                {
                    page.AutoScroll = true; page.Padding = new Padding(0);
                    page.BackColor = background; page.ForeColor = ink;
                }
                tabs.SelectedIndexChanged += delegate(object sender, EventArgs e) { SelectCurrent(); };
                SelectCurrent();

                footer = new Panel { Dock = DockStyle.Fill, BackColor = side, Margin = new Padding(0) };
                surface.Controls.Add(footer, 0, 2); surface.SetColumnSpan(footer, 2);
                bridgeLabel = Text("BRIDGE  /  CHECKING", 9, true, dim);
                bridgeLabel.SetBounds(19, 3, 315, 32); footer.Controls.Add(bridgeLabel);
                routeLabel = Text("SINGLE WINDOW  /  PRIVATE BY DEFAULT", 9, false, dim);
                routeLabel.Anchor = AnchorStyles.Top | AnchorStyles.Right;
                routeLabel.SetBounds(340, 3, 510, 32); footer.Controls.Add(routeLabel);
                footer.Resize += delegate(object sender, EventArgs e)
                {
                    routeLabel.Left = Math.Max(340, footer.ClientSize.Width - routeLabel.Width - 23);
                };

                ApplyTheme(theme, false);
                SelectCurrent();
                heartbeat = new System.Windows.Forms.Timer { Interval = 1400 };
                heartbeat.Tick += delegate(object sender, EventArgs e) { RefreshTelemetry(); };
                host.FormClosed += delegate(object sender, FormClosedEventArgs e)
                {
                    heartbeat.Stop(); heartbeat.Dispose();
                };
                heartbeat.Start(); RefreshTelemetry();
            }
            finally { host.ResumeLayout(true); }
        }

        private void AddLink(FlowLayoutPanel nav, TabPage page, string caption, string detail)
        {
            var btn = new Button
            {
                Text = caption + "\n" + detail,
                TextAlign = ContentAlignment.MiddleLeft,
                Width = 196, Height = 60,
                Font = new Font("Segoe UI", 10, FontStyle.Regular),
                BackColor = panel, ForeColor = ink, FlatStyle = FlatStyle.Flat,
                Margin = new Padding(5, 0, 2, 7), Padding = new Padding(9, 0, 0, 0),
                TabStop = false, UseVisualStyleBackColor = false
            };
            btn.FlatAppearance.BorderColor = Color.FromArgb(45, 69, 70);
            btn.FlatAppearance.MouseOverBackColor = Color.FromArgb(32, 49, 50);
            btn.Click += delegate(object sender, EventArgs e) { tabs.SelectedTab = page; };
            btn.Tag = caption + "\n" + detail;
            btn.FlatAppearance.MouseOverBackColor = hover;
            nav.Controls.Add(btn); links.Add(page, btn);
        }
        private void ToggleSidebar()
        {
            collapsed = !collapsed;
            surface.SuspendLayout();
            try {
                surface.ColumnStyles[0].Width = collapsed ? 76 : 226;
                if (brand != null) brand.Visible = !collapsed;
                if (safeNote != null) safeNote.Visible = !collapsed;
                if (separator != null) separator.Width = collapsed ? 56 : 198;
                nav.Padding = collapsed ? new Padding(5, 55, 4, 8) : new Padding(9, 55, 8, 12);
                collapseButton.Left = collapsed ? 23 : 178;
                collapseButton.Text = collapsed ? ">>" : "<<";
                foreach (var item in links) {
                    var button = item.Value;
                    button.Width = collapsed ? 54 : 196;
                    button.Height = collapsed ? 47 : 60;
                    button.Padding = collapsed ? new Padding(0) : new Padding(9, 0, 0, 0);
                    button.Margin = collapsed ? new Padding(4, 0, 0, 5) : new Padding(5, 0, 2, 7);
                    button.TextAlign = collapsed ? ContentAlignment.MiddleCenter : ContentAlignment.MiddleLeft;
                    string full = button.Tag as string ?? "";
                    button.Text = collapsed ? full.Substring(0, Math.Min(2, full.Length)) : full;
                }
            } finally { surface.ResumeLayout(true); }
        }
        private void SelectCurrent()
        {
            foreach (KeyValuePair<TabPage, Button> item in links)
            {
                bool selected = item.Key == tabs.SelectedTab;
                item.Value.BackColor = selected ? selectedBg : panel;
                item.Value.ForeColor = selected ? green : ink;
                item.Value.FlatAppearance.BorderColor = selected ? green : border;
                item.Value.FlatAppearance.MouseOverBackColor = hover;
            }
            if (routeLabel != null && tabs.SelectedTab != null)
                routeLabel.Text = "ACTIVE VIEW  /  " + tabs.SelectedTab.Text.ToUpperInvariant();
        }

        // Same strict public activity schema and freshness rules as the existing tray.
        private static string Enum(string json, string name)
        {
            Match match = Regex.Match(json, "\"" + Regex.Escape(name) + "\"\\s*:\\s*\"([a-z0-9_.-]{1,40})\"");
            return match.Success ? match.Groups[1].Value : "";
        }
        private static string StageLabel(string s)
        {
            switch (s)
            {
                case "ready": return "READY";
                case "observing": return "OBSERVING";
                case "capturing": return "CAPTURING";
                case "thinking": return "INFERENCE";
                case "deciding": return "PLANNING";
                case "awaiting_effect": return "WAITING FOR EFFECT";
                case "executing": return "EXECUTING";
                case "verifying": return "VERIFYING";
                case "verified": return "VERIFIED";
                case "human_override": return "HUMAN OVERRIDE";
                case "completed": return "COMPLETED";
                case "failed": return "FAILED";
                case "stopped": return "STOPPED";
                default: return "";
            }
        }
        internal static string CurrentStage()
        {

            string activity = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ReflexCore", "runtime", "activity.json");
            try
            {
                if (File.Exists(activity))
                {
                    var bytes = new FileInfo(activity);
                    if (bytes.Length <= 2048)
                    {
                        string json = File.ReadAllText(activity);
                        if (Enum(json, "schema") == "reflexcore.activity.v1")
                        {
                            string source = Enum(json, "source");
                            string stage = StageLabel(Enum(json, "stage"));
                            Match stamp = Regex.Match(json, "\"at_utc\"\\s*:\\s*\"([^\"]{1,40})\"");
                            DateTime at;
                            if ((source == "citadel_rust" || source == "shared_control" || source == "vision_loop") && stage.Length > 0 &&
                                stamp.Success && DateTime.TryParse(stamp.Groups[1].Value,
                                System.Globalization.CultureInfo.InvariantCulture,
                                System.Globalization.DateTimeStyles.RoundtripKind, out at))
                            {
                                double age = (DateTime.UtcNow - at.ToUniversalTime()).TotalSeconds;
                                if (age >= -10 && age <= 65) return stage;
                            }
                        }
                    }
                }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            return "IDLE";
        }
        private void RefreshTelemetry()
        {
            if(host.IsDisposed)return;
            stageLabel.Text="STAGE  /  "+CurrentStage();
            try
            {
                string path = Path.Combine(root, "data", "bridge", "status.json");
                string status = "OFFLINE";
                if (File.Exists(path) && new FileInfo(path).Length <= 2048)
                {
                    string raw = File.ReadAllText(path);
                    string state = Enum(raw, "state");
                    if (state == "running" || state == "idle" || state == "stopped" || state == "failed" || state == "error")
                        status = state.ToUpperInvariant();
                }
                bridgeLabel.Text = "BRIDGE  /  " + status;
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }

        public static void SelfTest()
        {
            if (StageLabel("thinking") != "INFERENCE" || StageLabel("untrusted_window_title") != "")
                throw new Exception("Status enum regression");
            if (Enum("{\"schema\":\"reflexcore.activity.v1\"}", "schema") != "reflexcore.activity.v1")
                throw new Exception("Activity parser regression");
            if (Enum("{\"stage\":\"<raw private text>\"}", "stage") != "")
                throw new Exception("Private status rejection regression");
            ReflexThemeCatalog.SelfTest();
            Console.WriteLine("[ReflexCore] UnifiedShell enum parser and theme integration tests passed.");
        }
    }
}
