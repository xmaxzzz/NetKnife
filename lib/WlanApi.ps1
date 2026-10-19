# Native WLAN API (wlanapi.dll): triggers a fresh scan and reads the BSS list with RSSI in dBm and the centre
# frequency. netsh only shows the OS cache (up to a minute old) and a 0-100 "signal" percentage — useless for
# a site survey. Entries older than ~6 s relative to the newest one are dropped as stale cache.

if (-not ("NetKnife.Wlan" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace NetKnife {
    public class BssInfo {
        public string Ssid; public string Bssid; public int Rssi; public int Quality;
        public int FreqMHz; public int Channel; public string Band; public string Iface;
    }

    public static class Wlan {
        [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint ver, IntPtr res, out uint negotiated, out IntPtr h);
        [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr h, IntPtr res);
        [DllImport("wlanapi.dll")] static extern uint WlanEnumInterfaces(IntPtr h, IntPtr res, out IntPtr list);
        [DllImport("wlanapi.dll")] static extern uint WlanScan(IntPtr h, ref Guid iface, IntPtr ssid, IntPtr ie, IntPtr res);
        [DllImport("wlanapi.dll")] static extern uint WlanGetNetworkBssList(IntPtr h, ref Guid iface, IntPtr ssid, int bssType, bool secOnly, IntPtr res, out IntPtr list);
        [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr p);

        public static int Channel(int f) {
            if (f == 2484) return 14;
            if (f >= 2412 && f < 2484) return (f - 2407) / 5;
            if (f >= 5150 && f < 5925) return (f - 5000) / 5;
            if (f >= 5925 && f < 7125) return (f - 5950) / 5;
            return 0;
        }

        // WLAN_BSS_ENTRY is 360 bytes; offsets per wlanapi.h (natural alignment)
        const int EntrySize = 360, OffBssid = 40, OffRssi = 56, OffQuality = 60, OffHostTs = 80, OffFreq = 92;
        const int IfaceInfoSize = 532;   // GUID + WCHAR[256] + state

        public static List<BssInfo> Scan(int waitMs) {
            var result = new List<BssInfo>();
            uint neg; IntPtr h;
            uint r = WlanOpenHandle(2, IntPtr.Zero, out neg, out h);
            if (r != 0) throw new Exception("WlanOpenHandle: код " + r + (r == 1062 ? " (служба WLAN AutoConfig не запущена)" : ""));
            try {
                IntPtr il;
                r = WlanEnumInterfaces(h, IntPtr.Zero, out il);
                if (r != 0) throw new Exception("WlanEnumInterfaces: код " + r);
                var ifaces = new List<KeyValuePair<Guid, string>>();
                try {
                    int n = Marshal.ReadInt32(il, 0);
                    for (int i = 0; i < n; i++) {
                        IntPtr p = il + 8 + i * IfaceInfoSize;
                        byte[] g = new byte[16]; Marshal.Copy(p, g, 0, 16);
                        ifaces.Add(new KeyValuePair<Guid, string>(new Guid(g), Marshal.PtrToStringUni(p + 16)));
                    }
                } finally { WlanFreeMemory(il); }
                if (ifaces.Count == 0) throw new Exception("нет Wi-Fi адаптера");

                if (waitMs > 0) {
                    foreach (var f in ifaces) { Guid g = f.Key; WlanScan(h, ref g, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero); }
                    Thread.Sleep(waitMs);
                }

                foreach (var f in ifaces) {
                    Guid g = f.Key; IntPtr bl;
                    uint br = WlanGetNetworkBssList(h, ref g, IntPtr.Zero, 3, false, IntPtr.Zero, out bl);
                    if (br == 5) throw new Exception("доступ к Wi-Fi запрещён: включи «Расположение» в Параметрах Windows → Конфиденциальность");
                    if (br != 0) continue;
                    try {
                        int n = Marshal.ReadInt32(bl, 4);
                        var tmp = new List<KeyValuePair<long, BssInfo>>();
                        long maxTs = 0;
                        for (int i = 0; i < n; i++) {
                            IntPtr e = bl + 8 + i * EntrySize;
                            int slen = Math.Min(Marshal.ReadInt32(e, 0), 32);
                            byte[] sb = new byte[32]; Marshal.Copy(e + 4, sb, 0, 32);
                            byte[] mac = new byte[6]; Marshal.Copy(e + OffBssid, mac, 0, 6);
                            long ts = Marshal.ReadInt64(e, OffHostTs);
                            int freq = Marshal.ReadInt32(e, OffFreq) / 1000;
                            var b = new BssInfo {
                                Ssid = slen > 0 ? System.Text.Encoding.UTF8.GetString(sb, 0, slen) : "",
                                Bssid = BitConverter.ToString(mac).Replace('-', ':'),
                                Rssi = Marshal.ReadInt32(e, OffRssi),
                                Quality = Marshal.ReadInt32(e, OffQuality),
                                FreqMHz = freq, Channel = Channel(freq),
                                Band = freq < 3000 ? "2.4" : (freq < 5925 ? "5" : "6"),
                                Iface = f.Value
                            };
                            if (ts > maxTs) maxTs = ts;
                            tmp.Add(new KeyValuePair<long, BssInfo>(ts, b));
                        }
                        foreach (var kv in tmp) if (kv.Key >= maxTs - 60000000L) result.Add(kv.Value);   // 6 s in 100 ns units
                    } finally { WlanFreeMemory(bl); }
                }
            } finally { WlanCloseHandle(h, IntPtr.Zero); }
            return result;
        }
    }
}
'@
}
