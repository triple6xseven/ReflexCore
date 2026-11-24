using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace ReflexCore.Control
{
    public sealed class ExtensionRename
    {
        const int EntryLimit = 4096;
        const string Extension = @"\.?[a-z0-9][a-z0-9_-]{0,31}";
        const RegexOptions MatchOptions = RegexOptions.IgnoreCase | RegexOptions.CultureInvariant;
        static readonly Regex Request = new Regex(
            @"\A(?:(?:change|rename)(?: the)? extensions?(?: of all files)?|(?:измени|поменяй|переименуй) расширени[ея](?: (?:всех файлов|у всех файлов))?)" +
            @"\s+(?:(?:from|с)\s+(?<from>" + Extension + @")\s+)?(?:to|на)\s+(?<to>" + Extension + @")[.!]?\z", MatchOptions);
        static readonly Regex ValidExtension = new Regex(@"\A" + Extension + @"\z", MatchOptions);

        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);

        public sealed class Entry
        {
            public string Before { get; private set; }
            public string After { get; private set; }
            internal readonly long Length;
            internal readonly DateTime LastWrite;
            internal readonly DateTime Created;
            internal Entry(FileInfo file, string destination)
            {
                Before = file.Name;
                After = destination;
                Length = file.Length;
                LastWrite = file.LastWriteTimeUtc;
                Created = file.CreationTimeUtc;
            }
        }

        readonly string folder, source, destination;
        readonly List<Entry> entries;
        public IList<Entry> Entries { get { return entries.AsReadOnly(); } }

        ExtensionRename(string folder, string source, string destination, List<Entry> entries)
        {
            this.folder = folder;
            this.source = source;
            this.destination = destination;
            this.entries = entries;
        }

        public static bool TryParse(string text, out string source, out string destination)
        {
            source = destination = "";
            if (String.IsNullOrWhiteSpace(text) || text.Length > 256) return false;
            var match = Request.Match(text.Trim());
            if (!match.Success) return false;
            source = match.Groups["from"].Value;
            destination = match.Groups["to"].Value;
            return true;
        }

        static string Normalize(string value, bool optional)
        {
            value = (value ?? "").Trim();
            if (optional && value.Length == 0) return "";
            if (!ValidExtension.IsMatch(value))
                throw new ArgumentException("Use one extension, such as .txt or .log.");
            return "." + value.TrimStart('.');
        }

        sealed class FolderPins : IDisposable
        {
            readonly List<SafeFileHandle> handles = new List<SafeFileHandle>();

            public FolderPins(string folder)
            {
                var root = Path.GetPathRoot(folder);
                if (root.Length != 3 || root[1] != ':' || new DriveInfo(root).DriveType != DriveType.Fixed)
                    throw new IOException("Select a folder on a local fixed drive.");
                var chain = new Stack<DirectoryInfo>();
                for (var part = new DirectoryInfo(folder); part != null; part = part.Parent) chain.Push(part);
                try {
                    foreach (var part in chain) {
                        // Open the directory itself and keep it pinned while resolving its children.
                        var handle = CreateFile(part.FullName,0x80,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
                        handles.Add(handle);
                        if (handle.IsInvalid || (File.GetAttributes(part.FullName) &
                            (FileAttributes.Directory|FileAttributes.ReparsePoint)) != FileAttributes.Directory)
                            throw new IOException("Cannot pin this folder. Linked folders are unsupported.");
                    }
                } catch {
                    Dispose();
                    throw;
                }
            }

            public void Dispose()
            {
                for (int i = handles.Count - 1; i >= 0; --i) handles[i].Dispose();
            }
        }

        public static ExtensionRename Preview(string folder, string source, string destination)
        {
            folder = Path.GetFullPath(folder);
            source = Normalize(source,true);
            destination = Normalize(destination,false);
            using (new FolderPins(folder))
                return new ExtensionRename(folder,source,destination,Scan(folder,source,destination));
        }

        static List<Entry> Scan(string folder, string source, string destination)
        {
            var occupied = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var targets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var entries = new List<Entry>();

            foreach (var path in Directory.EnumerateFileSystemEntries(folder)) {
                occupied.Add(Path.GetFileName(path));
                if (occupied.Count > EntryLimit)
                    throw new IOException("Choose a folder with at most 4,096 entries.");
                var attributes = File.GetAttributes(path);
                if ((attributes & (FileAttributes.Directory|FileAttributes.ReparsePoint)) != 0) continue;
                var file = new FileInfo(path);
                int dot = file.Name.LastIndexOf('.');
                string extension = dot > 0 ? file.Name.Substring(dot) : "";
                if (source.Length > 0 && !String.Equals(source,extension,StringComparison.OrdinalIgnoreCase)) continue;
                if (String.Equals(destination,extension,StringComparison.OrdinalIgnoreCase)) continue;

                string name = (dot > 0 ? file.Name.Substring(0,dot) : file.Name) + destination;
                if (!targets.Add(name))
                    throw new IOException("Multiple files would have the same name. Try filtering by the old extension.");
                entries.Add(new Entry(file,name));
            }

            foreach (var entry in entries)
                if (occupied.Contains(entry.After))
                    throw new IOException("A destination name already exists. Choose another extension.");
            entries.Sort((first,second) => StringComparer.Ordinal.Compare(first.Before,second.Before));
            return entries;
        }

        public bool Apply(out int renamed, out string error)
        {
            renamed = 0;
            error = "";
            try {
                using (new FolderPins(folder)) {
                    var current = Scan(folder,source,destination);
                    if (current.Count != entries.Count) throw new IOException("Folder contents changed. Preview again.");
                    for (int i = 0; i < entries.Count; ++i) {
                        var expected = entries[i];
                        var actual = current[i];
                        if (expected.Before != actual.Before || expected.After != actual.After ||
                            expected.Length != actual.Length || expected.LastWrite != actual.LastWrite ||
                            expected.Created != actual.Created)
                            throw new IOException("Folder contents changed. Preview again.");
                    }
                    foreach (var entry in entries) {
                        var path = Path.Combine(folder,entry.Before);
                        if ((File.GetAttributes(path) & (FileAttributes.ReparsePoint|FileAttributes.Directory)) != 0)
                            throw new IOException("A source file changed.");
                        File.Move(path,Path.Combine(folder,entry.After));
                        ++renamed;
                    }
                }
                return true;
            } catch (IOException) {
                error = "Stopped because the folder changed, a file is in use, or a destination already exists. Preview again.";
            } catch (UnauthorizedAccessException) {
                error = "Stopped because access to a file was denied.";
            }
            return false;
        }
    }
}
