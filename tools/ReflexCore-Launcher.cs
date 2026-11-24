using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class ReflexCoreLauncher
{
    [STAThread]
    private static void Main()
    {
        try
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string entry = Path.Combine(root, "tools", "ReflexCore-ControlCenter.ps1");
            if (!File.Exists(entry))
                throw new FileNotFoundException("ReflexCore Studio could not be found.");
            string shell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            Process.Start(new ProcessStartInfo
            {
                FileName = shell,
                Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File \"" + entry + "\"",
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = true
            });
        }
        catch (Exception error)
        {
            MessageBox.Show(error.Message, "ReflexCore", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
