# Microphone for the voice-annotated Wi-Fi walk. The capture itself runs in a helper process — lib\MicRec.ps1
# under Windows PowerShell 5.1 (WASAPI → 16 kHz mono WAV): PowerShell 7 from the Microsoft Store is a packaged app
# without the microphone capability, so Windows silently denies it the microphone (no prompt, E_ACCESSDENIED).
# NetKnife.MicProc keeps the old recorder's surface: Start(path) / Stop() / Started / Peak / Seconds / Error.

$script:MicHelper = Join-Path $PSScriptRoot "MicRec.ps1"

if (-not ("NetKnife.MicProc" -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Threading;

namespace NetKnife {
    public class MicProc {
        readonly string helper; Process p; readonly ManualResetEventSlim ready = new ManualResetEventSlim(false);
        public DateTime Started; public volatile int Peak; public string Error = ""; public double Done = -1;
        public double Seconds { get { return Done >= 0 ? Done : (Started == default(DateTime) ? 0 : (DateTime.Now - Started).TotalSeconds); } }
        public MicProc(string helperPath) { helper = helperPath; }

        public bool Start(string path) {
            try {
                var psi = new ProcessStartInfo("powershell.exe");
                psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + helper + "\" -Out \"" + path + "\"";
                psi.UseShellExecute = false; psi.CreateNoWindow = true;
                psi.RedirectStandardInput = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
                p = Process.Start(psi);
                var t = new Thread(Read) { IsBackground = true }; t.Start();
                p.ErrorDataReceived += (s, e) => { if (!string.IsNullOrEmpty(e.Data) && Error == "") Error = e.Data; };
                p.BeginErrorReadLine();
                // the helper compiles its WASAPI code first (~1–3 s)
                if (!ready.Wait(15000)) { Error = "микрофон не ответил за 15 с"; Kill(); return false; }
                if (Started == default(DateTime)) { Kill(); return false; }
                return true;
            } catch (Exception e) { Error = e.Message; return false; }
        }

        void Read() {
            try {
                string l;
                while ((l = p.StandardOutput.ReadLine()) != null) {
                    if (l == "START") { Started = DateTime.Now; ready.Set(); }
                    else if (l.StartsWith("LVL ")) { int v; if (int.TryParse(l.Substring(4), out v)) Peak = v; }
                    else if (l.StartsWith("DONE ")) { double d; if (double.TryParse(l.Substring(5), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out d)) Done = d; }
                    else if (l.StartsWith("ERR ")) { Error = l.Substring(4); ready.Set(); }
                }
            } catch { }
            ready.Set();
        }

        public void Stop() {
            if (p == null) return;
            try { p.StandardInput.WriteLine("STOP"); p.StandardInput.Flush(); } catch { }
            if (!p.WaitForExit(8000)) Kill();
        }

        void Kill() { try { if (p != null && !p.HasExited) p.Kill(); } catch { } }
    }
}
"@
}
