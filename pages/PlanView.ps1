# Read-only plan view for the walk: the plan of the HelpDesk directory (GET /collector/sites → plans[]): the picture
# from the cache (collector\plan-<id>-<sha256>.png|jpg), rooms (floor.rooms), the route (floor.route) and the APs
# (floor.aps) — all coordinates are fractions of the picture (0..1). On top: clicks of the current walk and «я здесь».
# The plan is edited in the web (Объект → Инструменты → Wi-Fi), the track and the signal are drawn by the server.

# server keys are lower case (x, y, name), the route keeps NetKnife's X/Y — accept both
function Get-PlanVal {
    param($O, [string]$K)
    if ($null -eq $O) { return $null }
    if ($O -is [System.Collections.IDictionary]) {
        if ($O.Contains($K)) { return $O[$K] }
        $U = $K.Substring(0, 1).ToUpper() + $K.Substring(1)
        if ($O.Contains($U)) { return $O[$U] }
        if ($O.Contains($K.ToLower())) { return $O[$K.ToLower()] }
        return $null
    }
    return $O.$K
}

function Get-PlanFloor { param($Plan) return (Get-PlanVal $Plan "floor") }
function Get-PlanRooms { param($Plan) return @(@(Get-PlanVal (Get-PlanFloor $Plan) "rooms") | Where-Object { $_ }) }
function Get-PlanRoute { param($Plan) return @(@(Get-PlanVal (Get-PlanFloor $Plan) "route") | Where-Object { $_ }) }

# the smallest room containing the point wins (a hall drawn around rooms must not swallow them)
function Get-PlanRoomAt {
    param($Plan, [double]$X, [double]$Y)
    $Hit = foreach ($R in @(Get-PlanRooms $Plan)) {
        $Rx = [double](Get-PlanVal $R "x"); $Ry = [double](Get-PlanVal $R "y"); $Rw = [double](Get-PlanVal $R "w"); $Rh = [double](Get-PlanVal $R "h")
        if ($X -ge $Rx -and $X -le ($Rx + $Rw) -and $Y -ge $Ry -and $Y -le ($Ry + $Rh)) { @{ Name = "$(Get-PlanVal $R 'name')"; Area = $Rw * $Rh } }
    }
    return @($Hit | Sort-Object { $_.Area }) | Select-Object -First 1
}

function Get-PlanCpName {
    param($Plan, $Cp, [int]$I)
    $Rm = Get-PlanRoomAt $Plan ([double](Get-PlanVal $Cp "X")) ([double](Get-PlanVal $Cp "Y"))
    return "$($I + 1)$(if ($Rm) { " · $($Rm.Name)" })"
}

function Read-PlanBitmapFile {
    param([string]$Path)
    $B = New-Object System.Windows.Media.Imaging.BitmapImage
    $B.BeginInit(); $B.CacheOption = "OnLoad"; $B.CreateOptions = "IgnoreImageCache"; $B.UriSource = [Uri]$Path; $B.EndInit(); $B.Freeze()
    return $B
}

# ---------------------------------------------------------------- view

