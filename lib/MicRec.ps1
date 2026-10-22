# Microphone recorder process (WASAPI shared capture → 16 kHz mono 16-bit WAV for whisper.cpp).
# Runs under Windows PowerShell 5.1 (powershell.exe), NOT pwsh: PowerShell 7 from the Microsoft Store is a packaged
# app without the microphone capability — Windows denies it the microphone silently (E_ACCESSDENIED, no prompt).
# Protocol on stdout: "START" when capturing, "LVL <0..32767>" every 250 ms, "DONE <seconds>" at the end,
# "ERR <message>" on failure. Stops on a "STOP" line on stdin or when stdin closes (NetKnife exited).
param([Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = "Stop"
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
namespace NkMic {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo { }
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    interface IMMDeviceEnumerator { int EnumAudioEndpoints(int f, int m, out IntPtr c); int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice d); }
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    interface IMMDevice { int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2")]
    interface IAudioClient {
        int Initialize(int share, int flags, long dur, long per, IntPtr fmt, IntPtr session);
        int GetBufferSize(out uint n); int GetStreamLatency(out long l); int GetCurrentPadding(out uint p);
        int IsFormatSupported(int share, IntPtr fmt, out IntPtr closest); int GetMixFormat(out IntPtr fmt);
        int GetDevicePeriod(out long d, out long m); int Start(); int Stop(); int Reset(); int SetEventHandle(IntPtr h);
        int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    }
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317")]
    interface IAudioCaptureClient { int GetBuffer(out IntPtr data, out uint frames, out uint flags, out long pos, out long qpc); int ReleaseBuffer(uint n); int GetNextPacketSize(out uint n); }

    public static class Rec {
        static volatile bool stop;
        static void Check(int hr, string what) { if (hr != 0) throw new Exception(what + " 0x" + hr.ToString("X8") + (hr == unchecked((int)0x80070005) ? " — доступ к микрофону запрещён (Параметры → Конфиденциальность → Микрофон)" : "")); }

        public static int Run(string path) {
            FileStream fs = null;
            try {
                var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCo();
                IMMDevice dev; Check(en.GetDefaultAudioEndpoint(1, 0, out dev), "нет микрофона по умолчанию:");
                Guid iid = typeof(IAudioClient).GUID; object o; Check(dev.Activate(ref iid, 23, IntPtr.Zero, out o), "микрофон не открылся:");
                var ac = (IAudioClient)o; IntPtr f; Check(ac.GetMixFormat(out f), "формат:");
                int ch = Marshal.ReadInt16(f, 2), rate = Marshal.ReadInt32(f, 4), bits = Marshal.ReadInt16(f, 14);
                Check(ac.Initialize(0, 0, 10000000, 0, f, IntPtr.Zero), "запуск записи:");
                Guid ic = typeof(IAudioCaptureClient).GUID; object co; Check(ac.GetService(ref ic, out co), "захват:");
                var cap = (IAudioCaptureClient)co;
                fs = new FileStream(path, FileMode.Create, FileAccess.Write);
                fs.Write(new byte[44], 0, 44);
                var bw = new BinaryWriter(fs);
                new Thread(() => { try { string l; while ((l = Console.In.ReadLine()) != null) { if (l.Trim() == "STOP") break; } } catch { } stop = true; }) { IsBackground = true }.Start();
                Check(ac.Start(), "старт:");
                Console.Out.WriteLine("START"); Console.Out.Flush();
                double ratio = rate / 16000.0, phase = 0, acc = 0; int cnt = 0, peak = 0, maxAll = 0; long outN = 0;
                var lastLvl = DateTime.Now;
                while (!stop) {
                    Thread.Sleep(10);
                    uint n; cap.GetNextPacketSize(out n);
                    while (n > 0) {
                        IntPtr d; uint fr, fl; long p1, p2;
                        Check(cap.GetBuffer(out d, out fr, out fl, out p1, out p2), "буфер:");
                        bool silent = (fl & 2) != 0;
                        int total = (int)fr * ch;
                        float[] fb = null; short[] sb = null;
                        if (!silent) { if (bits == 32) { fb = new float[total]; Marshal.Copy(d, fb, 0, total); } else { sb = new short[total]; Marshal.Copy(d, sb, 0, total); } }
                        for (int i = 0; i < fr; i++) {
                            double m = 0;
                            if (!silent) { for (int c = 0; c < ch; c++) m += (fb != null) ? fb[i * ch + c] : sb[i * ch + c] / 32768.0; m /= ch; }
                            acc += m; cnt++; phase += 1;
                            if (phase >= ratio) {
                                phase -= ratio;
                                int v = (int)Math.Round(acc / cnt * 32767); if (v > 32767) v = 32767; if (v < -32768) v = -32768;
                                bw.Write((short)v); outN++; acc = 0; cnt = 0;
                                int a = Math.Abs(v); if (a > peak) peak = a; if (a > maxAll) maxAll = a;
                            }
                        }
                        cap.ReleaseBuffer(fr);
                        cap.GetNextPacketSize(out n);
                    }
                    if ((DateTime.Now - lastLvl).TotalMilliseconds >= 250) { Console.Out.WriteLine("LVL " + peak); Console.Out.Flush(); peak = 0; lastLvl = DateTime.Now; }
                }
                ac.Stop();
                bw.Flush();
                long bytes = outN * 2;
                fs.Seek(0, SeekOrigin.Begin);
                bw.Write(new char[] { 'R', 'I', 'F', 'F' }); bw.Write((int)(36 + bytes)); bw.Write(new char[] { 'W', 'A', 'V', 'E' });
                bw.Write(new char[] { 'f', 'm', 't', ' ' }); bw.Write(16); bw.Write((short)1); bw.Write((short)1); bw.Write(16000); bw.Write(32000); bw.Write((short)2); bw.Write((short)16);
                bw.Write(new char[] { 'd', 'a', 't', 'a' }); bw.Write((int)bytes);
                bw.Flush(); fs.Dispose(); fs = null;
                // laptop microphone arrays record quietly: normalise to ~90 % (at most ×20) so whisper hears soft speech
                if (maxAll > 0 && maxAll < 16000 && bytes > 0) {
                    double g = Math.Min(20.0, 29500.0 / maxAll);
                    using (var rw = new FileStream(path, FileMode.Open, FileAccess.ReadWrite)) {
                        var buf = new byte[65536]; rw.Seek(44, SeekOrigin.Begin); long pos = 44;
                        int got;
                        while ((got = rw.Read(buf, 0, buf.Length)) > 0) {
                            for (int k = 0; k + 1 < got; k += 2) {
                                int v = (int)Math.Round(BitConverter.ToInt16(buf, k) * g); if (v > 32767) v = 32767; if (v < -32768) v = -32768;
                                buf[k] = (byte)(v & 0xFF); buf[k + 1] = (byte)((v >> 8) & 0xFF);
                            }
                            rw.Seek(pos, SeekOrigin.Begin); rw.Write(buf, 0, got); pos += got;
                        }
                    }
                }
                Console.Out.WriteLine("DONE " + (outN / 16000.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)); Console.Out.Flush();
                return 0;
            } catch (Exception e) {
                Console.Out.WriteLine("ERR " + e.Message); Console.Out.Flush();
                if (fs != null) try { fs.Dispose(); } catch { }
                return 1;
            }
        }
    }
}
"@
exit [NkMic.Rec]::Run($Out)
