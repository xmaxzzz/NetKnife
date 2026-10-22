# Floor plan of a site (wizard step «План»): picture from PNG/JPG/PDF or the clipboard, rooms (recognised by the AI
# or drawn by hand) and where each AP hangs. Stored in the site plan: plan.Floor = @{ Image; W; H; Rooms = @(@{
# Name; X; Y; W; H }); Aps = @{ apKey = @{ X; Y } } } — all coordinates are fractions of the picture (0..1).
# The same view (New-FloorView) is reused by the walk step to show the route and the signal on top of the plan.

$script:FloorPdfTool = Join-Path $PSScriptRoot "..\lib\PdfPage.ps1"

function Get-Floor {
    if (-not $script:Wplan) { return $null }
    if (-not $script:Wplan.Floor) { $script:Wplan.Floor = @{ Image = ""; W = 0; H = 0; Rooms = @(); Aps = @{} } }
    $F = $script:Wplan.Floor
    if (-not $F.Rooms) { $F.Rooms = @() }
    if (-not $F.Aps) { $F.Aps = @{} }
    # v2026.10.15.22 stored every click as 0 or 1 ([Math]::Min(1, x) picked the Int32 overload): such AP
    # positions are dropped once, so the APs show as not placed and get placed again
    if (-not $F.V) {
        foreach ($K in @($F.Aps.Keys)) { $A = $F.Aps[$K]; if (([double]$A.X -eq 0 -or [double]$A.X -eq 1) -and ([double]$A.Y -eq 0 -or [double]$A.Y -eq 1)) { [void]$F.Aps.Remove($K) } }
        $F.V = 2
    }
    return $F
}

function Get-FloorImagePath {
    $F = Get-Floor
    if (-not $F -or -not $F.Image) { return "" }
    $P = Join-Path $script:WplanDir $F.Image
    if (Test-Path $P) { return $P } else { return "" }
}

function Get-FloorRoomAt {
    param([double]$X, [double]$Y)
    $F = Get-Floor
    if (-not $F) { return $null }
    # the smallest room containing the point wins (a hall drawn around rooms must not swallow them)
    return @($F.Rooms | Where-Object { $X -ge $_.X -and $X -le ($_.X + $_.W) -and $Y -ge $_.Y -and $Y -le ($_.Y + $_.H) } | Sort-Object { $_.W * $_.H }) | Select-Object -First 1
}

function Get-FloorRoomCenter {
    param([string]$Name)
    $F = Get-Floor
    $R = @($F.Rooms | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
    if ($R) { return @{ X = $R.X + $R.W / 2; Y = $R.Y + $R.H / 2 } }
    return $null
}

# ---------------------------------------------------------------- scale (metres)

# Floor.Scale = @{ X1; Y1; X2; Y2; Mm } — a line drawn along a dimension line of the plan and its real length
function Get-FloorMPerPx {
    $F = Get-Floor
    $S = $(if ($F) { $F.Scale } else { $null })
    if (-not $S -or -not $F.W -or -not $S.Mm) { return 0.0 }
    $Dx = ([double]$S.X2 - [double]$S.X1) * $F.W; $Dy = ([double]$S.Y2 - [double]$S.Y1) * $F.H
    $Px = [Math]::Sqrt($Dx * $Dx + $Dy * $Dy)
    if ($Px -lt 1.0) { return 0.0 }
    return ([double]$S.Mm / 1000.0) / $Px
}

# distance in metres between two plan points (fractions), or $null without a scale
function Get-FloorDist {
    param($A, $B)
    $K = Get-FloorMPerPx
    if (-not $K -or -not $A -or -not $B) { return $null }
    $F = Get-Floor
    $Dx = ([double]$B.X - [double]$A.X) * $F.W; $Dy = ([double]$B.Y - [double]$A.Y) * $F.H
    return [Math]::Sqrt($Dx * $Dx + $Dy * $Dy) * $K
}

function Format-FloorM { param($M) if ($null -eq $M) { return "" }; return ("{0:N1} м" -f [double]$M) }

function Get-FloorRoomSize {
    param($R)
    $K = Get-FloorMPerPx; $F = Get-Floor
    if (-not $K) { return "" }
    return ("{0:N1}×{1:N1} м" -f ($R.W * $F.W * $K), ($R.H * $F.H * $K))
}

# free-space path loss, dB (d in metres, Wi-Fi channel → frequency)
function Get-FloorFspl {
    param([double]$D, [int]$Ch)
    $Mhz = $(if ($Ch -le 14) { 2407 + 5 * $Ch } else { 5000 + 5 * $Ch })
    return 20 * [Math]::Log10([Math]::Max(1.0, $D)) + 20 * [Math]::Log10($Mhz) - 27.55
}

# "2900", "2 900", "2900 мм", "2,9 м", "2.9m" → millimetres
function ConvertTo-FloorMm {
    param([string]$S)
    $T = ($S -replace '\s', '').ToLower().Replace(",", ".")
    if ($T -notmatch '^(\d+(\.\d+)?)(мм|mm|см|cm|м|m)?$') { return 0 }
    $V = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
    switch ($Matches[3]) { { $_ -in @("м", "m") } { return $V * 1000 } { $_ -in @("см", "cm") } { return $V * 10 } default { return $(if ($V -lt 100 -and $T.Contains(".")) { $V * 1000 } else { $V }) } }
}

# ---------------------------------------------------------------- import

# any BitmapSource → <site>.floor.png (longest side ≤ 3000 px) → plan.Floor
function Save-FloorBitmap {
    param($Bmp)
    $F = Get-Floor
    if (-not $F) { Show-Toast "Сначала выбери объект (шаг 1)" "warn"; return }
    $Max = [Math]::Max($Bmp.PixelWidth, $Bmp.PixelHeight)
    if ($Max -gt 3000) { $K = 3000.0 / $Max; $Bmp = New-Object System.Windows.Media.Imaging.TransformedBitmap($Bmp, (New-Object System.Windows.Media.ScaleTransform($K, $K))) }
    if (-not (Test-Path $script:WplanDir)) { New-Item -ItemType Directory -Path $script:WplanDir | Out-Null }
    $Name = (Split-Path (Get-WplanPath $script:Wplan.Site "floor.png") -Leaf)
    $Enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $Enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Bmp))
    $Fs = [IO.File]::Create((Join-Path $script:WplanDir $Name)); $Enc.Save($Fs); $Fs.Dispose()
    $Keep = ($F.W -and [Math]::Abs($F.W / [Math]::Max(1, $F.H) - $Bmp.PixelWidth / [double]$Bmp.PixelHeight) -lt 0.02)
    $F.Image = $Name; $F.W = $Bmp.PixelWidth; $F.H = $Bmp.PixelHeight
    if (-not $Keep -and (@($F.Rooms).Count -or $F.Aps.Count)) {
        if (Show-Confirm "Новый план другой формы" "Пропорции картинки изменились — помещения, точки и масштаб, заданные на старом плане, окажутся не на своих местах. Убрать их?" "Убрать") { $F.Rooms = @(); $F.Aps = @{}; $F.Scale = $null }
    }
    Save-Wplan
    Update-FloorPage
    Show-Toast $(if ($Keep -and (@($F.Rooms).Count -or $F.Aps.Count)) { "План заменён: $($F.W)×$($F.H), помещения и точки остались на местах" } else { "План загружен: $($F.W)×$($F.H)" })
}

