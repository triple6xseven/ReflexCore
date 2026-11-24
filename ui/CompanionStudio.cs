using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;

namespace ReflexCore.Studio;

public sealed partial class StudioWindow
{
    readonly ScrollViewer widgets = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    readonly Dictionary<string, object> widgetDefaults = WidgetSettings.Defaults();
    Dictionary<string, object> widgetDraft;
    readonly HashSet<string> changedWidgetKeys = new(StringComparer.Ordinal);
    TextBlock classicStatus, companionStatus, widgetFeedback, characterEditorStatus;
    readonly DispatcherTimer widgetSave = new() { Interval = TimeSpan.FromMilliseconds(180) };
    int widgetSection;

    void BuildWidgets()
    {
        widgetDraft = WidgetSettings.Load();
        widgetSave.Tick += (_, _) => ApplyWidgetChanges();
        new SmoothWheel(widgets, () => smooth, () => 210);
        LayoutWidgets();
    }

    void LayoutWidgets()
    {
        var page = new StackPanel { Margin = new Thickness(22, 18, 22, 26) };
        widgets.Content = page;
        widgetFeedback = WidgetHint("Settings save automatically.");
        page.Children.Add(widgetFeedback);
        var toolbar = new WrapPanel { Margin = new Thickness(0, 0, 0, 10) };
        page.Children.Add(toolbar);
        var panels = new[] { new StackPanel(), new StackPanel(), new StackPanel(), new StackPanel(), new StackPanel(), new StackPanel() };
        var names = new[] { "Character", "Editor", "Movement", "Classic", "Advanced", "Dev" };
        var tabs = new List<Button>();
        Action reloadWardrobe = null;
        void Select(int index)
        {
            widgetSection=index;
            for(int i=0;i<panels.Length;i++)
            {
                panels[i].Visibility=i==index ? Visibility.Visible : Visibility.Collapsed;
                tabs[i].SetResourceReference(Control.BorderBrushProperty,i==index ? "Accent" : "PanelOutline");
            }
            if (index == 1) reloadWardrobe?.Invoke();
            widgets.ScrollToTop();
        }
        for(int i=0;i<names.Length;i++)
        {
            int index=i;
            var tab=Command(names[i],()=>Select(index));
            tab.Margin=new Thickness(0,0,8,5);
            tabs.Add(tab);
            toolbar.Children.Add(tab);
            page.Children.Add(panels[i]);
        }
        var dev = Section(panels[5], "Animation preview");
        var previewStatus = WidgetHint("Start the companion, then click a pose to preview it on the desktop.");
        dev.Children.Add(previewStatus);
        void Preview(string pose)
        {
            var runtime = WidgetSettings.Read(Path.Combine(WidgetSettings.Folder, "status.json"));
            int pid = (int)WidgetSettings.Number(runtime, "pid", 0);
            if (pid <= 0 || !WidgetSettings.Bool(runtime, "ready") || !WidgetSettings.Bool(runtime, "running"))
            {
                previewStatus.Text = "Open the companion first.";
                return;
            }
            try
            {
                var request = new { pid, pose, token = Guid.NewGuid().ToString("N"),
                    at = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() };
                string json = new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(request);
                WidgetSettings.Write(Path.Combine(WidgetSettings.Folder, "animation-preview.json"), json);
                previewStatus.Text = pose == "stop" ? "Resume requested." : "Preview requested.";
            }
            catch (IOException) { previewStatus.Text = "Could not send preview. Try again."; }
            catch (UnauthorizedAccessException) { previewStatus.Text = "Preview file is unavailable."; }
        }
        WidgetButtons(dev, ("Show 3D", () => SendWidgetCommand("start-3d")), ("Resume behavior", () => Preview("stop")));
        WidgetButtons(Section(dev, "Movement"),
            ("Idle", () => Preview("idle")), ("Walk", () => Preview("walk")), ("Run", () => Preview("run")),
            ("Hover", () => Preview("hover")), ("Drag", () => Preview("dragged")),
            ("Throw", () => Preview("thrown")), ("Landing", () => Preview("landing")));
        WidgetButtons(Section(dev, "Seating"),
            ("Window sit", () => Preview("sit")), ("Cloud summon", () => Preview("cloud_summon")),
            ("Cloud sit cycle", () => Preview("cloud_sit")));
        WidgetButtons(Section(dev, "Reactions"),
            ("Head pat", () => Preview("petted")), ("Smile", () => Preview("face_smile")),
            ("Tickle", () => Preview("tickled")), ("Think", () => Preview("thinking")),
            ("Work", () => Preview("working")), ("Celebrate", () => Preview("happy")));
        var classic = Section(panels[3], "Classic Live Status");
        classicStatus = WidgetHint("Waiting for tray status.");
        classic.Children.Add(classicStatus);
        WidgetButtons(classic,
            ("Show Classic", () => SendWidgetCommand("show-classic")),
            ("Hide Classic", () => SendWidgetCommand("hide-classic", false)),
            ("Reset position", () => SendWidgetCommand("reset-classic-position", false)));
        WidgetNumber(classic, "Opacity", "classic_opacity", 40, 100, "%", 100);
        WidgetToggle(classic, "CPU & system memory", "classic_host");
        WidgetToggle(classic, "GPU & video memory", "classic_gpu");
        WidgetToggle(classic, "Show graphics card names", "classic_gpu_names");
        WidgetToggle(classic, "Ollama throughput", "classic_ollama");

        var companionHost = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
        panels[0].Children.Add(companionHost);
        var companion = Section(companionHost, "ReflexCompanion 3D");
        companionStatus = WidgetHint("Waiting for tray status.");
        companion.Children.Add(companionStatus);
        WidgetButtons(companion,
            ("Show 3D", () => SendWidgetCommand("start-3d")),
            ("Stop", () => SendWidgetCommand("stop-3d", false)),
            ("Restart", () => SendWidgetCommand("restart-3d")));

        var modelRow = new DockPanel { LastChildFill = true, Margin = new Thickness(0, 8, 0, 8) };
        var modelLabel = Label("", 13);
        modelLabel.TextTrimming = TextTrimming.CharacterEllipsis;
        void DescribeModel()
        {
            string path = WidgetSettings.String(widgetDraft, "model");
            bool custom = WidgetSettings.String(widgetDraft, "edition") == "custom";
            modelLabel.Text = custom ? "Using the character editor" : path.Length == 0 ? "Default avatar" : Path.GetFileName(path);
            modelLabel.ToolTip = custom || path.Length == 0 ? null : path;
        }
        Action updateModelControls = DescribeModel;
        var pick = Command("Choose model…", () =>
        {
            var dialog = new OpenFileDialog
            {
                Title = "Choose a rigged avatar", Filter = "VRM or GLB avatar (*.vrm;*.glb)|*.vrm;*.glb",
                CheckFileExists = true, Multiselect = false
            };
            if (dialog.ShowDialog(this) != true) return;
            string selected = dialog.FileName;
            if (selected.Length > 1024 || selected.Length < 4 || selected[1] != ':' ||
                !new[] { ".vrm", ".glb" }.Contains(Path.GetExtension(selected), StringComparer.OrdinalIgnoreCase))
            {
                widgetFeedback.Text = "Choose a VRM or GLB from a local drive.";
                return;
            }
            ChangeWidget("model", selected);
            updateModelControls();
        });
        var useDefault = Command("Use default", () => { ChangeWidget("model", ""); updateModelControls(); });
        foreach (var button in new[] { useDefault, pick })
        {
            button.Margin = new Thickness(8, 0, 0, 0);
            DockPanel.SetDock(button, Dock.Right);
            modelRow.Children.Add(button);
        }
        modelRow.Children.Add(modelLabel);
        var appearanceGroup = Section(panels[0], "Model and outfit");
        var movement = Section(panels[2], "Behavior and animation");
        var desktop = Section(panels[4], "Window and performance");
        desktop.Children.Add(modelRow);
        var edition = WidgetChoice(appearanceGroup, "Edition", "edition",
            new[] { "Midnight Nocturne", "Lunar Temptation", "Velvet Enchantress", "Velvet Bloom", "ZXC", "Midnight Edition", "Original", "Custom character" },
            new object[] { "nocturne", "lunar", "velvet", "velvet_bloom", "zxc", "midnight", "original", "custom" });
        WidgetButtons(appearanceGroup, ("Open character editor", () => Select(1)));
        reloadWardrobe = BuildCharacterEditor(panels[1], () => edition.SelectedIndex = edition.Items.Count - 1);
        WidgetNumber(appearanceGroup, "Scale", "zoom", 65, 200, "%", 100);
        var originalLegs = new StackPanel();
        var fittedLegs = new StackPanel();
        appearanceGroup.Children.Add(originalLegs);
        appearanceGroup.Children.Add(fittedLegs);
        WidgetChoice(originalLegs, "Legwear", "stockings", new[] { "Stockings", "Bare legs" }, new object[] { true, false });
        BuildFittedLegwear(fittedLegs, custom: false, out var setStockingStyles);
        void DisplayLegwear()
        {
            string editionId = WidgetSettings.String(widgetDraft, "edition");
            bool custom = editionId == "custom";
            bool legacy = editionId == "original" || WidgetSettings.String(widgetDraft, "model").Length > 0;
            originalLegs.Visibility = legacy && !custom ? Visibility.Visible : Visibility.Collapsed;
            fittedLegs.Visibility = !legacy && !custom ? Visibility.Visible : Visibility.Collapsed;
            setStockingStyles(editionId != "midnight");
            pick.IsEnabled = useDefault.IsEnabled = !custom;
            DescribeModel();
        }
        updateModelControls = DisplayLegwear;
        edition.SelectionChanged += (_, _) => DisplayLegwear();
        DisplayLegwear();
        WidgetChoice(movement, "Sitting style", "sit_style", new[] { "Still", "Leg swing", "Relaxed stretch" }, new object[] { "still", "swing", "relaxed" });
        WidgetNumber(movement, "Sitting motion intensity", "intensity", 0, 100, "%", 100);
        WidgetToggle(movement, "Animations", "animate");
        WidgetToggle(movement, "Hair motion", "hair");
        WidgetToggle(appearanceGroup, "Keep companion above other windows", "top");
        WidgetToggle(appearanceGroup, "Show companion over fullscreen apps", "fullscreen_overlay");
        WidgetToggle(appearanceGroup, "Thought bubble", "bubble");
        WidgetChoice(appearanceGroup, "Bubble style", "bubble_style", new[] { "Glass", "Minimal" }, new object[] { "glass", "minimal" });
        WidgetNumber(desktop, "Status refresh", "poll_ms", 200, 2500, "ms");

        var behavior = movement;
        WidgetChoice(behavior, "Mode", "mode", new[] { "Taskbar", "Window edges", "Free roam", "Stationary", "Follow cursor", "Hover" },
            new object[] { "taskbar", "windows", "roam", "stationary", "follow", "hover" });
        WidgetToggle(behavior, "Physics", "physics");
        WidgetToggle(behavior, "Magic Platforms", "magic");
        var magnet = Section(behavior, "Window magnet");
        WidgetToggle(magnet, "Attract companion to window edges", "window_magnet_enabled");
        WidgetNumber(magnet, "Magnet strength", "window_magnet", 50, 200, "%", 100);
        WidgetButtons(magnet, ("Reset window magnet", () =>
        {
            ChangeWidget("window_magnet_enabled", true);
            ChangeWidget("window_magnet", 1.0);
            LayoutWidgets();
            ApplyWidgetChanges();
        }));
        WidgetNumber(behavior, "Gravity", "gravity", 120, 2400, "px/s²");
        WidgetNumber(behavior, "Walk speed", "walk_speed", 10, 280, "px/s");
        WidgetButtons(behavior, ("Reset 3D position", () =>
        {
            ChangeWidget("x", -1);
            ChangeWidget("y", -1);
            SendWidgetCommand("reset-3d-position");
        }));

        WidgetToggle(desktop, "Left-click through", "clickthrough");
        WidgetToggle(desktop, "Start with ReflexCore", "app_start");
        var notifications = Section(panels[4], "Notifications");
        WidgetToggle(notifications, "Windows activity notifications", "windows_notifications");
        notifications.Children.Add(WidgetHint("These notifications appear in Windows under Windows PowerShell 5.1."));
        WidgetChoice(desktop, "Maximum edge smoothing", "msaa", new[] { "Off", "2× MSAA", "4× MSAA" }, new object[] { 0, 1, 2 });
        WidgetNumber(desktop, "FPS limit", "fps", 15, 60, "FPS");
        WidgetButtons(desktop, ("Use low-power preset", () =>
        {
            ChangeWidget("fps", 24);
            ChangeWidget("msaa", 1);
            ChangeWidget("hair", false);
            ChangeWidget("poll_ms", 900);
            LayoutWidgets();
            ApplyWidgetChanges();
        }));


        var footer = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
        panels[4].Children.Add(footer);
        WidgetButtons(footer, ("Restore defaults", () =>
            {
                foreach (var pair in widgetDefaults) ChangeWidget(pair.Key, pair.Value);
                LayoutWidgets();
                ApplyWidgetChanges();
            }));
        Select(widgetSection);
        RefreshWidgetStatus();
    }