function New-PlanView {
    param([string]$Kind)
    $Cv = New-Object System.Windows.Controls.Canvas
    $Cv.Background = [System.Windows.Media.Brushes]::Transparent
    $Vb = New-Object System.Windows.Controls.Viewbox
    $Vb.Stretch = "Uniform"; $Vb.Child = $Cv
    $Ph = New-Object System.Windows.Controls.TextBlock
    $Ph.Text = "План не загружен"; $Ph.Foreground = Get-Brush "Faint"; $Ph.HorizontalAlignment = "Center"; $Ph.VerticalAlignment = "Center"; $Ph.FontSize = 14; $Ph.TextWrapping = "Wrap"; $Ph.TextAlignment = "Center"
    # zoom = RenderTransform of the canvas (inside the fit-to-box Viewbox); GetPosition(canvas) stays in plan pixels
    $Sc = New-Object System.Windows.Media.ScaleTransform 1, 1
    $Tr = New-Object System.Windows.Media.TranslateTransform 0, 0
    $Tg = New-Object System.Windows.Media.TransformGroup; $Tg.Children.Add($Sc); $Tg.Children.Add($Tr)
    $Cv.RenderTransform = $Tg
    $Tools = New-Object System.Windows.Controls.StackPanel
    $Tools.Orientation = "Horizontal"; $Tools.HorizontalAlignment = "Right"; $Tools.VerticalAlignment = "Bottom"; $Tools.Margin = New-Object System.Windows.Thickness 0, 0, 6, 6
    $View = @{ Kind = $Kind; Box = $Vb; Canvas = $Cv; Placeholder = $Ph; Tools = $Tools; Zoom = $Sc; Shift = $Tr; W = 0; H = 0; File = ""; Bmp = $null; Pan = $null }
    foreach ($Bt in @(@{ G = 0xE710; T = "Крупнее (колесо мыши)"; F = 1.4; Id = "ZoomIn" }, @{ G = 0xE738; T = "Мельче"; F = 1 / 1.4; Id = "ZoomOut" }, @{ G = 0xE9A6; T = "Вписать целиком"; F = 0; Id = "ZoomFit" })) {
        $B = New-Object System.Windows.Controls.Button
        [System.Windows.Automation.AutomationProperties]::SetAutomationId($B, "$Kind$($Bt.Id)")
        $B.Style = $script:Win.FindResource("Btn"); $B.Padding = New-Object System.Windows.Thickness 8, 5, 8, 5; $B.Margin = New-Object System.Windows.Thickness 4, 0, 0, 0
        $G = New-Object System.Windows.Controls.TextBlock; $G.Text = [string][char]$Bt.G; $G.FontFamily = $script:Win.FindResource("IconFont"); $G.FontSize = 13
        $B.Content = $G; $B.ToolTip = $Bt.T; $B.Tag = @{ View = $View; F = $Bt.F }
        $B.Add_Click({ param($S2, $E2) $X = $S2.Tag; if ($X.F) { Set-PlanZoom $X.View $X.F $null } else { Reset-PlanZoom $X.View } })
        [void]$Tools.Children.Add($B)
    }
    $Cv.Tag = $View
    $Cv.Add_MouseWheel({
        param($S2, $E2)
        $V = $S2.Tag; if (-not $V.W) { return }
        Set-PlanZoom $V $(if ($E2.Delta -gt 0) { 1.2 } else { 1 / 1.2 }) $E2.GetPosition($V.Canvas)
        $E2.Handled = $true
    })
    $Cv.Add_MouseDown({
        param($S2, $E2)
        $V = $S2.Tag
        if ($E2.ChangedButton -notin @("Right", "Middle") -or $V.Zoom.ScaleX -le 1.0001) { return }
        $V.Pan = @{ P = $E2.GetPosition($V.Box); X = $V.Shift.X; Y = $V.Shift.Y }
        [void]$V.Canvas.CaptureMouse(); $V.Canvas.Cursor = [System.Windows.Input.Cursors]::SizeAll
        $E2.Handled = $true
    })
    $Cv.Add_MouseMove({
        param($S2, $E2)
        $V = $S2.Tag; if (-not $V.Pan) { return }
        $Q = $E2.GetPosition($V.Box); $K = Get-PlanBoxScale $V
        $V.Shift.X = $V.Pan.X + ($Q.X - $V.Pan.P.X) / $K; $V.Shift.Y = $V.Pan.Y + ($Q.Y - $V.Pan.P.Y) / $K
        Limit-PlanShift $V
    })
    $Cv.Add_MouseUp({
        param($S2, $E2)
        $V = $S2.Tag; if (-not $V.Pan -or $E2.ChangedButton -notin @("Right", "Middle")) { return }
        $V.Pan = $null; $V.Canvas.ReleaseMouseCapture(); $V.Canvas.Cursor = $null
        $E2.Handled = $true
    })
    return $View
}

function Set-PlanViewHost {
    param($View, $HostGrid)
    $HostGrid.Children.Clear()
    [void]$HostGrid.Children.Add($View.Placeholder)
    [void]$HostGrid.Children.Add($View.Box)
    [void]$HostGrid.Children.Add($View.Tools)
}

# Viewbox fit factor (plan pixels → screen units)
function Get-PlanBoxScale {
    param($V)
    if (-not $V.W -or -not $V.Box.ActualWidth) { return 1.0 }
    return [Math]::Min($V.Box.ActualWidth / $V.W, $V.Box.ActualHeight / $V.H)
}

