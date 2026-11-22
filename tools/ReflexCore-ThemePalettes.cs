// REFLEXCORE 0.6.4 PREVIEW2: faithful palette data port from the user's own zxcLagLab/style/Themes.cs.
// Original zxcLagLab WPF shell, brushes, effects, native network/driver code are NOT imported.
// The WPF Theme constructors were translated to .NET Framework-compatible C# for the existing WinForms host.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Text;

namespace ReflexCore.Control
{
    internal sealed class ReflexImportedTheme
    {
        public readonly string Name, Font;
        public readonly bool Dark;
        public readonly Color Bg, Card, Text, Sub, Accent, Accent2, OnAccent, Track;
        public ReflexImportedTheme(string name, bool dark, string bg, string card, string ink, string sub,
                                   string accent, string accent2, string onAccent, string track, string font)
        {
            Name = name; Dark = dark; Font = font;
            Bg = ColorTranslator.FromHtml(bg); Card = ColorTranslator.FromHtml(card);
            Text = ColorTranslator.FromHtml(ink); Sub = ColorTranslator.FromHtml(sub);
            Accent = ColorTranslator.FromHtml(accent); Accent2 = ColorTranslator.FromHtml(accent2);
            OnAccent = ColorTranslator.FromHtml(onAccent); Track = ColorTranslator.FromHtml(track);
        }
    }