function Read-FloorBitmapFile {
    param([string]$Path)
    $B = New-Object System.Windows.Media.Imaging.BitmapImage
    $B.BeginInit(); $B.CacheOption = "OnLoad"; $B.UriSource = [Uri]$Path; $B.EndInit(); $B.Freeze()
    return $B
}

function Remove-Floor {
    $F = Get-Floor
    if (-not $F -or -not $F.Image) { return }
    $Msg = "Удалится картинка плана$(if (@($F.Rooms).Count) { ", помещения ($(@($F.Rooms).Count))" })$(if ($F.Aps.Count) { ", расстановка точек ($($F.Aps.Count))" })$(if ($F.Scale) { ", масштаб" }). Прогулки, замеры и расчёт останутся. Новый план — кнопкой «Загрузить план»."
    if (-not (Show-Confirm "Удалить план?" $Msg "Удалить" -Danger)) { return }
    $P = Get-FloorImagePath
    $script:Wplan.Floor = @{ Image = ""; W = 0; H = 0; Rooms = @(); Aps = @{}; V = 2 }
    $script:FloorSelAp = ""; $script:FloorScaleMode = $false
    Save-Wplan
    if ($P) { try { Remove-Item $P -Force } catch { Write-AppLog "floor delete: $_" } }
    if ($script:FloorView) { $script:FloorView.Bmp = $null; $script:FloorView.File = "" }
    if ($script:WalkView) { $script:WalkView.Bmp = $null; $script:WalkView.File = "" }
    Update-FloorPage
    Show-Toast "План удалён"
}

function Import-FloorFile {
    $P = @(Show-OpenFiles "План помещений" "План (*.png;*.jpg;*.jpeg;*.bmp;*.pdf)|*.png;*.jpg;*.jpeg;*.bmp;*.pdf") | Select-Object -First 1
    if (-not $P) { return }
    if ($P -match '\.pdf$') { Import-FloorPdf $P; return }
    try { Save-FloorBitmap (Read-FloorBitmapFile $P) } catch { Show-Toast "Не открыл картинку: $($_.Exception.Message)" "fail" }
}

function Invoke-FloorPdfTool {
    param([string[]]$Arg)
    $Psi = New-Object System.Diagnostics.ProcessStartInfo "powershell.exe"
    foreach ($A in @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ([IO.Path]::GetFullPath($script:FloorPdfTool))) + $Arg) { $Psi.ArgumentList.Add($A) }
    $Psi.UseShellExecute = $false; $Psi.CreateNoWindow = $true; $Psi.RedirectStandardOutput = $true
    $Pr = [System.Diagnostics.Process]::Start($Psi)
    $Out = $Pr.StandardOutput.ReadToEnd(); [void]$Pr.WaitForExit(60000)
    return "$Out".Trim()
}