# keep the zoomed plan covering the view (no flying off into emptiness)
function Limit-PlanShift {
    param($V)
    $S = $V.Zoom.ScaleX
    $V.Shift.X = [Math]::Min(0.0, [Math]::Max($V.W * (1.0 - $S), $V.Shift.X))
    $V.Shift.Y = [Math]::Min(0.0, [Math]::Max($V.H * (1.0 - $S), $V.Shift.Y))
}

# zoom by $Factor keeping plan point $At (plan pixels; default — centre of what is visible) under the cursor
function Set-PlanZoom {
    param($V, [double]$Factor, $At)
    if (-not $V -or -not $V.W) { return }
    $S = $V.Zoom.ScaleX
    $N = [Math]::Max(1.0, [Math]::Min(12.0, $S * $Factor))
    if (-not $At) { $At = New-Object System.Windows.Point ((($V.W / 2) - $V.Shift.X) / $S), ((($V.H / 2) - $V.Shift.Y) / $S) }
    $Qx = $S * $At.X + $V.Shift.X; $Qy = $S * $At.Y + $V.Shift.Y
    $V.Zoom.ScaleX = $N; $V.Zoom.ScaleY = $N
    $V.Shift.X = $Qx - $N * $At.X; $V.Shift.Y = $Qy - $N * $At.Y
    Limit-PlanShift $V
}

function Reset-PlanZoom {
    param($V)
    if (-not $V) { return }
    $V.Zoom.ScaleX = 1.0; $V.Zoom.ScaleY = 1.0; $V.Shift.X = 0.0; $V.Shift.Y = 0.0
}

