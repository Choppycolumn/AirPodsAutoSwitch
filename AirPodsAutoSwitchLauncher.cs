using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

internal static class AirPodsAutoSwitchLauncher
{
    [STAThread]
    private static int Main()
    {
        string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        string scriptPath = Path.Combine(baseDirectory, "AirPodsAutoSwitchApp.ps1");

        if (!File.Exists(scriptPath))
        {
            MessageBox.Show(
                "AirPodsAutoSwitchApp.ps1 was not found next to the launcher.",
                "AirPods Auto Switch",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 2;
        }

        ProcessStartInfo startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File " + Quote(scriptPath),
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = baseDirectory
        };

        try
        {
            using (Process process = Process.Start(startInfo))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                "Could not start PowerShell: " + ex.Message,
                "AirPods Auto Switch",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error);
            return 1;
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }
}