# Windows built-in PDF renderer (Windows.Data.Pdf through Windows PowerShell 5.1 — see tools\PdfPage.ps1)
function Import-FloorPdf {
    param([string]$Path)
    $Win = $script:Win; $Win.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $R = Invoke-FloorPdfTool @("-Pdf", $Path, "-Page", "-1")
        if ($R -notmatch '^PAGES (\d+)') { Show-Toast "PDF не открылся: $R" "fail"; return }
        $N = [int]$Matches[1]; $Pg = 1
        if ($N -gt 1) {
            $Win.Cursor = $null
            $V = Show-FloorInput "Страница PDF" "В файле $N страниц. Какую взять как план?" "1"
            if (-not $V) { return }
            if (-not [int]::TryParse($V, [ref]$Pg) -or $Pg -lt 1 -or $Pg -gt $N) { Show-Toast "Нет такой страницы" "warn"; return }
            $Win.Cursor = [System.Windows.Input.Cursors]::Wait
        }
        $Png = Join-Path $env:TEMP ("nk-floor-{0}.png" -f [guid]::NewGuid().ToString("N").Substring(0, 8))
        $R = Invoke-FloorPdfTool @("-Pdf", $Path, "-Out", $Png, "-Page", "$($Pg - 1)", "-Width", "2600")
        if ($R -notmatch '^OK' -or -not (Test-Path $Png)) { Show-Toast "PDF не отрисовался: $R" "fail"; return }
        Save-FloorBitmap (Read-FloorBitmapFile $Png)
        Remove-Item $Png -ErrorAction SilentlyContinue
    } finally { $Win.Cursor = $null }
}

function Import-FloorClipboard {
    if (-not [System.Windows.Clipboard]::ContainsImage()) {
        $Fl = [System.Windows.Clipboard]::GetFileDropList()
        if ($Fl.Count) { $P = $Fl[0]; if ($P -match '\.pdf$') { Import-FloorPdf $P } else { try { Save-FloorBitmap (Read-FloorBitmapFile $P) } catch { Show-Toast "Не открыл: $($_.Exception.Message)" "fail" } }; return }
        Show-Toast "В буфере нет картинки — сделай скриншот плана (Win+Shift+S) и нажми ещё раз" "warn"; return
    }
    Save-FloorBitmap ([System.Windows.Clipboard]::GetImage())
}

function Show-FloorInput {
    param([string]$Title, [string]$Text, [string]$Value = "")
    $D = New-Dialog $Title @"
<StackPanel>
    <TextBlock Text="$([System.Security.SecurityElement]::Escape($Title))" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="$([System.Security.SecurityElement]::Escape($Text))" Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,12" FontSize="12.5"/>
    <TextBox x:Name="FVal" Style="{StaticResource Field}"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="OK" MinWidth="110" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@ 440
    $FVal = $D.FindName("FVal"); $FVal.Text = $Value
    $D.FindName("FOk").Add_Click({ $D.DialogResult = $true })
    $D.Add_ContentRendered({ [void]$FVal.Focus(); $FVal.SelectAll() })
    if ($D.ShowDialog()) { return $FVal.Text.Trim() }
    return $null
}

# ---------------------------------------------------------------- AI: rooms from the picture

function Get-FloorJpegB64 {
    param($Bmp, [int]$Max = 1568)
    $L = [Math]::Max($Bmp.PixelWidth, $Bmp.PixelHeight)
    if ($L -gt $Max) { $K = $Max / [double]$L; $Bmp = New-Object System.Windows.Media.Imaging.TransformedBitmap($Bmp, (New-Object System.Windows.Media.ScaleTransform($K, $K))) }
    # JPEG has no alpha: flatten on white
    $Dv = New-Object System.Windows.Media.DrawingVisual
    $Dc = $Dv.RenderOpen()
    $Rc = New-Object System.Windows.Rect 0, 0, $Bmp.PixelWidth, $Bmp.PixelHeight
    $Dc.DrawRectangle([System.Windows.Media.Brushes]::White, $null, $Rc); $Dc.DrawImage($Bmp, $Rc); $Dc.Close()
    $Rt = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($Bmp.PixelWidth, $Bmp.PixelHeight, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $Rt.Render($Dv)
    $Enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder; $Enc.QualityLevel = 85
    $Enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Rt))
    $Ms = New-Object IO.MemoryStream; $Enc.Save($Ms)
    return [Convert]::ToBase64String($Ms.ToArray())
}