    static TextBlock WidgetHint(string text)
    {
        var label = Label(text, 13, "Sub");
        label.TextWrapping = TextWrapping.Wrap;
        label.Margin = new Thickness(0, 2, 0, 9);
        return label;
    }

    static void WidgetButtons(Panel parent, params (string label, Action action)[] actions)
    {
        var row = new WrapPanel { Margin = new Thickness(0, 4, 0, 6) };
        foreach (var action in actions)
        {
            var button = Command(action.label, action.action);
            button.Margin = new Thickness(0, 0, 8, 6);
            row.Children.Add(button);
        }
        parent.Children.Add(row);
    }

    static readonly int[] legwearDensities = { 40, 30, 20, 15, 10, 5 };
    static readonly string[] stockingColors = { "dark", "black", "white", "lilac", "plum", "burgundy" };

    Action BuildFittedLegwear(Panel parent, bool custom, out Action<bool> setStockingStyles)
    {
        string enabledKey = custom ? "custom_stockings" : "midnight_stockings";
        string densityKey = custom ? "custom_legwear_den" : "legwear_den";
        string colorKey = custom ? "custom_legwear_color" : "legwear_color";
        var legwear = Choice(parent, custom ? "Custom legwear" : "Legwear", new[] { "Barefoot", "Stockings" });
        legwear.SelectedIndex = WidgetSettings.Bool(widgetDraft, enabledKey) ? 1 : 0;
        var options = new StackPanel();
        parent.Children.Add(options);
        var density = Choice(options, "Stocking density",
            legwearDensities.Select(value => value.ToString(CultureInfo.InvariantCulture) + " den").ToArray());
        var savedDensity = WidgetSettings.Number(widgetDraft, densityKey, 40);
        density.SelectedIndex = Math.Max(0, Array.FindIndex(legwearDensities, value => value == savedDensity));
        var color = Choice(options, "Stocking color",
            stockingColors.Select(value => CultureInfo.InvariantCulture.TextInfo.ToTitleCase(value)).ToArray());
        color.SelectedIndex = Math.Max(0, Array.IndexOf(stockingColors, WidgetSettings.String(widgetDraft, colorKey)));

        bool supportsStyles = true;
        void UpdateVisibility() => options.Visibility =
            supportsStyles && legwear.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed;
        setStockingStyles = supported =>
        {
            supportsStyles = supported;
            UpdateVisibility();
        };

        void Apply()
        {
            if (legwear.SelectedIndex < 0 || density.SelectedIndex < 0 || color.SelectedIndex < 0) return;
            ChangeWidget(enabledKey, legwear.SelectedIndex == 1);
            if (!supportsStyles) return;
            ChangeWidget(densityKey, legwearDensities[density.SelectedIndex]);
            ChangeWidget(colorKey, stockingColors[color.SelectedIndex]);
        }

        legwear.SelectionChanged += (_, _) => UpdateVisibility();
        UpdateVisibility();
        if (!custom)
        {
            legwear.SelectionChanged += (_, _) => Apply();
            density.SelectionChanged += (_, _) => Apply();
            color.SelectionChanged += (_, _) => Apply();
        }
        return Apply;
    }

