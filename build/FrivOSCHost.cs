// Native Windows host for FrivOSC's PowerShell UI scripts. The form runs inside
// this executable's STA runspace, so Task Manager identifies it as FrivOSC.

using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("FrivOSC")]
[assembly: AssemblyDescription("FrivOSC desktop host")]
[assembly: AssemblyCompany("Friday")]
[assembly: AssemblyProduct("FrivOSC")]
// Generated from the VERSION file at the repo root by
// Build-FrivOSCInstaller.ps1 and compiled in alongside this file. Written
// here originally, which is how this exe said 1.0.0 while the service said
// 1.1.0 — before anything had even shipped.

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        string script = null;
        for (var index = 0; index < args.Length; index++)
        {
            if (string.Equals(args[index], "--script", StringComparison.OrdinalIgnoreCase) && index + 1 < args.Length)
                script = args[++index];
        }

        if (string.IsNullOrWhiteSpace(script) || !File.Exists(script))
        {
            MessageBox.Show("FrivOSC's startup script could not be found.", "FrivOSC",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        try
        {
            Directory.SetCurrentDirectory(Path.GetDirectoryName(Path.GetFullPath(script)));
            using (var runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = System.Threading.ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.ReuseThread;
                runspace.Open();
                using (var powerShell = PowerShell.Create())
                {
                    powerShell.Runspace = runspace;
                    powerShell.AddScript("Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force");
                    powerShell.Invoke();
                    if (powerShell.HadErrors)
                        throw new InvalidOperationException("Unable to set the process execution policy.");

                    powerShell.Commands.Clear();
                    powerShell.Streams.Error.Clear();
                    powerShell.AddCommand(script);
                    powerShell.Invoke();
                    if (powerShell.HadErrors)
                    {
                        var message = "FrivOSC could not start.";
                        if (powerShell.Streams.Error.Count > 0)
                            message += "\r\n\r\n" + powerShell.Streams.Error[0];
                        MessageBox.Show(message, "FrivOSC", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 1;
                    }
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            MessageBox.Show("FrivOSC could not start.\r\n\r\n" + error.Message, "FrivOSC",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