function Start-FloorRoomsAi {
    $P = Get-FloorImagePath
    if (-not $P) { Show-Toast "Сначала загрузи план" "warn"; return }
    $F = Get-Floor
    if (@($F.Rooms).Count -and -not (Show-Confirm "Распознать заново?" "Помещения, нарисованные сейчас ($(@($F.Rooms).Count)), заменятся распознанными. Точки доступа останутся на местах." "Распознать")) { return }
    $Known = @($script:Wplan.Points | ForEach-Object { $_.Room } | Sort-Object -Unique)
    $Sys = "Ты разбираешь архитектурные планы квартир и домов. Отвечаешь только JSON без пояснений."
    $Txt = "Найди на плане все помещения: комнаты, кухню, санузлы, коридоры, холлы, гардеробные, лестницы, балконы, террасы, гараж. Верни JSON {`"rooms`":[{`"name`":`"Кухня`",`"x`":0.12,`"y`":0.30,`"w`":0.20,`"h`":0.15}]}: x,y — левый верхний угол прямоугольника, охватывающего помещение, w,h — его размеры; всё в долях ширины и высоты картинки (0..1). Названия бери с плана (по-русски, коротко, без площади). Если подписи нет — назови по назначению. Одинаковые названия различай номером (Детская 1, Детская 2)." +
        $(if ($Known.Count) { " Эти названия уже используются в замерах объекта — если помещение совпадает по смыслу, используй именно их: " + ($Known -join ", ") + "." } else { "" })
    $Ui.FlRooms.IsEnabled = $false
    $Ui.FlHint.Text = "ИИ распознаёт помещения на плане…"
    $Ok = Start-AiRequest -Name "floor-ai" -System $Sys -UserText $Txt -MaxTokens 3000 -ImageB64 (Get-FloorJpegB64 (Read-FloorBitmapFile $P)) -OnResult {
        param($M)
        $Ui.FlRooms.IsEnabled = $true
        if (-not $M.Ok) { $Ui.FlHint.Text = "ИИ: $($M.Text)"; Show-Toast "ИИ: $($M.Text)" "fail"; return }
        if ($M.NoImage) { $Ui.FlHint.Text = "ИИ-провайдер не принял картинку плана — обведи помещения сам (переключатель «Рисовать помещения») или выбери в Настройках → ИИ-анализ провайдер с поддержкой картинок."; return }
        $J = ConvertFrom-AiJson $M.Text
        $L = @(foreach ($R in @($J.rooms)) {
            $X = [double]$R.x; $Y = [double]$R.y; $W = [double]$R.w; $H = [double]$R.h
            if ("$($R.name)".Trim() -and $W -gt 0 -and $H -gt 0 -and $X -ge -0.05 -and $Y -ge -0.05 -and $X + $W -le 1.05 -and $Y + $H -le 1.05) { @{ Name = "$($R.name)".Trim(); X = $X; Y = $Y; W = $W; H = $H } }
        })
        if (-not $L.Count) { $Ui.FlHint.Text = "ИИ не нашёл помещений — нарисуй их сам (переключатель «Рисовать помещения»)"; return }
        (Get-Floor).Rooms = $L
        Save-Wplan
        Update-FloorPage
        $Ui.FlHint.Text = "Найдено помещений: $($L.Count). Проверь подписи и рамки: двойной клик по названию в списке — переименовать, Delete — удалить, «Рисовать помещения» — добавить."
    }
    if (-not $Ok) { $Ui.FlRooms.IsEnabled = $true }
}

# ---------------------------------------------------------------- view (shared with the walk step)

function New-FloorView {
    param([string]$Kind)
    $Cv = New-Object System.Windows.Controls.Canvas
    $Cv.Background = [System.Windows.Media.Brushes]::Transparent
    $Cv.Tag = @{ Kind = $Kind }
    $Vb = New-Object System.Windows.Controls.Viewbox
    $Vb.Stretch = "Uniform"; $Vb.Child = $Cv
    $Ph = New-Object System.Windows.Controls.TextBlock
    $Ph.Text = "План не загружен"; $Ph.Foreground = Get-Brush "Faint"; $Ph.HorizontalAlignment = "Center"; $Ph.VerticalAlignment = "Center"; $Ph.FontSize = 14; $Ph.TextWrapping = "Wrap"; $Ph.TextAlignment = "Center"
    return @{ Kind = $Kind; Box = $Vb; Canvas = $Cv; Placeholder = $Ph; W = 0; H = 0; File = ""; Bmp = $null }
}

function Set-FloorViewHost {
    param($View, $HostGrid)
    $HostGrid.Children.Clear()
    [void]$HostGrid.Children.Add($View.Placeholder)
    [void]$HostGrid.Children.Add($View.Box)
}

function Add-FloorText {
    param($Cv, [string]$Text, [double]$X, [double]$Y, [double]$Size, $Brush, [switch]$Center, [switch]$Bold)
    $T = New-Object System.Windows.Controls.TextBlock
    $T.Text = $Text; $T.FontSize = $Size; $T.Foreground = $Brush
    if ($Bold) { $T.FontWeight = "SemiBold" }
    # readable over any plan: light halo
    $T.Effect = New-Object System.Windows.Media.Effects.DropShadowEffect -Property @{ Color = [System.Windows.Media.Colors]::White; BlurRadius = $Size / 3; ShadowDepth = 0; Opacity = 1 }
    $T.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    [System.Windows.Controls.Canvas]::SetLeft($T, $(if ($Center) { $X - $T.DesiredSize.Width / 2 } else { $X }))
    [System.Windows.Controls.Canvas]::SetTop($T, $(if ($Center) { $Y - $T.DesiredSize.Height / 2 } else { $Y }))
    [void]$Cv.Children.Add($T)
}

function Add-FloorDot {
    param($Cv, [double]$X, [double]$Y, [double]$D, $Fill, $Stroke = $null, [double]$Sw = 0, [string]$Tip = "")
    $E = New-Object System.Windows.Shapes.Ellipse
    $E.Width = $D; $E.Height = $D; $E.Fill = $Fill
    if ($Stroke) { $E.Stroke = $Stroke; $E.StrokeThickness = $Sw }
    if ($Tip) { $E.ToolTip = $Tip }
    [System.Windows.Controls.Canvas]::SetLeft($E, $X - $D / 2); [System.Windows.Controls.Canvas]::SetTop($E, $Y - $D / 2)
    [void]$Cv.Children.Add($E)
    return $E
}

function Get-RssiBrush {
    param([int]$Rssi)
    $C = $(if ($Rssi -ge -60) { "#22C55E" } elseif ($Rssi -ge -67) { "#A3E635" } elseif ($Rssi -ge -72) { "#FACC15" } elseif ($Rssi -ge -78) { "#F97316" } else { "#EF4444" })
    return ConvertTo-Brush $C
}

# draws picture + rooms + APs; $Walk (optional) adds route, signal dots, events and notes
function Update-FloorView {
    param($View, $Walk = $null, [string]$SelAp = "")
    $Cv = $View.Canvas
    $P = Get-FloorImagePath
    $F = Get-Floor
    $Cv.Children.Clear()
    if (-not $P) { $View.Box.Visibility = "Collapsed"; $View.Placeholder.Visibility = "Visible"; return }
    $View.Box.Visibility = "Visible"; $View.Placeholder.Visibility = "Collapsed"
    if ($View.File -ne $P -or -not $View.Bmp -or $View.Stamp -ne (Get-Item $P).LastWriteTimeUtc) {
        $View.Bmp = Read-FloorBitmapFile $P; $View.File = $P; $View.Stamp = (Get-Item $P).LastWriteTimeUtc
    }
    $W = [double]$View.Bmp.PixelWidth; $H = [double]$View.Bmp.PixelHeight
    $View.W = $W; $View.H = $H
    $Cv.Width = $W; $Cv.Height = $H
    $Img = New-Object System.Windows.Controls.Image
    $Img.Source = $View.Bmp; $Img.Width = $W; $Img.Height = $H
    if ($Walk) {
        # the plan fades to light (not grey on a dark theme) so the route and the signal dots stand out
        $Bg = New-Object System.Windows.Shapes.Rectangle; $Bg.Width = $W; $Bg.Height = $H; $Bg.Fill = [System.Windows.Media.Brushes]::White
        [void]$Cv.Children.Add($Bg)
        $Img.Opacity = 0.5
    }
    [void]$Cv.Children.Add($Img)
    $U = $W / 1000.0
    $Ink = ConvertTo-Brush "#1F2937"
    $Acc = Get-Brush "Accent"
    # rooms
    foreach ($R in @($F.Rooms)) {
        $Rc = New-Object System.Windows.Shapes.Rectangle
        $Rc.Width = $R.W * $W; $Rc.Height = $R.H * $H
        $Rc.Stroke = ConvertTo-Brush "#806366F1"; $Rc.StrokeThickness = 2 * $U; $Rc.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (, [double[]]@(4, 3))
        $Rc.Fill = ConvertTo-Brush "#106366F1"
        [System.Windows.Controls.Canvas]::SetLeft($Rc, $R.X * $W); [System.Windows.Controls.Canvas]::SetTop($Rc, $R.Y * $H)
        [void]$Cv.Children.Add($Rc)
        # label in the top-left corner of the frame — the plan usually has its own caption in the middle
        Add-FloorText $Cv $R.Name ($R.X * $W + 8 * $U) ($R.Y * $H + 6 * $U) (17 * $U) (ConvertTo-Brush "#4338CA") -Bold
    }
    # scale line
    if ($F.Scale -and $F.Scale.Mm) {
        $Sc = $F.Scale; $Or = ConvertTo-Brush "#F97316"
        $Ln = New-Object System.Windows.Shapes.Line
        $Ln.X1 = $Sc.X1 * $W; $Ln.Y1 = $Sc.Y1 * $H; $Ln.X2 = $Sc.X2 * $W; $Ln.Y2 = $Sc.Y2 * $H
        $Ln.Stroke = $Or; $Ln.StrokeThickness = 4 * $U; $Ln.StrokeStartLineCap = "Round"; $Ln.StrokeEndLineCap = "Round"
        [void]$Cv.Children.Add($Ln)
        foreach ($Pt in @(@{ X = $Sc.X1; Y = $Sc.Y1 }, @{ X = $Sc.X2; Y = $Sc.Y2 })) { [void](Add-FloorDot $Cv ($Pt.X * $W) ($Pt.Y * $H) (12 * $U) $Or) }
        Add-FloorText $Cv ("{0:N2} м" -f ($Sc.Mm / 1000.0)) ((($Sc.X1 + $Sc.X2) / 2) * $W) ((($Sc.Y1 + $Sc.Y2) / 2) * $H - 22 * $U) (18 * $U) $Or -Center -Bold
    }
    # walk overlay: route, signal of the connected AP along it, events, notes
    if ($Walk) {
        $Pts = @(Get-WalkTrack $Walk)
        if ($Pts.Count -ge 2) {
            $Pl = New-Object System.Windows.Shapes.Polyline
            foreach ($Q in $Pts) { $Pl.Points.Add((New-Object System.Windows.Point ($Q.X * $W), ($Q.Y * $H))) }
            $Pl.Stroke = ConvertTo-Brush "#8C1F2937"; $Pl.StrokeThickness = 2.5 * $U; $Pl.StrokeLineJoin = "Round"
            [void]$Cv.Children.Add($Pl)
        }
        foreach ($S in @(Get-WalkSignalDots $Walk)) { [void](Add-FloorDot $Cv ($S.X * $W) ($S.Y * $H) (9 * $U) (Get-RssiBrush $S.Rssi) $null 0 "$($S.Tip)") }
        foreach ($E in @(Get-WalkEventMarks $Walk)) {
            $D = $(if ($E.Kind -eq "fail") { 22 } else { 16 }) * $U
            $Br = $(if ($E.Kind -eq "fail") { ConvertTo-Brush "#EF4444" } elseif ($E.Kind -eq "warn") { ConvertTo-Brush "#F97316" } elseif ($E.Kind -eq "note") { ConvertTo-Brush "#A855F7" } else { ConvertTo-Brush "#3B82F6" })
            [void](Add-FloorDot $Cv ($E.X * $W) ($E.Y * $H) $D ([System.Windows.Media.Brushes]::White) $Br (4 * $U) "$($E.Tip)")
        }
    }
    # APs
    foreach ($K in @($F.Aps.Keys)) {
        $A = $F.Aps[$K]
        $X = $A.X * $W; $Y = $A.Y * $H
        $Sel = ($K -eq $SelAp)
        [void](Add-FloorDot $Cv $X $Y ($(if ($Sel) { 44 } else { 34 }) * $U) $Acc ([System.Windows.Media.Brushes]::White) (3 * $U) (Get-WplanApName $K))
        Add-FloorText $Cv (Get-WplanApName $K) $X ($Y + 34 * $U) (19 * $U) $Ink -Center -Bold
    }
}

# ---------------------------------------------------------------- page (wizard step «План»)

$script:FloorSelAp = ""
$script:FloorDrag = $null
$script:FloorScaleMode = $false

function Update-FloorPage {
    if (-not $script:FloorView) { return }
    $F = Get-Floor
    Update-FloorView $script:FloorView -SelAp $script:FloorSelAp
    $W = $(if ($script:Wplan) { Get-WhState } else { @{} })
    # AP list: planner APs ∪ the router's DHCP list
    $Keys = [ordered]@{}
    if ($script:Wplan) { foreach ($K in $script:Wplan.Aps.Keys) { $Keys[$K] = 1 } }
    foreach ($A in @(Get-MtCachedAps $W.RouterId)) { if ($A.Key) { $Keys[$A.Key] = 1 } }
    $Raw = @(foreach ($K in $Keys.Keys) {
        $On = ($F -and $F.Aps.ContainsKey($K))
        [pscustomobject]@{ Key = $K; Label = "$(if ($On) { '✔' } else { '·' })  $(Get-WplanApName $K)" }
    })
    $Items = @($Raw | Sort-Object { $_.Label -replace '^\S+\s+', '' })
    $script:FloorListSync = $true
    $Ui.FlAps.ItemsSource = $Items; $Ui.FlAps.DisplayMemberPath = "Label"
    $Ui.FlAps.SelectedItem = ($Items | Where-Object { $_.Key -eq $script:FloorSelAp } | Select-Object -First 1)
    $Ui.FlRoomList.ItemsSource = @(if ($F) { @($F.Rooms) | ForEach-Object { $Sz = Get-FloorRoomSize $_; [pscustomobject]@{ Name = $_.Name; Label = "$($_.Name)$(if ($Sz) { "  ·  $Sz" })" } } })
    $Ui.FlRoomList.DisplayMemberPath = "Label"
    $script:FloorListSync = $false
    $Has = [bool](Get-FloorImagePath)
    $Ui.FlLoadText.Text = $(if ($Has) { "Заменить план" } else { "Загрузить план (PNG, JPG, PDF)" })
    $Ui.FlDelete.Visibility = $(if ($Has) { "Visible" } else { "Collapsed" })
    $Kpx = Get-FloorMPerPx
    $Ui.FlScaleText.Text = $(if ($Kpx) { "Масштаб ✔" } else { "Масштаб" })
    $ScTxt = $(if (-not $Has) { "" } elseif ($Kpx) { " Масштаб: план ≈ {0:N1}×{1:N1} м." -f ($F.W * $Kpx), ($F.H * $Kpx) } else { " Масштаб не задан — кнопка «Масштаб» (расстояния и затухание стен в метрах и dB)." })
    $NPl = $(if ($F) { $F.Aps.Count } else { 0 })
    $Ui.FlCount.Text = "на плане $NPl из $($Items.Count)"
    if (-not (Get-FloorImagePath)) { $Ui.FlHint.Text = "Загрузи план: картинка или PDF (кнопка) или скриншот (Win+Shift+S → «Вставить», Ctrl+V)." }
    elseif ($script:FloorScaleMode) { $Ui.FlHint.Text = "Масштаб: проведи линию по размерной линии плана (зажми и тяни; Shift — строго по горизонтали/вертикали) и впиши её длину. Esc — отмена." }
    elseif ($script:FloorSelAp) { $Ui.FlHint.Text = "Кликни на плане, где висит «$(Get-WplanApName $script:FloorSelAp)». Esc — отмена." }
    elseif ($Ui.FlRoomMode.IsChecked) { $Ui.FlHint.Text = "Обведи помещение мышью (зажми и тяни), затем впиши название." }
    elseif (-not @($F.Rooms).Count) { $Ui.FlHint.Text = "Помещения: «Распознать помещения» (ИИ прочитает план) или нарисуй сам. Точки: выбери справа и кликни на плане." }
    else { $Ui.FlHint.Text = "Выбери точку справа и кликни на плане, где она висит. Помещений: $(@($F.Rooms).Count)." }
    if ($ScTxt -and -not $script:FloorScaleMode) { $Ui.FlHint.Text += $ScTxt }
    Update-WhStepper
}

function Get-FloorPos {
    param($E)
    $V = $script:FloorView
    if (-not $V.W) { return $null }
    $Pt = $E.GetPosition($V.Canvas)
    return @{ X = [Math]::Max(0.0, [Math]::Min(1.0, $Pt.X / $V.W)); Y = [Math]::Max(0.0, [Math]::Min(1.0, $Pt.Y / $V.H)) }
}

function Initialize-FloorPage {
    $script:FloorView = New-FloorView "edit"
    Set-FloorViewHost $script:FloorView $Ui.FlHost
    $Cv = $script:FloorView.Canvas
    $Ui.FlLoad.Add_Click({ Import-FloorFile })
    $Ui.FlPaste.Add_Click({ Import-FloorClipboard })
    $Ui.FlRooms.Add_Click({ Start-FloorRoomsAi })
    $Ui.FlDelete.Add_Click({ Remove-Floor })
    $Ui.FlScale.Add_Click({
        if (-not (Get-FloorImagePath)) { Show-Toast "Сначала загрузи план" "warn"; return }
        $script:FloorScaleMode = -not $script:FloorScaleMode
        $script:FloorSelAp = ""; $Ui.FlRoomMode.IsChecked = $false
        Update-FloorPage
    })
    $script:Win.Add_PreviewKeyDown({ param($S, $E) if ($E.Key -eq "Escape" -and $script:FloorScaleMode) { $script:FloorScaleMode = $false; Update-FloorPage } })
    $Ui.FlRoomMode.Add_Click({ $script:FloorSelAp = ""; Update-FloorPage })
    $Ui.FlAps.Add_SelectionChanged({
        if ($script:FloorListSync) { return }
        $S = $Ui.FlAps.SelectedItem
        $script:FloorSelAp = $(if ($S) { $S.Key } else { "" })
        if ($script:FloorSelAp) { $Ui.FlRoomMode.IsChecked = $false; $script:FloorScaleMode = $false }
        Update-FloorPage
    })
    $Ui.FlAps.Add_KeyDown({
        param($S, $E)
        if ($E.Key -eq "Delete" -and $Ui.FlAps.SelectedItem) { $F = Get-Floor; [void]$F.Aps.Remove($Ui.FlAps.SelectedItem.Key); $script:FloorSelAp = ""; Save-Wplan; Update-FloorPage }
        if ($E.Key -eq "Escape") { $script:FloorSelAp = ""; Update-FloorPage }
    })
    $Ui.FlRoomList.Add_KeyDown({
        param($S, $E)
        if ($E.Key -eq "Delete" -and $Ui.FlRoomList.SelectedItem) { $F = Get-Floor; $N = $Ui.FlRoomList.SelectedItem.Name; $F.Rooms = @($F.Rooms | Where-Object { $_.Name -ne $N }); Save-Wplan; Update-FloorPage }
    })
    $Ui.FlRoomList.Add_MouseDoubleClick({
        $S = $Ui.FlRoomList.SelectedItem; if (-not $S) { return }
        $V = Show-FloorInput "Название помещения" "Так его нужно будет называть на прогулке." $S.Name
        if (-not $V -or $V -eq $S.Name) { return }
        foreach ($R in @((Get-Floor).Rooms)) { if ($R.Name -eq $S.Name) { $R.Name = $V } }
        Save-Wplan; Update-FloorPage
    })
    $Cv.Add_MouseLeftButtonDown({
        param($S, $E)
        $P = Get-FloorPos $E; if (-not $P) { return }
        $F = Get-Floor
        if ($script:FloorScaleMode) {
            $L = New-Object System.Windows.Shapes.Line
            $L.X1 = $P.X * $script:FloorView.W; $L.Y1 = $P.Y * $script:FloorView.H; $L.X2 = $L.X1; $L.Y2 = $L.Y1
            $L.Stroke = ConvertTo-Brush "#F97316"; $L.StrokeThickness = 4 * $script:FloorView.W / 1000
            $script:FloorDrag = @{ Kind = "scale"; X0 = $P.X; Y0 = $P.Y; X1 = $P.X; Y1 = $P.Y; Line = $L }
            [void]$script:FloorView.Canvas.Children.Add($L)
            [void]$script:FloorView.Canvas.CaptureMouse()
            return
        }
        if ($script:FloorSelAp) {
            $F.Aps[$script:FloorSelAp] = @{ X = [Math]::Round($P.X, 4); Y = [Math]::Round($P.Y, 4) }
            # next unplaced AP is selected automatically — place them one after another
            $Next = @($Ui.FlAps.ItemsSource | Where-Object { -not $F.Aps.ContainsKey($_.Key) }) | Select-Object -First 1
            $script:FloorSelAp = $(if ($Next) { $Next.Key } else { "" })
            Save-Wplan; Update-FloorPage
            return
        }
        if ($Ui.FlRoomMode.IsChecked) {
            $script:FloorDrag = @{ Kind = "room"; X0 = $P.X; Y0 = $P.Y; Rect = New-Object System.Windows.Shapes.Rectangle }
            $R = $script:FloorDrag.Rect
            $R.Stroke = Get-Brush "Accent"; $R.StrokeThickness = 3 * $script:FloorView.W / 1000
            [void]$script:FloorView.Canvas.Children.Add($R)
            [void]$script:FloorView.Canvas.CaptureMouse()
        }
    })
    $Cv.Add_MouseMove({
        param($S, $E)
        $D = $script:FloorDrag; if (-not $D) { return }
        $P = Get-FloorPos $E; if (-not $P) { return }
        $V = $script:FloorView
        if ($D.Kind -eq "scale") {
            # Shift: strictly horizontal / vertical (dimension lines are)
            if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) {
                if ([Math]::Abs(($P.X - $D.X0) * $V.W) -ge [Math]::Abs(($P.Y - $D.Y0) * $V.H)) { $P.Y = $D.Y0 } else { $P.X = $D.X0 }
            }
            $D.X1 = $P.X; $D.Y1 = $P.Y
            $D.Line.X2 = $P.X * $V.W; $D.Line.Y2 = $P.Y * $V.H
            return
        }
        [System.Windows.Controls.Canvas]::SetLeft($D.Rect, [Math]::Min($D.X0, $P.X) * $V.W); [System.Windows.Controls.Canvas]::SetTop($D.Rect, [Math]::Min($D.Y0, $P.Y) * $V.H)
        $D.Rect.Width = [Math]::Abs($P.X - $D.X0) * $V.W; $D.Rect.Height = [Math]::Abs($P.Y - $D.Y0) * $V.H
    })
    $Cv.Add_MouseLeftButtonUp({
        param($S, $E)
        $D = $script:FloorDrag; if (-not $D) { return }
        $script:FloorDrag = $null
        $script:FloorView.Canvas.ReleaseMouseCapture()
        if ($D.Kind -eq "scale") {
            $V = $script:FloorView
            $Px = [Math]::Sqrt([Math]::Pow(($D.X1 - $D.X0) * $V.W, 2) + [Math]::Pow(($D.Y1 - $D.Y0) * $V.H, 2))
            if ($Px -lt 20) { Update-FloorPage; return }
            $F = Get-Floor
            $Def = $(if ($F.Scale -and $F.Scale.Mm) { "$([int]$F.Scale.Mm)" } else { "" })
            $In = Show-FloorInput "Длина отрезка" "Сколько это в реальности? В миллиметрах, как на размерных линиях плана (2900), или в метрах (2,9 м)." $Def
            $Mm = $(if ($In) { ConvertTo-FloorMm $In } else { 0 })
            if ($In -and $Mm -le 0) { Show-Toast "Не понял длину: «$In»" "warn" }
            if ($Mm -gt 0) {
                $F.Scale = @{ X1 = [Math]::Round($D.X0, 5); Y1 = [Math]::Round($D.Y0, 5); X2 = [Math]::Round($D.X1, 5); Y2 = [Math]::Round($D.Y1, 5); Mm = [double]$Mm }
                $script:FloorScaleMode = $false
                Save-Wplan
                $K = Get-FloorMPerPx
                Show-Toast ("Масштаб задан: план ≈ {0:N1}×{1:N1} м" -f ($F.W * $K), ($F.H * $K))
            }
            Update-FloorPage
            return
        }
        $P = Get-FloorPos $E
        if (-not $P -or [Math]::Abs($P.X - $D.X0) -lt 0.01 -or [Math]::Abs($P.Y - $D.Y0) -lt 0.01) { Update-FloorPage; return }
        $N = Show-FloorInput "Новое помещение" "Название — так его нужно будет называть на прогулке." ""
        if ($N) {
            $F = Get-Floor
            $F.Rooms = @($F.Rooms) + @(@{ Name = $N; X = [Math]::Round([Math]::Min($D.X0, $P.X), 4); Y = [Math]::Round([Math]::Min($D.Y0, $P.Y), 4); W = [Math]::Round([Math]::Abs($P.X - $D.X0), 4); H = [Math]::Round([Math]::Abs($P.Y - $D.Y0), 4) })
            Save-Wplan
        }
        Update-FloorPage
    })
}
