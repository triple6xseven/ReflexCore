using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace ReflexCore.Studio;

static class WidgetSettings
{
    const int MaxBytes = 16 * 1024;
    static readonly UTF8Encoding Utf8 = new(false, true);
    internal static readonly string Folder = Environment.GetEnvironmentVariable("REFLEXCORE_COMPANION_DIRECTORY") ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ReflexCore", "companion3d");

    internal static Dictionary<string, object> Defaults() => new()
    {
        ["model"] = "", ["mode"] = "taskbar", ["x"] = -1, ["y"] = -1, ["zoom"] = 1.0,
        ["edition"] = "nocturne", ["midnight_stockings"] = false, ["sit_style"] = "swing", ["intensity"] = 1.0, ["magic"] = true, ["msaa"] = 2,
        ["custom_outfit"] = "lunar", ["custom_hair"] = "lunar", ["custom_head"] = "lunar", ["custom_stockings"] = false,
        ["legwear_den"] = 40, ["legwear_color"] = "dark", ["custom_legwear_den"] = 40, ["custom_legwear_color"] = "dark",
        ["physics"] = true, ["gravity"] = 900, ["walk_speed"] = 58, ["hair"] = true,
        ["stockings"] = true, ["animate"] = true, ["bubble"] = true, ["bubble_style"] = "glass",
        ["top"] = true, ["fullscreen_overlay"] = false, ["clickthrough"] = false, ["fps"] = 30, ["poll_ms"] = 450, ["app_start"] = false,
        ["windows_notifications"] = false, ["classic_opacity"] = 0.94, ["classic_host"] = true, ["classic_gpu"] = true, ["classic_ollama"] = true
    };

    internal static Dictionary<string, object> Read(string path)
    {
        if (!File.Exists(path)) return new Dictionary<string, object>();
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            long length = stream.Length;
            if (length > MaxBytes) return new Dictionary<string, object>();
            using var reader = new StreamReader(stream, Utf8);
            var buffer = new char[length + 1];
            int count = reader.ReadBlock(buffer, 0, buffer.Length);
            if (count > length || reader.Peek() >= 0) return new Dictionary<string, object>();
            string raw = new string(buffer, 0, count);
            return new JavaScriptSerializer { MaxJsonLength = MaxBytes, RecursionLimit = 12 }
                .Deserialize<Dictionary<string, object>>(raw) ?? new Dictionary<string, object>();
        }
        catch (IOException) { return new Dictionary<string, object>(); }
        catch (UnauthorizedAccessException) { return new Dictionary<string, object>(); }
        catch (ArgumentException) { return new Dictionary<string, object>(); }
        catch (InvalidOperationException) { return new Dictionary<string, object>(); }
    }

    internal static Dictionary<string, object> Load()
    {
        var defaults = Defaults();
        foreach (var pair in Read(Path.Combine(Folder, "settings.json")))
            if (defaults.ContainsKey(pair.Key)) defaults[pair.Key] = pair.Value;
        return defaults;
    }

    internal static string String(IDictionary<string, object> values, string key, string fallback = "") =>
        values.TryGetValue(key, out var value) && value is string text && text.Length <= 1024 ? text : fallback;

    internal static bool Bool(IDictionary<string, object> values, string key, bool fallback = false) =>
        values.TryGetValue(key, out var value) && value is bool flag ? flag : fallback;

    internal static double Number(IDictionary<string, object> values, string key, double fallback)
    {
        if (!values.TryGetValue(key, out var value)) return fallback;
        double result;
        switch (value)
        {
            case int integer: result = integer; break;
            case long large: result = large; break;
            case uint unsigned: result = unsigned; break;
            case double floating: result = floating; break;
            case decimal precise: result = (double)precise; break;
            default: return fallback;
        }
        return Double.IsNaN(result) || Double.IsInfinity(result) ? fallback : result;
    }

    internal static void Save(IDictionary<string, object> values, IEnumerable<string> changed, string filename = "settings.json")
    {
        string path = Path.Combine(Folder, filename);
        var merged = Read(path);
        foreach (string key in changed) merged[key] = values[key];
        Write(path, new JavaScriptSerializer { MaxJsonLength = MaxBytes, RecursionLimit = 12 }.Serialize(merged));
    }

    internal static void Write(string path, string value, bool replace = true)
    {
        string folder = Path.GetDirectoryName(path);
        if (Utf8.GetByteCount(value) > MaxBytes) throw new IOException("Widget settings are too large.");
        Directory.CreateDirectory(folder);
        string pending = Path.Combine(folder, ".widget-" + Guid.NewGuid().ToString("N", CultureInfo.InvariantCulture) + ".tmp");
        try
        {
            File.WriteAllText(pending, value, Utf8);
            if (replace && File.Exists(path))
            {
                try { File.Replace(pending, path, null); }
                catch (FileNotFoundException) { File.Move(pending, path); }
            }
            else File.Move(pending, path);
        }
        finally
        {
            if (File.Exists(pending)) File.Delete(pending);
        }
    }
}