    internal static class ReflexThemeCatalog
    {
        // Values directly extracted from zxcLagLab 2.2.0-preview.35 Themes.cs; no modified theme RGBs.
        internal static readonly ReflexImportedTheme[] All = {
            new ReflexImportedTheme("Network Studio", true, "#0C121C", "#151F2D", "#E6EDF6", "#9BAEC5", "#65B5F5", "#7BD7C4", "#081421", "#243449", "Segoe UI"),
            new ReflexImportedTheme("Pixel Terminal", true, "#0D1812", "#18291F", "#DBF2B8", "#AFCA92", "#BAE879", "#F5C969", "#172413", "#2B4532", "Segoe UI"),
            new ReflexImportedTheme("Pixel Arcade", true, "#14152B", "#202442", "#F7EAFF", "#C4B7DE", "#F5A349", "#54DDE4", "#281633", "#363D64", "Segoe UI"),
            new ReflexImportedTheme("Pixel Glacier", false, "#DCEAF8", "#F2F7FF", "#253152", "#465983", "#3460A7", "#B44C80", "#FFFFFF", "#CCD8EF", "Segoe UI"),
            new ReflexImportedTheme("Snow", false, "#EAF2F9", "#FFFFFF", "#24394D", "#526B83", "#518BB7", "#86BAD4", "#FFFFFF", "#D6E5F0", "Segoe UI"),
            new ReflexImportedTheme("Merry Christmas", true, "#101E1A", "#1A3028", "#FFF3DC", "#BCC9B2", "#CB4450", "#E4BE70", "#FFFFFF", "#304B3D", "Segoe UI"),
            new ReflexImportedTheme("Prism Glass", false, "#E8EBF3", "#FFFFFF", "#24364B", "#5B708A", "#729ACD", "#BA8EC7", "#FFFFFF", "#DCE5F0", "Segoe UI"),
            new ReflexImportedTheme("Alien Command", true, "#080E0C", "#111F18", "#E3FFE9", "#91B9A0", "#87E84D", "#41CBA5", "#071109", "#263D2D", "Consolas"),
            new ReflexImportedTheme("Alienwave", true, "#0B1119", "#151F29", "#E4F6FF", "#91A8BB", "#61D5E8", "#99A7D2", "#071820", "#273947", "Segoe UI"),
            new ReflexImportedTheme("Dark Fantasy", true, "#14110E", "#241E18", "#F2E6CD", "#B5A484", "#C3A066", "#9A7046", "#17110B", "#3D3428", "Palatino Linotype"),
            new ReflexImportedTheme("zxc 2003", true, "#160B1B", "#201328", "#FAEAFB", "#E3B7EA", "#F77BFF", "#A597FF", "#251028", "#4A245A", "Segoe UI"),
            new ReflexImportedTheme("zxc", true, "#201628", "#302340", "#FFF1FC", "#E1C9EF", "#FF9AD5", "#A7CAFF", "#26172D", "#4A355B", "Bahnschrift"),
            new ReflexImportedTheme("Vampire", true, "#100C12", "#21151F", "#F5E7EF", "#C19AAE", "#C53B62", "#D4B5C2", "#FFF3F7", "#3A2335", "Segoe UI"),
            new ReflexImportedTheme("Crimson Nocturne", true, "#130B0D", "#281317", "#FFE9E5", "#C99F9A", "#D8453D", "#C4B0A3", "#FFF8F3", "#48272C", "Cambria"),
            new ReflexImportedTheme("Windows 7 Aero", false, "#C4DDEB", "#F5FAFF", "#142C40", "#426582", "#337CB5", "#70B9EB", "#FFFFFF", "#D6E5EF", "Segoe UI"),
            new ReflexImportedTheme("Windows Vista", true, "#16232C", "#253C49", "#F0F8FF", "#A8C2D1", "#487D9E", "#A7CEDD", "#FFFFFF", "#3D596A", "Segoe UI"),
            new ReflexImportedTheme("Glass", true, "#111725", "#1E283B", "#F4F7FF", "#BBCCE5", "#A4BCFA", "#91D9CD", "#131B32", "#34415B", "Segoe UI"),
            new ReflexImportedTheme("Bubblegum", false, "#FFE9F3", "#FFFFFF", "#3B2A35", "#8B6B7D", "#FF8DC7", "#E0559A", "#FFFFFF", "#FFD6EA", "Segoe UI"),
            new ReflexImportedTheme("Sakura", false, "#FFF1F5", "#FFFFFF", "#4A2F3B", "#9A7184", "#F4A6C0", "#D4678F", "#40202E", "#FCDCE8", "Segoe UI"),
            new ReflexImportedTheme("Hot Pink", false, "#FFBEDD", "#FFF3F9", "#44002C", "#8C2F63", "#FF2E93", "#C70069", "#FFFFFF", "#FFD9EC", "Segoe UI"),
            new ReflexImportedTheme("Strawberry Milk", false, "#FFECEE", "#FFFFFF", "#4A2A30", "#9C6A73", "#FF9AA2", "#E2606F", "#40202E", "#FFD9DD", "Segoe UI"),
            new ReflexImportedTheme("Cotton Candy", false, "#FFE3F6", "#FFFFFF", "#38284A", "#7C6A99", "#FF9BD2", "#6EC6F5", "#2E1E40", "#F2D4FF", "Segoe UI"),
            new ReflexImportedTheme("Midnight Pink", true, "#1B1020", "#2A1A33", "#F6E6F2", "#B79BB0", "#FF5FB1", "#FF8DC7", "#1B1020", "#46305A", "Segoe UI"),
            new ReflexImportedTheme("Cyberpunk", true, "#0B0B16", "#14142A", "#E8F6FF", "#7FA0B8", "#FCEE0A", "#FF2A6D", "#0B0B16", "#2B2B55", "Consolas"),
            new ReflexImportedTheme("Hacker", true, "#06100C", "#0E1C16", "#D6FDEA", "#91CAA9", "#67F4A6", "#B7F77F", "#082018", "#1A3629", "Consolas"),
            new ReflexImportedTheme("Toxic", true, "#0A1208", "#121A10", "#D8FFB0", "#7AAA50", "#B8FF00", "#7CFC00", "#0A1208", "#1A2A14", "Consolas"),
            new ReflexImportedTheme("Vaporwave", true, "#2A1B4D", "#3B2A66", "#F3E9FF", "#BBA6E8", "#FF71CE", "#01CDFE", "#2A1B4D", "#52408A", "Segoe UI"),
            new ReflexImportedTheme("Windows XP", false, "#ECE9D8", "#FFFFFF", "#000000", "#404040", "#245EDC", "#3C8CF4", "#FFFFFF", "#D4D0C8", "Tahoma"),
            new ReflexImportedTheme("Nord", true, "#2E3440", "#3B4252", "#ECEFF4", "#D8DEE9", "#88C0D0", "#81A1C1", "#2E3440", "#4C566A", "Segoe UI"),
            new ReflexImportedTheme("Mono", true, "#121212", "#1E1E1E", "#EAEAEA", "#9A9A9A", "#FFFFFF", "#CFCFCF", "#121212", "#2A2A2A", "Consolas"),
            new ReflexImportedTheme("Dracula", true, "#282A36", "#44475A", "#F8F8F2", "#BD93F9", "#FF79C6", "#BD93F9", "#282A36", "#6272A4", "Segoe UI"),
            new ReflexImportedTheme("Ocean", true, "#0B1C2C", "#12283A", "#E6F4FF", "#7EB6D6", "#3DDCFF", "#1B9AAA", "#0B1C2C", "#1A3A50", "Segoe UI"),
            new ReflexImportedTheme("Ember", true, "#1A0E0A", "#2A1810", "#FFE8D6", "#E8A87C", "#FF6B35", "#D94F04", "#1A0E0A", "#3D2418", "Segoe UI"),
            new ReflexImportedTheme("Ice", false, "#EEF6FA", "#FFFFFF", "#1A3040", "#5A7A8A", "#4FC3F7", "#0288D1", "#FFFFFF", "#D4EAF4", "Segoe UI"),
            new ReflexImportedTheme("Matcha", false, "#F2F7EC", "#FFFFFF", "#2A3A28", "#6A8A68", "#7CB342", "#558B2F", "#FFFFFF", "#DCE8D4", "Segoe UI"),
            new ReflexImportedTheme("Lavender", false, "#F3EEF9", "#FFFFFF", "#3A2A4A", "#8A7A9A", "#9B7EBD", "#7B5EA7", "#FFFFFF", "#E4D8F0", "Segoe UI"),
            new ReflexImportedTheme("Sunset", false, "#FFF3E8", "#FFFFFF", "#3A2A20", "#9A6A50", "#FF8A5B", "#E85D04", "#FFFFFF", "#FFE0C8", "Segoe UI"),
            new ReflexImportedTheme("Neon", true, "#0A0614", "#140A22", "#F8EFFF", "#B89AD4", "#FF2EA6", "#00F0FF", "#0A0614", "#2A1840", "Segoe UI"),
            new ReflexImportedTheme("Aurora", true, "#0A1220", "#122033", "#E8F4FF", "#8AB4D0", "#5EF0C0", "#7B6CFF", "#0A1220", "#1A2A40", "Segoe UI"),
            new ReflexImportedTheme("Rose Gold", false, "#FFF5F0", "#FFFFFF", "#3A2420", "#9A6A60", "#E8A090", "#C07060", "#FFFFFF", "#F5E0D8", "Segoe UI"),
            new ReflexImportedTheme("Midnight City", true, "#0C0C18", "#16162A", "#F0F0FF", "#9090C0", "#FF4D8D", "#4D9FFF", "#0C0C18", "#222240", "Segoe UI"),
            new ReflexImportedTheme("Forest", true, "#0C1610", "#14241A", "#E0F0E4", "#70A080", "#3DCC7A", "#A8E060", "#0C1610", "#1A3020", "Segoe UI"),
            new ReflexImportedTheme("Candy Night", true, "#1A0A18", "#2A1428", "#FFE8F8", "#C090B0", "#FF6BCB", "#7B5CFF", "#1A0A18", "#3A2040", "Segoe UI"),
            new ReflexImportedTheme("Amber", true, "#18100A", "#281A10", "#FFF0E0", "#D0A070", "#FFB040", "#FF7040", "#18100A", "#3A2818", "Segoe UI"),
            new ReflexImportedTheme("Glacier", false, "#F0F6FA", "#FFFFFF", "#1A3040", "#5A8090", "#60D0E8", "#3080C0", "#FFFFFF", "#D8E8F0", "Segoe UI"),
        };
        private static readonly string SettingsPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ReflexCore", "settings", "ui-theme.txt");

