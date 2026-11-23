using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;

namespace ReflexCore.Studio;

public sealed partial class StudioWindow
{
    static readonly KeyValuePair<string, string>[] wardrobePresets =
    {
        new("nocturne", "Midnight Nocturne"),
        new("lunar", "Lunar Temptation"),
        new("velvet", "Velvet Enchantress"),
        new("zxc", "ZXC")
    };

    Action BuildCharacterEditor(Panel parent, Action selectCustomEdition)
    {
        var editor = Section(parent, "Character editor");
        editor.Children.Add(WidgetHint("Combine parts from your installed presets. Apply your selections to save them as Custom character."));
        string[] categories = { "outfit", "hair", "head" };
        string[] labels = { "Outfit", "Hair", "Head and face" };
        var controls = new ComboBox[categories.Length];
        var rows = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2 };
        editor.Children.Add(rows);
        for (int i = 0; i < categories.Length; i++)
        {
            var column = new StackPanel { Margin = new Thickness(0, 0, i % 2 == 0 ? 8 : 0, 4) };
            rows.Children.Add(column);
            var control = Choice(column, labels[i], Array.Empty<string>());
            control.DisplayMemberPath = "Value";
            control.SelectedValuePath = "Key";
            controls[i] = control;
        }
        var legwearColumn = new StackPanel { Margin = new Thickness(0, 0, 0, 4) };
        rows.Children.Add(legwearColumn);
        var legwear = Choice(legwearColumn, "Custom legwear", new[] { "Barefoot", "Dark stockings" });
        legwear.SelectedIndex = WidgetSettings.Bool(widgetDraft, "custom_stockings") ? 1 : 0;
        var availability = WidgetHint("");
        editor.Children.Add(availability);
        characterEditorStatus = WidgetHint("");
        characterEditorStatus.Visibility = Visibility.Collapsed;
        editor.Children.Add(characterEditorStatus);

        void Apply(bool show)
        {
            for (int i = 0; i < controls.Length; i++)
                ChangeWidget("custom_" + categories[i], controls[i].SelectedValue);
            ChangeWidget("custom_stockings", legwear.SelectedIndex == 1);
            selectCustomEdition();
            if (ApplyWidgetChanges() && show) SendWidgetCommand("start-3d", false);
        }

        var apply = Command("Apply character", () => Apply(false));
        var preview = Command("Apply and show on desktop", () => Apply(true));
        var buttons = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        editor.Children.Add(buttons);

        void Reload()
        {
            var manifest = WidgetSettings.Read(Path.Combine(WidgetSettings.Folder, "wardrobe", "manifest.json"));
            string generation = WidgetSettings.String(manifest, "generation");
            bool valid = WidgetSettings.String(manifest, "schema") == "reflexcore.wardrobe.v1" && generation.Length == 20 &&
                generation.All(ch => ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f');
            var parts = valid &&
                manifest.TryGetValue("parts", out var value) ? value as Dictionary<string, object> : null;
            for (int i = 0; i < controls.Length; i++)
            {
                var control = controls[i];
                string category = categories[i];
                string selected = control.SelectedValue as string ?? WidgetSettings.String(widgetDraft, "custom_" + category, "lunar");
                var entries = parts != null && parts.TryGetValue(category, out var slot) ? slot as Dictionary<string, object> : null;
                var options = wardrobePresets.Where(preset => entries != null && entries.ContainsKey(preset.Key))
                    .Select(preset => category == "head" && preset.Key == "lunar"
                        ? new KeyValuePair<string, string>("lunar", "Lumen") : preset).ToArray();
                control.ItemsSource = options;
                control.SelectedValue = selected;
                if (control.SelectedIndex == -1 && options.Length > 0) control.SelectedIndex = 0;
                control.IsEnabled = options.Length > 0;
            }
            bool ready = controls.All(control => control.SelectedIndex >= 0);
            apply.IsEnabled = preview.IsEnabled = legwear.IsEnabled = ready;
            availability.Text = ready ? "" :
                "The local parts library is unavailable. Follow the Character Editor setup in docs/REFLEXCOMPANION.md, then reload parts.";
            availability.Visibility = ready ? Visibility.Collapsed : Visibility.Visible;
        }

        foreach (var button in new[] { apply, preview, Command("Reload parts", Reload) })
        {
            button.Margin = new Thickness(0, 0, 8, 6);
            buttons.Children.Add(button);
        }
        return Reload;
    }
}
