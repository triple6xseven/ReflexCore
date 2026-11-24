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

        public static string JournalDirectory
        {
            get {
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "ReflexCore","rename-history");
            }
        }

        sealed class RenameJournal : IDisposable
        {
            readonly FileStream stream;
            readonly System.Web.Script.Serialization.JavaScriptSerializer serializer =
                new System.Web.Script.Serialization.JavaScriptSerializer();

            public RenameJournal(string path)
            {
                stream = new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.Read);
            }

            public void Record(string action, string folder, Entry entry, int count)
            {
                var record = new {
                    schema="reflexcore.rename.journal.v1",
                    utc=DateTime.UtcNow.ToString("o",System.Globalization.CultureInfo.InvariantCulture),
                    action,folder,
                    before=entry==null?null:entry.Before,
                    after=entry==null?null:entry.After,
                    renamed=count
                };
                byte[] bytes = System.Text.Encoding.UTF8.GetBytes(serializer.Serialize(record) + "\n");
                stream.Write(bytes,0,bytes.Length);
                stream.Flush(true);
            }

            public void Dispose() { stream.Dispose(); }
        }

        public bool Apply(string historyDirectory, out int renamed, out string error)
        {
            renamed = 0;
            error = "";
            RenameJournal journal;
            try {
                string history = Path.GetFullPath(historyDirectory).TrimEnd(Path.DirectorySeparatorChar);
                if (String.Equals(folder.TrimEnd(Path.DirectorySeparatorChar),history,StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Cannot rename files in the history folder.");
                Directory.CreateDirectory(history);
                string name = DateTime.UtcNow.ToString("yyyyMMdd-HHmmss",System.Globalization.CultureInfo.InvariantCulture)
                    + "-" + Guid.NewGuid().ToString("N") + ".jsonl";
                journal = new RenameJournal(Path.Combine(history,name));
            } catch (IOException) {
                error = "Could not create the rename log. No files were changed.";
                return false;
            } catch (UnauthorizedAccessException) {
                error = "Could not create the rename log. No files were changed.";
                return false;
            }

            using (journal) {
                try {
                    journal.Record("started",folder,null,renamed);
                    using (new FolderPins(folder)) {
                        VerifyPreview();
                        foreach (var entry in entries) {
                            var path = Path.Combine(folder,entry.Before);
                            if ((File.GetAttributes(path) & (FileAttributes.ReparsePoint|FileAttributes.Directory)) != 0)
                                throw new IOException("A source file changed.");

                            // A flushed intent preserves the original name even if the process stops during the move.
                            journal.Record("intent",null,entry,renamed);
                            File.Move(path,Path.Combine(folder,entry.After));
                            ++renamed;
                            journal.Record("renamed",null,entry,renamed);
                        }
                    }
                    journal.Record("completed",null,null,renamed);
                    return true;
                } catch (IOException) {
                    error = StopAndRecord(journal,renamed);
                    return false;
                } catch (UnauthorizedAccessException) {
                    error = StopAndRecord(journal,renamed);
                    return false;
                }
            }
        }

        static string StopAndRecord(RenameJournal journal, int renamed)
        {
            const string incomplete = "The rename log could not be completed. Inspect the folder before retrying.";
            try {
                journal.Record("stopped",null,null,renamed);
                return "Stopped at the first file or log error. Check the log and preview again.";
            } catch (IOException) { return incomplete; }
              catch (UnauthorizedAccessException) { return incomplete; }
        }

        void VerifyPreview()
        {
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
        }
    }
}