        internal static ReflexImportedTheme Find(string name)
        {
            if (name != null)
                foreach (var item in All)
                    if (String.Equals(item.Name, name, StringComparison.Ordinal)) return item;
            foreach (var item in All) if (item.Name == "Hacker") return item;
            throw new InvalidOperationException("No Hacker theme in imported palette data");
        }
        internal static ReflexImportedTheme Load()
        {
            try {
                if (File.Exists(SettingsPath) && new FileInfo(SettingsPath).Length <= 160)
                    return Find(File.ReadAllText(SettingsPath, Encoding.UTF8).Trim().Trim('\uFEFF'));
            } catch (IOException) { } catch (UnauthorizedAccessException) { }
            return Find("Hacker");
        }
        internal static void Save(ReflexImportedTheme selected)
        {
            // Save only a whitelisted palette NAME. No telemetry or private UI strings.
            var theme = Find(selected == null ? null : selected.Name);
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath));
            File.WriteAllText(SettingsPath, theme.Name, new UTF8Encoding(false));
        }
        internal static void SelfTest()
        {
            if (All.Length != 45) throw new Exception("zxcLab theme count changed");
            var unique = new HashSet<string>(StringComparer.Ordinal);
            foreach (var theme in All) {
                if (!unique.Add(theme.Name)) throw new Exception("Duplicate imported theme");
                if (theme.Bg == Color.Empty || theme.Accent == Color.Empty) throw new Exception("Invalid palette");
            }
            if (Find("Hacker").Bg.ToArgb() != ColorTranslator.FromHtml("#06100C").ToArgb()
                || Find("Network Studio").Accent.ToArgb() != ColorTranslator.FromHtml("#65B5F5").ToArgb()
                || Find("Alien Command").Accent.ToArgb() != ColorTranslator.FromHtml("#87E84D").ToArgb()
                || Find("does-not-exist").Name != "Hacker")
                throw new Exception("Imported palette color and whitelist regression");
            Console.WriteLine("[ReflexCore] zxcLagLab imported palette tests passed (45 themes, whitelist, RGB).");
        }
    }
}
