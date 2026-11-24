using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class Setup
{
    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            bool smoke = args.Length == 2 && args[0] == "--extract-test";
            if (args.Length != 0 && !smoke) return 2;
            string programs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs");
            string destination = smoke ? Path.GetFullPath(args[1]) : Path.Combine(programs, "ReflexCore");
            if (!smoke && Directory.Exists(destination))
            {
                using (var dialog = new FolderBrowserDialog())
                {
                    dialog.Description = "Choose an empty parent folder for the new ReflexCore installation.";
                    dialog.SelectedPath = programs;
                    if (dialog.ShowDialog() != DialogResult.OK) return 0;
                    destination = Path.Combine(dialog.SelectedPath, "ReflexCore");
                }
            }
            if (Directory.Exists(destination) || File.Exists(destination))
                throw new IOException("ReflexCore already exists in that location.");
            if (!smoke && MessageBox.Show("Install ReflexCore to:\n" + destination, "ReflexCore Setup",
                    MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return 0;

            var staging = destination + ".staging-" + Guid.NewGuid().ToString("N");
            Directory.CreateDirectory(staging);
            using (var payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("ReflexCore.Payload.zip"))
            using (var zip = new ZipArchive(payload, ZipArchiveMode.Read))
                zip.ExtractToDirectory(staging);

            if (!smoke && !HasFramework())
            {
                string prerequisite = Path.Combine(staging, "Prerequisites", "net48.exe");
                using (var installer = Process.Start(new ProcessStartInfo(prerequisite, "/passive /norestart") { Verb = "runas", UseShellExecute = true }))
                {
                    installer.WaitForExit();
                    if (installer.ExitCode != 0 && installer.ExitCode != 3010 && installer.ExitCode != 1641)
                        throw new InvalidOperationException(".NET Framework 4.8 setup did not finish successfully.");
                }
            }

            Directory.Move(Path.Combine(staging, "ReflexCore"), destination);
            File.Delete(Path.Combine(staging, "Prerequisites", "net48.exe"));
            Directory.Delete(Path.Combine(staging, "Prerequisites"));
            Directory.Delete(staging);
            if (!smoke)
            {
                string menu = Environment.GetFolderPath(Environment.SpecialFolder.Programs);
                dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
                dynamic shortcut = shell.CreateShortcut(Path.Combine(menu, "ReflexCore.lnk"));
                shortcut.TargetPath = Path.Combine(destination, "ReflexCore.exe");
                shortcut.WorkingDirectory = destination;
                shortcut.Save();
                MessageBox.Show("Installed. Open ReflexCore from Start. Restart Windows if the .NET installer requested a restart.",
                    "ReflexCore Setup", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            return 0;
        }
        catch (Exception error)
        {
            if (args.Length == 0) MessageBox.Show(error.Message, "ReflexCore Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static bool HasFramework()
    {
        using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry32))
        using (var key = baseKey.OpenSubKey(@"SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"))
            return key != null && Convert.ToInt32(key.GetValue("Release", 0)) >= 528040;
    }
}