    void WidgetToggle(Panel parent, string label, string key)
    {
        bool defaultValue = (bool)widgetDefaults[key];
        AddSwitch(parent, label, new Sw(WidgetSettings.Bool(widgetDraft, key, defaultValue)), value => ChangeWidget(key, value));
    }

    ComboBox WidgetChoice(Panel parent, string label, string key, string[] captions, object[] values)
    {
        var choice = Choice(parent, label, captions);
        int index = Array.IndexOf(values, widgetDraft[key]);
        choice.SelectedIndex = index < 0 ? Array.IndexOf(values, widgetDefaults[key]) : index;
        choice.SelectionChanged += (_, _) =>
        {
            if (choice.SelectedIndex >= 0) ChangeWidget(key, values[choice.SelectedIndex]);
        };
        return choice;
    }

    void WidgetNumber(Panel parent, string label, string key, double min, double max, string unit, double factor = 1)
    {
        var description = Label("", 13, "Sub");
        description.Margin = new Thickness(0, 6, 0, 2);
        parent.Children.Add(description);
        double fallback = WidgetSettings.Number(widgetDefaults, key, min / factor);
        var slider = new Slider
        {
            Minimum = min, Maximum = max, SmallChange = 1,
            LargeChange = max > 500 ? 100 : 5, IsSnapToTickEnabled = true, TickFrequency = 1,
            Value = Bounds.Clamp(WidgetSettings.Number(widgetDraft, key, fallback) * factor, min, max),
            Margin = new Thickness(0, 0, 0, 7)
        };
        AutomationProperties.SetName(slider, label);
        void UpdateCaption() => description.Text = String.Format(CultureInfo.InvariantCulture,
            "{0} · {1:0}{2}{3}", label, slider.Value, unit == "%" ? "" : " ", unit);
        slider.ValueChanged += (_, _) => { UpdateCaption(); ChangeWidget(key, factor == 1 ? (object)(int)slider.Value : slider.Value / factor); };
        UpdateCaption();
        parent.Children.Add(slider);
    }

