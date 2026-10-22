# Microphone recorder for the voice-annotated Wi-Fi walk: winmm waveIn, 16 kHz mono 16-bit PCM (what whisper.cpp
# wants), written straight to a WAV file by a background thread (no window message loop needed — MCI "record"
# hangs without one). Peak gives a live level meter; Started is the wall-clock time of sample 0, so whisper's
# segment offsets map back to the Wi-Fi samples.

if (-not ("NetKnife.MicRec" -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace NetKnife {
    public class MicRec {
        [StructLayout(LayoutKind.Sequential)] struct WAVEFORMATEX { public ushort wFormatTag, nChannels; public uint nSamplesPerSec, nAvgBytesPerSec; public ushort nBlockAlign, wBitsPerSample, cbSize; }
        [StructLayout(LayoutKind.Sequential)] struct WAVEHDR { public IntPtr lpData; public uint dwBufferLength, dwBytesRecorded; public IntPtr dwUser; public uint dwFlags, dwLoops; public IntPtr lpNext, reserved; }
        [DllImport("winmm.dll")] static extern int waveInOpen(out IntPtr h, int dev, ref WAVEFORMATEX fmt, IntPtr cb, IntPtr inst, int flags);
        [DllImport("winmm.dll")] static extern int waveInPrepareHeader(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll")] static extern int waveInUnprepareHeader(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll")] static extern int waveInAddBuffer(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll")] static extern int waveInStart(IntPtr h);
        [DllImport("winmm.dll")] static extern int waveInStop(IntPtr h);
        [DllImport("winmm.dll")] static extern int waveInReset(IntPtr h);
        [DllImport("winmm.dll")] static extern int waveInClose(IntPtr h);
        [DllImport("winmm.dll")] static extern int waveInGetNumDevs();
        const int Rate = 16000, BufBytes = 8000, NBuf = 8;   // 0.25 s per buffer
        const uint WHDR_DONE = 1;

        IntPtr h; IntPtr[] hdrs = new IntPtr[NBuf]; IntPtr[] data = new IntPtr[NBuf];
        FileStream fs; Thread th; volatile bool stop;
        public DateTime Started; public long Bytes; public volatile int Peak; public string Error = "";
        public double Seconds { get { return Bytes / 2.0 / Rate; } }
        public static int Devices() { return waveInGetNumDevs(); }

        public bool Start(string path) {
            if (waveInGetNumDevs() < 1) { Error = "нет микрофона"; return false; }
            var f = new WAVEFORMATEX { wFormatTag = 1, nChannels = 1, nSamplesPerSec = Rate, nAvgBytesPerSec = Rate * 2, nBlockAlign = 2, wBitsPerSample = 16, cbSize = 0 };
            int r = waveInOpen(out h, -1, ref f, IntPtr.Zero, IntPtr.Zero, 0);
            if (r != 0) { Error = "waveInOpen " + r; return false; }
            fs = new FileStream(path, FileMode.Create, FileAccess.Write);
            fs.Write(new byte[44], 0, 44);   // header is written on Stop
            int hs = Marshal.SizeOf(typeof(WAVEHDR));
            for (int i = 0; i < NBuf; i++) {
                data[i] = Marshal.AllocHGlobal(BufBytes);
                hdrs[i] = Marshal.AllocHGlobal(hs);
                Marshal.StructureToPtr(new WAVEHDR { lpData = data[i], dwBufferLength = BufBytes }, hdrs[i], false);
                waveInPrepareHeader(h, hdrs[i], hs);
                waveInAddBuffer(h, hdrs[i], hs);
            }
            stop = false; Bytes = 0;
            r = waveInStart(h);
            if (r != 0) { Error = "waveInStart " + r; Cleanup(); return false; }
            Started = DateTime.Now;
            th = new Thread(Loop) { IsBackground = true }; th.Start();
            return true;
        }

        void Loop() {
            int hs = Marshal.SizeOf(typeof(WAVEHDR));
            var buf = new byte[BufBytes];
            while (!stop) {
                bool any = false;
                for (int i = 0; i < NBuf; i++) {
                    var w = (WAVEHDR)Marshal.PtrToStructure(hdrs[i], typeof(WAVEHDR));
                    if ((w.dwFlags & WHDR_DONE) == 0) continue;
                    any = true;
                    int n = (int)w.dwBytesRecorded;
                    if (n > 0) {
                        Marshal.Copy(w.lpData, buf, 0, n);
                        lock (this) { fs.Write(buf, 0, n); Bytes += n; }
                        int pk = 0; for (int k = 0; k + 1 < n; k += 2) { int v = Math.Abs((int)BitConverter.ToInt16(buf, k)); if (v > pk) pk = v; }
                        Peak = pk;
                    }
                    if (stop) break;
                    w.dwFlags &= ~WHDR_DONE; w.dwBytesRecorded = 0;
                    Marshal.StructureToPtr(w, hdrs[i], false);
                    waveInAddBuffer(h, hdrs[i], hs);
                }
                if (!any) Thread.Sleep(20);
            }
        }

        public void Stop() {
            if (h == IntPtr.Zero) return;
            stop = true;
            if (th != null) th.Join(1000);
            waveInStop(h); waveInReset(h);
            Cleanup();
        }

        void Cleanup() {
            int hs = Marshal.SizeOf(typeof(WAVEHDR));
            for (int i = 0; i < NBuf; i++) {
                if (hdrs[i] != IntPtr.Zero) { waveInUnprepareHeader(h, hdrs[i], hs); Marshal.FreeHGlobal(hdrs[i]); hdrs[i] = IntPtr.Zero; }
                if (data[i] != IntPtr.Zero) { Marshal.FreeHGlobal(data[i]); data[i] = IntPtr.Zero; }
            }
            if (h != IntPtr.Zero) { waveInClose(h); h = IntPtr.Zero; }
            if (fs != null) {
                lock (this) {
                    fs.Seek(0, SeekOrigin.Begin);
                    var bw = new BinaryWriter(fs);
                    bw.Write(new char[] { 'R', 'I', 'F', 'F' }); bw.Write((int)(36 + Bytes)); bw.Write(new char[] { 'W', 'A', 'V', 'E' });
                    bw.Write(new char[] { 'f', 'm', 't', ' ' }); bw.Write(16); bw.Write((short)1); bw.Write((short)1); bw.Write(Rate); bw.Write(Rate * 2); bw.Write((short)2); bw.Write((short)16);
                    bw.Write(new char[] { 'd', 'a', 't', 'a' }); bw.Write((int)Bytes);
                    bw.Flush(); fs.Dispose(); fs = null;
                }
            }
        }
    }
}
"@
}
