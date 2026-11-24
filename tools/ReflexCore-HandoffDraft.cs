using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace ReflexCore.Control
{
    public enum HandoffDraftState { Draft, Clarify, OutsideScope }

    public static class HandoffDraft
    {
        const RegexOptions Options = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
        static readonly Regex Prefix = new Regex(
            @"\A(?:(?:please\s+)?(?:check|verify)(?:\s+(?:that|for|the files))?|проверь(?:,\s*что\s+(?:в\s+папке\s+)?есть|\s+наличие)?)\s*:?\s+",
            Options);
        static readonly Regex Ending = new Regex(@"\s+(?:are present|is present|exist|exists)\z", Options);
        static readonly Regex Item = new Regex(
            @"\G\s*(?:\x60(?<quoted>[^\x60]+)\x60|""(?<quoted>[^""]+)""|'(?<quoted>[^']+)'|«(?<quoted>[^»]+)»|(?<bare>[^\s,;()""'«»\x60|]+))" +
            @"(?:\s*(?:\|\s*(?<hash>[a-f0-9]{64})|\(\s*sha-?256\s*[:=]\s*(?<hash>[a-f0-9]{64})\s*\)|\s+sha-?256\s*[:=]\s*(?<hash>[a-f0-9]{64})))?",
            Options);
        static readonly Regex Separator = new Regex(@"\G(?:\s*[,;]\s*(?:(?:and|и)\s+)?|\s+(?:and|и)\s+)", Options);
        static readonly Regex Device = new Regex(@"\A(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|CLOCK\$|(?:COM|LPT)[0-9¹²³])\z", Options);

        public static HandoffDraftState Build(string request, out string[] lines)
        {
            lines = new string[0];
            if (String.IsNullOrWhiteSpace(request) || request.Length > 8192) return HandoffDraftState.Clarify;
            string body = request.Trim();
            var prefix = Prefix.Match(body);
            if (!prefix.Success) return HandoffDraftState.Clarify;
            body = body.Substring(prefix.Length);
            if (body.EndsWith(".", StringComparison.Ordinal) || body.EndsWith("?", StringComparison.Ordinal))
                body = body.Substring(0, body.Length - 1).TrimEnd();
            body = Ending.Replace(body, "");

            var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var proposed = new List<string>();
            int position = 0;
            while (position < body.Length)
            {
                var item = Item.Match(body, position);
                if (!item.Success) return HandoffDraftState.Clarify;
                bool quoted = item.Groups["quoted"].Success;
                string path = item.Groups[quoted ? "quoted" : "bare"].Value;
                if (!IsRelativeFile(path)) return HandoffDraftState.OutsideScope;
                if (!quoted && path.IndexOf('.') < 0) return HandoffDraftState.Clarify;
                if (!paths.Add(path.Replace('/', '\\')) || paths.Count > 128) return HandoffDraftState.Clarify;

                var hash = item.Groups["hash"];
                proposed.Add(hash.Success ? path + " | " + hash.Value.ToLowerInvariant() : path);
                position = item.Index + item.Length;
                if (position == body.Length) break;
                var separator = Separator.Match(body, position);
                if (!separator.Success) return HandoffDraftState.Clarify;
                position += separator.Length;
                if (position == body.Length) return HandoffDraftState.Clarify;
            }
            if (proposed.Count == 0) return HandoffDraftState.Clarify;
            lines = proposed.ToArray();
            return HandoffDraftState.Draft;
        }

        static bool IsRelativeFile(string path)
        {
            if (path.Length > 1024) return false;
            foreach (string component in path.Split('/', '\\'))
            {
                if (component.Length == 0 || component.EndsWith(" ", StringComparison.Ordinal) ||
                    component.EndsWith(".", StringComparison.Ordinal)) return false;
                foreach (char character in component)
                    if (Char.IsControl(character) || "<>:\"|?*".IndexOf(character) >= 0) return false;
                if (Device.IsMatch(component.Split('.')[0].TrimEnd())) return false;
            }
            return true;
        }
    }
}