    void ChangeWidget(string key, object value)
    {
        if (Equals(widgetDraft[key],value)) return;
        widgetDraft[key] = value;
        changedWidgetKeys.Add(key);
        if (widgetFeedback != null) widgetFeedback.Text = "Saving settings…";
        widgetSave.Stop();
        widgetSave.Start();
    }

    bool ApplyWidgetChanges()
    {
        widgetSave.Stop();
        try
        {
            if (changedWidgetKeys.Count > 0) WidgetSettings.Save(widgetDraft, changedWidgetKeys);
            changedWidgetKeys.Clear();
            widgetFeedback.Text = "Widget settings saved.";
            return true;
        }
        catch (IOException) { widgetFeedback.Text = "Couldn't save the widget settings. Try again."; }
        catch (UnauthorizedAccessException) { widgetFeedback.Text = "The widget settings folder is unavailable."; }
        catch (InvalidOperationException) { widgetFeedback.Text = "The widget settings file is invalid."; }
        return false;
    }

    void SendWidgetCommand(string command, bool apply = true)
    {
        if (String.IsNullOrEmpty(projectRoot))
        {
            widgetFeedback.Text = "Open Studio through the ReflexCore launcher to control the widgets.";
            return;
        }
        if (!TrayIsRunning())
        {
            widgetFeedback.Text = "Start the ReflexCore tray, then try again.";
            return;
        }
        if (apply && !ApplyWidgetChanges()) return;
        string path = Path.Combine(projectRoot, "data", "bridge", "widget-command.txt");
        try
        {
            WidgetSettings.Write(path, command, false);
            widgetFeedback.Text = "Request sent to the ReflexCore tray.";
        }
        catch (IOException) { widgetFeedback.Text = File.Exists(path) ?
            "The tray is handling an earlier request. Try again." : "Couldn't reach the ReflexCore tray. Try again."; }
        catch (UnauthorizedAccessException) { widgetFeedback.Text = "The ReflexCore tray bridge is unavailable."; }
    }

