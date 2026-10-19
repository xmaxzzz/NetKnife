# MikroTik discovery (MNDP, as Winbox does). UDP 5678: a 4-byte zero request to broadcast makes routers answer;
# they also announce on their own every ~30–60 s. Answer = 4-byte header + TLVs (type BE16, len BE16):
# 1 MAC, 5 identity, 7 version, 8 platform, 10 uptime, 12 board, 16 interface, 17 IPv4.

if (-not ("NetKnife.Mndp" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace NetKnife {
    public class MndpInfo {
        public string Mac = ""; public string Identity = ""; public string Version = ""; public string Platform = "";
        public string Board = ""; public string Ip = ""; public string Iface = ""; public long UptimeSec; public string From = "";
    }

    public static class Mndp {
        static int Be16(byte[] b, int i) { return (b[i] << 8) | b[i + 1]; }

        public static MndpInfo Parse(byte[] d, IPEndPoint from) {
            if (d.Length < 8) return null;
            var m = new MndpInfo { From = from.Address.ToString() };
            int i = 4;
            while (i + 4 <= d.Length) {
                int t = Be16(d, i), l = Be16(d, i + 2); i += 4;
                if (i + l > d.Length) break;
                switch (t) {
                    case 1: if (l == 6) m.Mac = BitConverter.ToString(d, i, 6).Replace('-', ':'); break;
                    case 5: m.Identity = Encoding.UTF8.GetString(d, i, l); break;
                    case 7: m.Version = Encoding.UTF8.GetString(d, i, l); break;
                    case 8: m.Platform = Encoding.UTF8.GetString(d, i, l); break;
                    case 10: if (l == 4) m.UptimeSec = BitConverter.ToUInt32(d, i); break;
                    case 12: m.Board = Encoding.UTF8.GetString(d, i, l); break;
                    case 16: m.Iface = Encoding.UTF8.GetString(d, i, l); break;
                    case 17: if (l == 4) m.Ip = new IPAddress(new byte[] { d[i], d[i + 1], d[i + 2], d[i + 3] }).ToString(); break;
                }
                i += l;
            }
            if (m.Ip == "") m.Ip = m.From;
            return (m.Mac == "" && m.Identity == "") ? null : m;
        }

        public static List<MndpInfo> Discover(int listenMs) {
            var found = new Dictionary<string, MndpInfo>();
            using (var u = new UdpClient()) {
                u.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                u.Client.Bind(new IPEndPoint(IPAddress.Any, 5678));
                u.EnableBroadcast = true;
                var req = new byte[4];
                var targets = new List<IPAddress> { IPAddress.Broadcast };
                foreach (var nic in NetworkInterface.GetAllNetworkInterfaces()) {
                    if (nic.OperationalStatus != OperationalStatus.Up) continue;
                    foreach (var ua in nic.GetIPProperties().UnicastAddresses) {
                        if (ua.Address.AddressFamily != AddressFamily.InterNetwork || ua.IPv4Mask == null) continue;
                        byte[] a = ua.Address.GetAddressBytes(), mk = ua.IPv4Mask.GetAddressBytes();
                        if (a[0] == 127 || (a[0] == 169 && a[1] == 254)) continue;
                        var bc = new byte[4];
                        for (int k = 0; k < 4; k++) bc[k] = (byte)(a[k] | ~mk[k]);
                        targets.Add(new IPAddress(bc));
                    }
                }
                var deadline = DateTime.UtcNow.AddMilliseconds(listenMs);
                int round = 0;
                while (DateTime.UtcNow < deadline) {
                    if (round++ % 20 == 0) foreach (var t in targets) { try { u.Send(req, req.Length, new IPEndPoint(t, 5678)); } catch { } }
                    if (u.Available > 0) {
                        var ep = new IPEndPoint(IPAddress.Any, 0);
                        byte[] d;
                        try { d = u.Receive(ref ep); } catch { continue; }
                        var m = Parse(d, ep);
                        if (m != null) found[m.Mac != "" ? m.Mac : m.Ip] = m;
                    } else System.Threading.Thread.Sleep(50);
                }
            }
            return new List<MndpInfo>(found.Values);
        }
    }
}
'@
}

$script:MndpBody = {
    param($Q, $Ctl, $Ms)
    try {
        $L = [NetKnife.Mndp]::Discover($Ms)
        # which SSH port answers: our objects use 10322, factory routers 22
        foreach ($M in $L) {
            $Port = 0
            foreach ($P in @(10322, 22)) {
                try { $T = New-Object System.Net.Sockets.TcpClient; $A = $T.BeginConnect($M.Ip, $P, $null, $null); if ($A.AsyncWaitHandle.WaitOne(700) -and $T.Connected) { $Port = $P }; $T.Close() } catch { }
                if ($Port) { break }
            }
            $Q.Enqueue(@{ Type = "mndp"; Mac = $M.Mac; Identity = $M.Identity; Version = $M.Version; Board = $M.Board; Ip = $M.Ip; Iface = $M.Iface; Uptime = $M.UptimeSec; Port = $Port })
        }
        $Q.Enqueue(@{ Type = "mndpdone"; Count = $L.Count })
    } catch { $Q.Enqueue(@{ Type = "mndpdone"; Count = -1; Error = "$($_.Exception.Message)" }) }
}

# Scan → list of found routers → pick one → router card prefilled → test → offer to prepare netknife
function Start-MtDiscovery {
    param([scriptblock]$Status)
    if (Test-WorkerRunning "mndp") { return }
    if (-not $Status) { $Status = { param($T, $K) Set-MtStatus $T $K } }
    $script:MtFound = [System.Collections.Generic.List[object]]::new()
    $script:MtDiscStatus = $Status
    & $Status "Ищу MikroTik в локальной сети (MNDP, как Winbox)… ~6 с" "wait"
    [void](Start-Worker -Name "mndp" -Body $script:MndpBody -ArgList @(5000) -OnMessage {
        param($M)
        if ($M.Type -eq "mndp") { $script:MtFound.Add($M) }
        elseif ($M.Type -eq "mndpdone") {
            if ($M.Count -lt 0) { & $script:MtDiscStatus "Поиск не удался: $($M.Error) (порт 5678 занят — закрой Winbox)" "fail"; return }
            if (-not $script:MtFound.Count) { & $script:MtDiscStatus "MikroTik не найдены. Ноутбук должен быть в той же сети, на роутере включён Neighbor Discovery (IP → Neighbors → Discovery Settings)" "fail"; return }
            & $script:MtDiscStatus "Найдено роутеров: $($script:MtFound.Count)" "ok"
            Show-MtFoundDialog
        }
    })
}

function Show-MtFoundDialog {
    $Known = @(Get-MtRouters | ForEach-Object { $_.Host })
    $D = New-Dialog "Найденные MikroTik" @"
<StackPanel>
    <TextBlock Text="Найденные MikroTik" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="Выбери роутер — откроется карточка с подставленными данными, затем проверка и предложение подготовить пользователя netknife." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,12" FontSize="12.5"/>
    <ListBox x:Name="FList" Height="220" Background="Transparent" BorderThickness="1" BorderBrush="{StaticResource Line}" Foreground="{StaticResource Text}" FontFamily="{StaticResource MonoFont}" FontSize="12"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button Style="{StaticResource Btn}" Content="Закрыть" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Добавить и настроить" MinWidth="170" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@ 760
    $FList = $D.FindName("FList")
    $Items = @($script:MtFound | Sort-Object { $_.Identity } | ForEach-Object {
        [pscustomobject]@{ M = $_; Label = ("{0,-22} {1,-16} {2}  {3,-12} v{4}  {5}{6}" -f $_.Identity, $_.Ip, $_.Mac, $_.Board, ("$($_.Version)" -split " ")[0], $(if ($_.Port) { "ssh:$($_.Port)" } else { "ssh закрыт" }), $(if ($Known -contains $_.Ip) { "  · уже добавлен" } else { "" })) }
    })
    $FList.ItemsSource = $Items; $FList.DisplayMemberPath = "Label"; if ($Items.Count) { $FList.SelectedIndex = 0 }
    $D.FindName("FOk").Add_Click({ if ($FList.SelectedItem) { $D.DialogResult = $true } })
    $FList.Add_MouseDoubleClick({ if ($FList.SelectedItem) { $D.DialogResult = $true } })
    if (-not $D.ShowDialog()) { return }
    $M = $FList.SelectedItem.M
    $Ex = @(Get-MtRouters) | Where-Object { $_.Host -eq $M.Ip } | Select-Object -First 1
    $script:MtOfferPrep = $true
    if ($Ex) { Show-MtRouterDialog $Ex; return }
    Show-MtRouterDialog @{ Id = ""; Name = $(if ($M.Identity) { $M.Identity } else { $M.Ip }); Host = $M.Ip; Port = $(if ($M.Port) { $M.Port } else { 10322 })
        Admin = $(if ($M.Port -eq 22) { "admin" } else { "butler" }); AdminKey = "~/.ssh/mikrotik_rsa"; Ready = $false; PassEnc = "" }
}
