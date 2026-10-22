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
        // from the beacon (information elements): channel width, 802.11k/v/r, security, country
        public int Width = 20; public bool K; public bool V; public bool R; public string Sec = ""; public string Country = "";
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
        const int OffIeOffset = 352, OffIeSize = 356;

        // HT/VHT operation → 20/40/80/160; RM capabilities (11k), extended caps bit 19 (11v BSS transition),
        // Mobility Domain (11r), RSN AKM suites (PSK / SAE / FT), Country
        static void ParseIe(BssInfo b, byte[] ie) {
            bool ht40 = false; int vht = -1, c0 = 0, c1 = 0; bool psk = false, sae = false, ent = false, open = true;
            for (int p = 0; p + 2 <= ie.Length; ) {
                int id = ie[p], len = ie[p + 1], d = p + 2;
                if (d + len > ie.Length) break;
                if (id == 61 && len >= 2) { int off = ie[d + 1] & 3; ht40 = (off == 1 || off == 3) && ((ie[d + 1] >> 2) & 1) == 1; }
                else if (id == 192 && len >= 3) { vht = ie[d]; c0 = ie[d + 1]; c1 = ie[d + 2]; }
                else if (id == 70) b.K = true;
                else if (id == 127 && len >= 3) b.V = ((ie[d + 2] >> 3) & 1) == 1;
                else if (id == 54) b.R = true;
                else if (id == 7 && len >= 2) b.Country = "" + (char)ie[d] + (char)ie[d + 1];
                else if (id == 48 && len >= 8) {
                    open = false;
                    int pc = ie[d + 6] | (ie[d + 7] << 8); int ap = d + 8 + 4 * pc;
                    if (ap + 2 <= d + len) {
                        int ac = ie[ap] | (ie[ap + 1] << 8);
                        for (int q = 0; q < ac && ap + 2 + 4 * q + 3 < d + len; q++) {
                            int t = ie[ap + 2 + 4 * q + 3];
                            if (t == 2 || t == 4 || t == 6) psk = true; else if (t == 8 || t == 9) sae = true; else if (t == 1 || t == 3 || t == 5) ent = true;
                            if (t == 3 || t == 4 || t == 9) b.R = true;
                        }
                    }
                }
                p = d + len;
            }
            int w = ht40 ? 40 : 20;
            if (vht == 1) w = (c1 != 0 && Math.Abs(c1 - c0) == 8) ? 160 : 80;
            else if (vht == 2 || vht == 3) w = 160;
            b.Width = w;
            b.Sec = open ? "open" : ent ? "enterprise" : (psk && sae) ? "WPA2/WPA3" : sae ? "WPA3" : psk ? "WPA2" : "?";
        }

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
                            try {
                                int ieo = Marshal.ReadInt32(e, OffIeOffset), ies = Marshal.ReadInt32(e, OffIeSize);
                                if (ieo > 0 && ies > 0 && ies < 4096) { byte[] ie = new byte[ies]; Marshal.Copy(e + ieo, ie, 0, ies); ParseIe(b, ie); }
                            } catch { }
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