    void RefreshWidgetStatus()
    {
        var host = WidgetSettings.Read(Path.Combine(WidgetSettings.Folder, "host-status.json"));
        if (classicStatus == null || companionStatus == null) return;
        bool hostReady = WidgetSettings.String(host, "schema") == "reflexcore.companion.host.v1" && TrayIsRunning();
        classicStatus.Text = !hostReady ? "Tray status unavailable" :
            WidgetSettings.Bool(host, "classic_visible") ? "Visible" : "Hidden";
        if (!hostReady || !WidgetSettings.Bool(host, "running"))
        {
            characterEditorStatus.Visibility = Visibility.Collapsed;
            string message = WidgetSettings.String(host, "message");
            companionStatus.Text = !hostReady ? "Tray status unavailable" : message switch
            {
                "Godot runtime is not configured." => "Godot runtime is not configured.",
                "Godot executable is unavailable." => "Godot executable is unavailable.",
                "Could not start Godot." or "Could not control the 3D renderer." or
                "3D renderer exited. See runtime status." => "The 3D renderer did not start or exited.",
                _ => "Stopped"
            };
            return;
        }
        var runtime = WidgetSettings.Read(Path.Combine(WidgetSettings.Folder, "status.json"));
        string runtimeError = WidgetSettings.String(runtime, "error");
        string customError = "";
        if (WidgetSettings.String(widgetDraft, "edition") == "custom")
        {
            customError = runtimeError switch
            {
                "custom_assets_missing" => "Custom parts are missing. Rebuild the local wardrobe, then reload parts in the editor.",
                "custom_assets_invalid" => "Custom parts could not be loaded. Rebuild the local wardrobe from the installed presets.",
                _ => ""
            };
        }
        characterEditorStatus.Text = customError;
        characterEditorStatus.Visibility = customError.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (customError.Length > 0)
        {
            companionStatus.Text = customError;
            return;
        }
        if (WidgetSettings.String(runtime, "schema") != "reflexcore.companion.runtime.v1" ||
            !WidgetSettings.Bool(runtime, "ready"))
        {
            companionStatus.Text = WidgetSettings.String(runtime, "error").Length == 0 ?
                "Starting overlay…" : "The overlay could not load its model or renderer.";
            return;
        }
        double fps = WidgetSettings.Number(runtime, "fps", 0);
        double frame = WidgetSettings.Number(runtime, "frame_ms", 0);
        bool loaded = WidgetSettings.Bool(runtime, "model_loaded");
        companionStatus.Text = loaded && fps > 0 && frame > 0 ? String.Format(CultureInfo.InvariantCulture,
            "Running · {0:0} FPS · {1:0.0} ms", fps, frame) : loaded ? "Running" : "Running · waiting for a model";
        var gpu = WidgetSettings.String(runtime, "gpu");
        if (loaded && !String.IsNullOrWhiteSpace(gpu))
            companionStatus.Text += " · " + gpu;
    }

    static bool TrayIsRunning()
    {
        try
        {
            using var tray = System.Threading.Mutex.OpenExisting(@"Local\ReflexCoreAgentTray");
            return true;
        }
        catch (System.Threading.WaitHandleCannotBeOpenedException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }
}