function Add-PlanText {
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

function Add-PlanDot {
    param($Cv, [double]$X, [double]$Y, [double]$D, $Fill, $Stroke = $null, [double]$Sw = 0, [string]$Tip = "")
    $E = New-Object System.Windows.Shapes.Ellipse
    $E.Width = $D; $E.Height = $D; $E.Fill = $Fill
    if ($Stroke) { $E.Stroke = $Stroke; $E.StrokeThickness = $Sw }
    if ($Tip) { $E.ToolTip = $Tip }
    [System.Windows.Controls.Canvas]::SetLeft($E, $X - $D / 2); [System.Windows.Controls.Canvas]::SetTop($E, $Y - $D / 2)
    [void]$Cv.Children.Add($E)
    return $E
}

# picture + rooms + route + APs of the plan; $Walk adds its clicks, reached checkpoints and «я здесь»
function Update-PlanView {
    param($View, $Plan, [string]$ImagePath, $Walk = $null)
    $Cv = $View.Canvas
    $Cv.Children.Clear()
    if (-not $Plan -or -not $ImagePath -or -not (Test-Path $ImagePath)) { $View.Box.Visibility = "Collapsed"; $View.Tools.Visibility = "Collapsed"; $View.Placeholder.Visibility = "Visible"; $View.W = 0; return }
    $View.Box.Visibility = "Visible"; $View.Tools.Visibility = "Visible"; $View.Placeholder.Visibility = "Collapsed"
    if ($View.File -ne $ImagePath -or -not $View.Bmp) {
        Reset-PlanZoom $View
        # a cached picture WPF cannot decode must not take the page (or the start-up) down
        try { $View.Bmp = Read-PlanBitmapFile $ImagePath; $View.File = $ImagePath }
        catch { Write-AppLog "plan picture ${ImagePath}: $_"; $View.Bmp = $null; $View.File = ""; $View.Box.Visibility = "Collapsed"; $View.Tools.Visibility = "Collapsed"; $View.Placeholder.Visibility = "Visible"; $View.W = 0; return }
    }
    $W = [double]$View.Bmp.PixelWidth; $H = [double]$View.Bmp.PixelHeight
    $View.W = $W; $View.H = $H
    $Cv.Width = $W; $Cv.Height = $H
    $Img = New-Object System.Windows.Controls.Image
    $Img.Source = $View.Bmp; $Img.Width = $W; $Img.Height = $H
    [void]$Cv.Children.Add($Img)
    $U = $W / 1000.0
    $Ink = ConvertTo-Brush "#1F2937"
    $Acc = Get-Brush "Accent"
    foreach ($R in @(Get-PlanRooms $Plan)) {
        $Rc = New-Object System.Windows.Shapes.Rectangle
        $Rc.Width = [double](Get-PlanVal $R "w") * $W; $Rc.Height = [double](Get-PlanVal $R "h") * $H
        $Rc.Stroke = ConvertTo-Brush "#806366F1"; $Rc.StrokeThickness = 2 * $U; $Rc.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (, [double[]]@(4, 3))
        $Rc.Fill = ConvertTo-Brush "#106366F1"
        [System.Windows.Controls.Canvas]::SetLeft($Rc, [double](Get-PlanVal $R "x") * $W); [System.Windows.Controls.Canvas]::SetTop($Rc, [double](Get-PlanVal $R "y") * $H)
        [void]$Cv.Children.Add($Rc)
        Add-PlanText $Cv "$(Get-PlanVal $R 'name')" ([double](Get-PlanVal $R "x") * $W + 8 * $U) ([double](Get-PlanVal $R "y") * $H + 6 * $U) (17 * $U) (ConvertTo-Brush "#4338CA") -Bold
    }
    # planned route with checkpoints (reached — green, next — orange)
    $Rt = @(Get-PlanRoute $Plan)
    if ($Rt.Count) {
        $Sky = ConvertTo-Brush "#0EA5E9"
        if ($Rt.Count -ge 2) {
            $Pl = New-Object System.Windows.Shapes.Polyline
            foreach ($Q in $Rt) { $Pl.Points.Add((New-Object System.Windows.Point ([double](Get-PlanVal $Q "X") * $W), ([double](Get-PlanVal $Q "Y") * $H))) }
            $Pl.Stroke = $Sky; $Pl.StrokeThickness = 3 * $U; $Pl.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (, [double[]]@(3, 2)); $Pl.Opacity = 0.8
            [void]$Cv.Children.Add($Pl)
        }
        $Nx = $(if ($Walk -and $null -ne $Walk.CpNext) { [int]$Walk.CpNext } else { -1 })
        for ($i = 0; $i -lt $Rt.Count; $i++) {
            $Q = $Rt[$i]; $Qx = [double](Get-PlanVal $Q "X") * $W; $Qy = [double](Get-PlanVal $Q "Y") * $H
            $Done = ($Walk -and $Nx -ge 0 -and $i -lt $Nx)
            $Next = ($Walk -and $Walk.Running -and $i -eq $Nx)
            $D = $(if ($Next) { 46 } else { 30 }) * $U
            $Fill = $(if ($Done) { ConvertTo-Brush "#22C55E" } elseif ($Next) { ConvertTo-Brush "#F97316" } else { $Sky })
            [void](Add-PlanDot $Cv $Qx $Qy $D $Fill ([System.Windows.Media.Brushes]::White) (3 * $U) (Get-PlanCpName $Plan $Q $i))
            Add-PlanText $Cv "$($i + 1)" $Qx $Qy $(if ($Next) { 22 * $U } else { 15 * $U }) ([System.Windows.Media.Brushes]::White) -Center -Bold
        }
    }
    foreach ($A in @(@(Get-PlanVal (Get-PlanFloor $Plan) "aps") | Where-Object { $_ })) {
        $X = [double](Get-PlanVal $A "x") * $W; $Y = [double](Get-PlanVal $A "y") * $H
        $Nm = "$(Get-PlanVal $A 'name')"
        [void](Add-PlanDot $Cv $X $Y (34 * $U) $Acc ([System.Windows.Media.Brushes]::White) (3 * $U) $Nm)
        Add-PlanText $Cv $Nm $X ($Y + 34 * $U) (19 * $U) $Ink -Center -Bold
    }
    # clicks of the walk: small dots; the last one — «я здесь»
    if ($Walk -and $Walk.Clicks.Count) {
        $Dot = ConvertTo-Brush "#3B82F6"
        foreach ($C in @($Walk.Clicks)) { [void](Add-PlanDot $Cv ([double]$C.X * $W) ([double]$C.Y * $H) (10 * $U) $Dot $null 0 "$(Format-WalkTime $C.T)") }
        if ($Walk.Running) {
            $C = $Walk.Clicks[$Walk.Clicks.Count - 1]
            [void](Add-PlanDot $Cv ([double]$C.X * $W) ([double]$C.Y * $H) (26 * $U) $Dot ([System.Windows.Media.Brushes]::White) (5 * $U) "я здесь")
        }
    }
}