# Current association (which AP the laptop is on right now) + fast probes for the roaming monitor.
# WLAN_CONNECTION_ATTRIBUTES offsets: isState@0, profile@8, SSID@520, BSSID@560, quality@576, rx@580, tx@584 (kbps).
if (-not ("NetKnife.WlanCur" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

namespace NetKnife {
    public class CurInfo {
        public int State; public string Ssid = ""; public string Bssid = ""; public int Rssi; public int Quality;
        public int Channel; public int RxKbps; public int TxKbps; public string Iface = "";
    }

    public static class WlanCur {
        [DllImport("wlanapi.dll")] static extern uint WlanOpenHandle(uint ver, IntPtr res, out uint negotiated, out IntPtr h);
        [DllImport("wlanapi.dll")] static extern uint WlanCloseHandle(IntPtr h, IntPtr res);
        [DllImport("wlanapi.dll")] static extern uint WlanEnumInterfaces(IntPtr h, IntPtr res, out IntPtr list);
        [DllImport("wlanapi.dll")] static extern uint WlanQueryInterface(IntPtr h, ref Guid iface, int op, IntPtr res, out int size, out IntPtr data, out int type);
        [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr p);

        static IntPtr handle = IntPtr.Zero;
        static readonly object gate = new object();

        static int QueryInt(ref Guid g, int op, int dflt) {
            int size, type; IntPtr data;
            if (WlanQueryInterface(handle, ref g, op, IntPtr.Zero, out size, out data, out type) != 0) return dflt;
            try { return Marshal.ReadInt32(data); } finally { WlanFreeMemory(data); }
        }

        // State: 1 connected, 3 disconnecting, 4 disconnected, 5 associating, 6 discovering, 7 authenticating
        public static CurInfo Current() {
            lock (gate) {
                var c = new CurInfo { State = 4 };
                if (handle == IntPtr.Zero) { uint neg; if (WlanOpenHandle(2, IntPtr.Zero, out neg, out handle) != 0) { handle = IntPtr.Zero; return c; } }
                IntPtr il;
                if (WlanEnumInterfaces(handle, IntPtr.Zero, out il) != 0) { WlanCloseHandle(handle, IntPtr.Zero); handle = IntPtr.Zero; return c; }
                try {
                    int n = Marshal.ReadInt32(il, 0);
                    for (int i = 0; i < n; i++) {
                        IntPtr p = il + 8 + i * 532;
                        byte[] gb = new byte[16]; Marshal.Copy(p, gb, 0, 16);
                        Guid g = new Guid(gb);
                        int state = Marshal.ReadInt32(p, 528);
                        if (i == 0 || state == 1) { c.State = state; c.Iface = Marshal.PtrToStringUni(p + 16); }
                        if (state != 1) continue;
                        int size, type; IntPtr data;
                        if (WlanQueryInterface(handle, ref g, 7, IntPtr.Zero, out size, out data, out type) == 0) {   // current_connection
                            try {
                                int slen = Math.Min(Marshal.ReadInt32(data, 520), 32);
                                byte[] sb = new byte[32]; Marshal.Copy(data + 524, sb, 0, 32);
                                c.Ssid = System.Text.Encoding.UTF8.GetString(sb, 0, slen);
                                byte[] mac = new byte[6]; Marshal.Copy(data + 560, mac, 0, 6);
                                c.Bssid = BitConverter.ToString(mac).Replace('-', ':');
                                c.Quality = Marshal.ReadInt32(data, 576);
                                c.RxKbps = Marshal.ReadInt32(data, 580);
                                c.TxKbps = Marshal.ReadInt32(data, 584);
                            } finally { WlanFreeMemory(data); }
                        }
                        c.Channel = QueryInt(ref g, 8, 0);                                  // channel_number
                        c.Rssi = QueryInt(ref g, 0x10000102, c.Quality / 2 - 100);          // rssi (dBm), fallback from quality
                        break;
                    }
                } finally { WlanFreeMemory(il); }
                return c;
            }
        }
    }

    public static class Probe {
        [DllImport("iphlpapi.dll")] static extern int SendARP(uint dest, uint src, byte[] mac, ref uint len);

        public static string ArpMac(string ip) {
            try {
                uint d = BitConverter.ToUInt32(IPAddress.Parse(ip).GetAddressBytes(), 0);
                byte[] m = new byte[6]; uint l = 6;
                if (SendARP(d, 0, m, ref l) != 0 || l == 0) return "";
                return BitConverter.ToString(m, 0, (int)l).Replace('-', ':');
            } catch { return ""; }
        }
        public static Task<string> ArpMacAsync(string ip) { return Task.Run(() => ArpMac(ip)); }

        // Raw UDP query straight to the server (bypasses the Windows DNS cache). ms on any answer, -1 on timeout.
        public static int Dns(string server, string name, int timeoutMs) {
            var sw = Stopwatch.StartNew();
            try {
                using (var u = new UdpClient()) {
                    u.Client.ReceiveTimeout = timeoutMs;
                    var rnd = new Random();
                    ushort id = (ushort)rnd.Next(1, 65535);
                    var pkt = new System.Collections.Generic.List<byte> { (byte)(id >> 8), (byte)id, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
                    foreach (var label in name.Split('.')) { pkt.Add((byte)label.Length); pkt.AddRange(System.Text.Encoding.ASCII.GetBytes(label)); }
                    pkt.AddRange(new byte[] { 0, 0, 1, 0, 1 });
                    u.Send(pkt.ToArray(), pkt.Count, new IPEndPoint(IPAddress.Parse(server), 53));
                    var ep = new IPEndPoint(IPAddress.Any, 0);
                    while (sw.ElapsedMilliseconds < timeoutMs) {
                        var r = u.Receive(ref ep);
                        if (r.Length > 3 && r[0] == (byte)(id >> 8) && r[1] == (byte)id) return (int)sw.ElapsedMilliseconds;
                    }
                }
            } catch { }
            return -1;
        }
        public static Task<int> DnsAsync(string server, string name, int timeoutMs) { return Task.Run(() => Dns(server, name, timeoutMs)); }
    }
}
'@
}
