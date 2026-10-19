# Page: Wi-Fi wizard — one tab for everything wireless. The existing Wi-Fi scanner, planner and roaming monitor
# panels are moved into the wizard host at start-up; the wizard decides which one is visible and what to do on
# each step: prepare (site, router, AP list + current power) → roaming test "before" → survey → calculation and
# entering values into Omada → survey "after" → roaming test "after" → summary (was/became). Wizard progress
# lives in the site plan (plan.Wizard), so a site can be resumed later.

$script:WhStep = 1
$script:WhPhase = ""      # "before" / "after" while a roaming step is open — Stop-RoamMonitor stores its result there
$script:WhSteps = @(
    @{ N = 1; Key = "prep";    Title = "Подготовка";      Panel = "WhPrep" }
    @{ N = 2; Key = "roam1";   Title = "Тест до";         Panel = "PageRoam" }
    @{ N = 3; Key = "survey";  Title = "Замеры";          Panel = "PageWplan" }
    @{ N = 4; Key = "calc";    Title = "Расчёт → Omada";  Panel = "PageWplan" }
    @{ N = 5; Key = "survey2"; Title = "Замеры после";    Panel = "PageWplan" }
    @{ N = 6; Key = "roam2";   Title = "Тест после";      Panel = "PageRoam" }
    @{ N = 7; Key = "sum";     Title = "Итог";            Panel = "WhSummary" }
)
$script:WhPanels = @("WhPrep", "WhSummary", "PageWifi", "PageWplan", "PageRoam")

function Get-WhState {
    if (-not $script:Wplan) { return @{} }
    if (-not $script:Wplan.Wizard) { $script:Wplan.Wizard = @{ Step = 1; Applied = $false; AfterSeries = ""; RoamBefore = $null; RoamAfter = $null; RouterId = "" } }
    return $script:Wplan.Wizard
}

function Test-WhStepDone {
    param([int]$N)
    if (-not $script:Wplan) { return $false }
    $W = Get-WhState
    $Base = @($script:Wplan.Points | Where-Object { $_.Series -eq $script:WplanBaseSeries }).Count
    switch ($N) {
        1 { return [bool]($W.RouterId -and @(Get-MtCachedAps $W.RouterId).Count -and @($script:Wplan.Ssids).Count) }
        2 { return [bool]$W.RoamBefore }
        3 { return ($Base -ge 2) }
        4 { return [bool]$W.Applied }
        5 { return [bool]($W.AfterSeries -and @($script:Wplan.Points | Where-Object { $_.Series -eq $W.AfterSeries }).Count) }
        6 { return [bool]$W.RoamAfter }
    }
    return $false
}

# ---------------------------------------------------------------- stepper

function Update-WhStepper {
    $P = $Ui.WhSteps
    $P.Children.Clear()
    foreach ($S in $script:WhSteps) {
        $B = New-Object System.Windows.Controls.Button
        $Done = Test-WhStepDone $S.N
        $B.Style = $script:Win.FindResource($(if ($S.N -eq $script:WhStep) { "AccentBtn" } elseif ($Done) { "Btn" } else { "GhostBtn" }))
        $B.Padding = New-Object System.Windows.Thickness 10, 6, 12, 6
        $B.Margin = New-Object System.Windows.Thickness 0, 0, 6, 0
        $Sp = New-Object System.Windows.Controls.StackPanel; $Sp.Orientation = "Horizontal"
        $G = New-Object System.Windows.Controls.TextBlock
        $G.Text = $(if ($Done -and $S.N -ne $script:WhStep) { [string][char]0xE73E } else { "$($S.N)" })
        $G.FontFamily = $(if ($Done -and $S.N -ne $script:WhStep) { $script:Win.FindResource("IconFont") } else { $script:Win.FindResource("MonoFont") })
        $G.FontWeight = "SemiBold"; $G.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0; $G.VerticalAlignment = "Center"
        if ($Done -and $S.N -ne $script:WhStep) { $G.Foreground = Get-Brush "Ok" }
        $T = New-Object System.Windows.Controls.TextBlock; $T.Text = $S.Title; $T.VerticalAlignment = "Center"
        [void]$Sp.Children.Add($G); [void]$Sp.Children.Add($T)
        $B.Content = $Sp
        $B.Tag = "wh:$($S.N)"
        [void]$P.Children.Add($B)
    }
}

function Show-WhPanel {
    param([string]$Name)
    foreach ($N in $script:WhPanels) { $Ui[$N].Visibility = $(if ($N -eq $Name) { "Visible" } else { "Collapsed" }) }
}

function Set-WhStep {
    param([int]$N)
    if ($N -lt 1) { $N = 1 }; if ($N -gt $script:WhSteps.Count) { $N = $script:WhSteps.Count }
    if ($script:Roam -and $script:Roam.Running -and $script:WhStep -ne $N -and $script:WhSteps[$script:WhStep - 1].Panel -eq "PageRoam") {
        if (-not (Show-Confirm "Остановить монитор?" "Идёт запись роуминга. Остановить и сохранить результат шага?" "Остановить")) { return }
        Stop-RoamMonitor
    }
    $script:WhStep = $N
    $S = $script:WhSteps[$N - 1]
    if ($script:Wplan) { (Get-WhState).Step = $N; Save-Wplan }
    $script:WhPhase = ""
    $Ui.WhCalcExtra.Visibility = "Collapsed"
    $Ui.WhPrev.IsEnabled = ($N -gt 1)
    $Ui.WhNext.Visibility = $(if ($N -lt $script:WhSteps.Count) { "Visible" } else { "Collapsed" })
    $Ui.WhTitle.Text = "Шаг $N из $($script:WhSteps.Count) · $($S.Title)"
    $W = Get-WhState
    switch ($S.Key) {
        "prep" {
            $Ui.WhText.Text = $(if (-not @(Get-MtRouters).Count) { "Роутер MikroTik ещё не добавлен — подключи его (блок ниже), потом выбери объект. " } else { "" }) + "Выбери объект и роутер (кнопка «Найти в сети» ищет MikroTik, как Winbox). Список точек и их имена подтянутся из DHCP роутера. Двойной клик по точке — впиши её текущую мощность из Omada (Devices → точка → Config → Radios): тогда расчёт даст точные dBm."
            Update-WhPrep
        }
        { $_ -in @("roam1", "roam2") } {
            $script:WhPhase = $(if ($S.Key -eq "roam1") { "before" } else { "after" })
            $Ui.WhText.Text = $(if ($S.Key -eq "roam1") { "Исходная картина. «Старт» и пройди объект обычным шагом через зоны всех точек; задержись там, где обычно пропадает связь. В конце — «Стоп и диагноз»: результат сохранится как «до»." } else { "Повтори ту же прогулку после правок в Omada: «Старт» → маршрут → «Стоп и диагноз». Результат сохранится как «после» и пойдёт в итог." })
            if ($W.RouterId -and $Ui.RoamRouter) { $Ui.RoamRouter.SelectedValue = $W.RouterId }
        }
        "survey" {
            Set-WhPlanLayout "survey"
            $Ui.WpSeries.Text = $script:WplanBaseSeries
            $Ui.WhText.Text = "Замеры: в каждой комнате встань там, где обычно пользуются Wi-Fi, введи название и Enter. В дверях и коридорах между зонами точек — с галкой «Переход». Минимум по 2 места на точку, включая дальние углы."
        }
        "calc" {
            Set-WhPlanLayout "calc"
            $Ui.WpSeries.Text = $script:WplanBaseSeries
            Use-WplanSite
            $Ui.WpReport.Text = Get-WplanReport
            $Ui.WhCalcExtra.Visibility = "Visible"
            $Ui.WhApplied.IsChecked = [bool]$W.Applied
            $Ui.WhText.Text = "Ниже — прогноз и значения для каждой точки (после правки поправки или потолков — «Рассчитать»). «Лист для Omada» копирует таблицу (точка → канал → ширина → мощность). Внеси значения в Omada, затем отметь «Внёс в Omada» и нажми «Принять как текущие» — следующий расчёт будет от новых мощностей."
        }
        "survey2" {
            Set-WhPlanLayout "survey"
            if (-not $W.AfterSeries) {
                $L = @(Get-WplanSeriesList); $K = 1; while ($L -contains "После правок $K") { $K++ }
                $W.AfterSeries = "После правок $K"; Save-Wplan
            }
            $Ui.WpSeries.Text = $W.AfterSeries
            $Ui.WhText.Text = "Проверочный обход: те же места под ТЕМИ ЖЕ названиями, что в «Замерах» (серия «$($W.AfterSeries)»). Так итог сравнит было/стало по каждой комнате и переходу."
        }
        "sum" {
            $Ui.WhText.Text = "Сравнение до/после: сигнал по местам и роуминг по точкам. HTML-отчёт — для заказчика или монтажника; «Совет ИИ» разберёт, что осталось."
            Update-WhSummary
        }
    }
    Show-WhPanel $S.Panel
    Update-WhStepper
    Update-PageSub
}

# The planner panel is shared by the survey and calc steps; each step shows only its part (site, SSID and series
# are owned by the wizard: step 1 and the step itself).
function Get-WhUp {
    param($El, [type]$Type)
    $P = $El.Parent
    while ($P -and $P -isnot $Type) { $P = $P.Parent }
    return $P
}

function Set-WhPlanLayout {
    param([ValidateSet("survey", "calc")][string]$Mode)
    $Calc = ($Mode -eq "calc")
    $Vis = { param([bool]$On) if ($On) { "Visible" } else { "Collapsed" } }
    (Get-WhUp $Ui.WpSite ([System.Windows.Controls.Grid])).Visibility = "Collapsed"
    $Series = Get-WhUp $Ui.WpOffset ([System.Windows.Controls.Grid])
    $Series.Visibility = & $Vis $Calc
    $SBox = Get-WhUp $Ui.WpSeries ([System.Windows.Controls.StackPanel])
    $SBox.Visibility = "Collapsed"
    $Series.ColumnDefinitions[0].Width = New-Object System.Windows.GridLength 0
    $Series.ColumnDefinitions[1].Width = New-Object System.Windows.GridLength 0
    $Series.Margin = New-Object System.Windows.Thickness 0
    $Ui.WpRoom.Parent.Visibility = & $Vis (-not $Calc)
    $Ui.WpRoom.Parent.Margin = New-Object System.Windows.Thickness 0
    $Ui.WpStatus.Visibility = & $Vis (-not $Calc)
    $Lists = Get-WhUp $Ui.WpPoints ([System.Windows.Controls.Grid])
    $Lists.Visibility = & $Vis (-not $Calc)
    $Report = Get-WhUp $Ui.WpReport ([System.Windows.Controls.Border])
    $Report.Visibility = & $Vis $Calc
    # rows: lists take the free height while surveying, the report while calculating
    $Ui.PageWplan.RowDefinitions[1].Height = $(if ($Calc) { New-Object System.Windows.GridLength 0 } else { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) })
    $Ui.PageWplan.RowDefinitions[2].Height = $(if ($Calc) { New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star) } else { New-Object System.Windows.GridLength 0 })
    # report toolbar: the sheet lives in the wizard bar, comparison and HTML — in the summary step
    foreach ($B in @($Ui.WpCopySheet, $Ui.WpCompare, $Ui.WpHtml)) { $B.Visibility = "Collapsed" }
}

function Show-WhAir {
    Show-WhPanel "PageWifi"
    $Ui.WhTitle.Text = "Эфир · соседние сети"
    $Ui.WhText.Text = "Все сети вокруг: сигнал, канал, производитель. Полезно перед выбором каналов — видно, где соседи. Вернуться к мастеру — кнопка шага сверху."
    $Ui.WhCalcExtra.Visibility = "Collapsed"
    if (-not $script:WifiItems.Count) { Start-WifiScan }
}

function Get-WhSub {
    if (-not $script:Wplan) { return "Мастер: подготовка → тест → замеры → расчёт → проверка" }
    $Done = @(1..6 | Where-Object { Test-WhStepDone $_ }).Count
    return "$($script:Wplan.Site) · шагов выполнено: $Done из 6"
}

# ---------------------------------------------------------------- step 1: preparation

function Update-WhPrep {
    $W = Get-WhState
    $Ui.WhSite.Text = $(if ($script:Wplan) { $script:Wplan.Site } else { "" })
    $Ui.WhSsids.Text = $(if ($script:Wplan) { @($script:Wplan.Ssids) -join ", " } else { "" })
    # routers (a single known router is picked automatically)
    $All = @(Get-MtRouters)
    if (-not $W.RouterId -and $All.Count -eq 1 -and $script:Wplan) { $W.RouterId = $All[0].Id; Save-Wplan }
    $Ui.WhNoRouter.Visibility = $(if ($All.Count) { "Collapsed" } else { "Visible" })
    $Items = @([pscustomobject]@{ Id = ""; Label = "— выбери роутер —" }) + @(Get-MtRouters | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Label = "$($_.Name)  ·  $($_.Host)$(if (-not $_.Ready) { '  ·  не подготовлен' })" } })
    $script:WhRouterSync = $true
    $Ui.WhRouter.ItemsSource = $Items; $Ui.WhRouter.DisplayMemberPath = "Label"; $Ui.WhRouter.SelectedValuePath = "Id"
    $Ui.WhRouter.SelectedValue = $(if ($W.RouterId -and ($Items | Where-Object { $_.Id -eq $W.RouterId })) { $W.RouterId } else { "" })
    $script:WhRouterSync = $false
    # APs: router DHCP list ∪ planner list
    $Rows = [ordered]@{}
    foreach ($A in @(Get-MtCachedAps $W.RouterId)) { $Rows[$A.Key] = @{ Key = $A.Key; Name = $A.Name; Ip = $A.Ip; Mac = $A.Mac } }
    if ($script:Wplan) { foreach ($K in $script:Wplan.Aps.Keys) { if (-not $Rows.Contains($K)) { $Rows[$K] = @{ Key = $K; Name = ""; Ip = ""; Mac = "" } } } }
    $List = foreach ($K in $Rows.Keys) {
        $R = $Rows[$K]
        $A = $(if ($script:Wplan) { $script:Wplan.Aps[$K] } else { $null })
        $Nm = $(if ($A -and $A.Name) { $A.Name } elseif ($R.Name) { $R.Name } else { "AP " + $K })
        $Tx = $(if ($A -and ("$($A.Tx24)" -or "$($A.Tx5)")) { "2.4: $(if ("$($A.Tx24)") { $A.Tx24 } else { '?' }) · 5: $(if ("$($A.Tx5)") { $A.Tx5 } else { '?' }) dBm" } else { "мощность не указана" })
        [pscustomobject]@{ Key = $K; Label = ("{0,-24} {1,-16} {2,-18} {3}" -f $Nm, $R.Ip, $R.Mac, $Tx) }
    }
    $Ui.WhAps.ItemsSource = @($List); $Ui.WhAps.DisplayMemberPath = "Label"
    # readiness
    $C = @()
    $C += $(if ($script:Wplan -and $script:Wplan.Site) { "✔ объект: $($script:Wplan.Site)" } else { "✖ объект не выбран" })
    $C += $(if (@($script:Wplan.Ssids).Count) { "✔ SSID: $(@($script:Wplan.Ssids) -join ', ')" } else { "✖ SSID объекта не указан" })
    $Rt = $(if ($W.RouterId) { Get-MtRouter $W.RouterId } else { $null })
    $C += $(if ($Rt) { "✔ роутер: $($Rt.Name)$(if (-not $Rt.Ready) { ' (не подготовлен — работает через админа)' })" } else { "✖ роутер не выбран — без него не будет пинга точек и DHCP в тесте роуминга" })
    $NAp = @($List).Count
    $NTx = @($List | Where-Object { $_.Label -notmatch 'не указана' }).Count
    $C += $(if ($NAp) { "✔ точек: $NAp" } else { "✖ точки не найдены — «Обновить с роутера»" })
    $C += $(if ($NAp -and $NTx -eq $NAp) { "✔ мощности указаны у всех" } elseif ($NAp) { "▲ мощность указана у $NTx из $NAp — без неё рекомендации относительные" } else { "" })
    $Ui.WhChecks.Text = ($C | Where-Object { $_ }) -join "`n"
    Update-WhStepper
}

function Set-WhSite {
    param([string]$Site)
    $Site = $Site.Trim()
    if (-not $Site) { return }
    $Ui.WpSite.Text = $Site
    Open-WplanSite $Site
    Update-WhPrep
}

function Set-WhRouter {
    if ($script:WhRouterSync -or -not $script:Wplan) { return }
    $W = Get-WhState
    $W.RouterId = "$($Ui.WhRouter.SelectedValue)"
    Save-Wplan
    $script:Settings.RoamRouterId = $W.RouterId; Save-Settings
    if ($Ui.RoamRouter) { $Ui.RoamRouter.SelectedValue = $W.RouterId }
    if ($W.RouterId) { $R = Get-MtRouter $W.RouterId; if ($R -and -not @(Get-MtCachedAps $R.Id).Count) { Start-MtApRefresh $R { param($A) Update-WhPrep } } }
    Update-WhPrep
}

function Open-WhApDialog {
    $S = $Ui.WhAps.SelectedItem
    if (-not $S -or -not $script:Wplan) { return }
    if (-not $script:Wplan.Aps.ContainsKey($S.Key)) {
        $Nm = $(if ($script:Settings.MtApNames) { "$($script:Settings.MtApNames[$S.Key])" } else { "" })
        $script:Wplan.Aps[$S.Key] = @{ Name = $Nm; Tx24 = ""; Tx5 = ""; Bssids = @() }
    }
    Show-WplanApDialog $S.Key
    Update-WhPrep
}

# ---------------------------------------------------------------- roaming results per phase

function Get-WhRoamSummary {
    $R = $script:Roam
    if (-not $R -or -not $R.Count) { return $null }
    $Roams = @($R.Log | Where-Object { $_.Title -like "Роуминг*" } | Group-Object Time | ForEach-Object { $_.Group[-1] })
    $Aps = foreach ($St in @($R.Stats.Values)) {
        $V = Get-RoamApVerdict $St
        [ordered]@{ Name = (Get-RoamApName $St.Bssid); Bssid = $St.Bssid; Key = (Get-MtApKey $St.Bssid); Kind = $V.Kind; Msg = $(if ($V.Msgs.Count) { $V.Msgs[0] } else { "без замечаний" }); Loss = [Math]::Round($V.Loss, 1); RoamAvg = [Math]::Round($V.RoamAvg, 1) }
    }
    return [ordered]@{ Time = $R.Started.ToString("dd.MM HH:mm"); Minutes = [Math]::Round(([DateTime]::Now - $R.Started).TotalMinutes, 1); Roams = $Roams.Count
        Bad = @($Roams | Where-Object { $_.Kind -in @("warn", "fail") }).Count; Aps = @($Aps); Text = "$($script:RoamLastText)" }
}

function Save-WhRoamResult {
    if (-not $script:WhPhase -or -not $script:Wplan) { return }
    $S = Get-WhRoamSummary
    if (-not $S) { return }
    $W = Get-WhState
    if ($script:WhPhase -eq "before") { $W.RoamBefore = $S } else { $W.RoamAfter = $S }
    Save-Wplan
    Update-WhStepper
    Show-Toast "Роуминг «$(if ($script:WhPhase -eq 'before') { 'до' } else { 'после' })» сохранён в объект: переходов $($S.Roams), с потерей связи $($S.Bad)"
}

# ---------------------------------------------------------------- step 7: summary

function Update-WhSummary {
    if (-not $script:Wplan) { $Ui.WhSumText.Text = "Объект не выбран."; return }
    $W = Get-WhState
    $Out = [System.Text.StringBuilder]::new()
    [void]$Out.AppendLine("ИТОГ · $($script:Wplan.Site)")
    [void]$Out.AppendLine("")
    foreach ($N in 1..6) { [void]$Out.AppendLine(("  {0} {1}. {2}" -f $(if (Test-WhStepDone $N) { "✔" } else { "·" }), $N, $script:WhSteps[$N - 1].Title)) }
    [void]$Out.AppendLine("")
    [void]$Out.AppendLine("━━━ РОУМИНГ ━━━")
    $B = $W.RoamBefore; $A = $W.RoamAfter
    if ($B -and $A) {
        [void]$Out.AppendLine(("переходов с потерей связи: было {0} из {1} → стало {2} из {3}" -f $B.Bad, $B.Roams, $A.Bad, $A.Roams))
        $Keys = @(@($B.Aps) + @($A.Aps) | ForEach-Object { $_.Key } | Sort-Object -Unique)
        foreach ($K in $Keys) {
            $X = @($B.Aps) | Where-Object { $_.Key -eq $K } | Select-Object -First 1
            $Y = @($A.Aps) | Where-Object { $_.Key -eq $K } | Select-Object -First 1
            $Nm = $(if ($Y) { $Y.Name } else { $X.Name })
            $Mk = { param($Z) if (-not $Z) { "—" } else { switch ($Z.Kind) { "fail" { "✖" } "warn" { "▲" } default { "✔" } } } }
            [void]$Out.AppendLine(("  {0,-22} {1} → {2}   {3}" -f $Nm, (& $Mk $X), (& $Mk $Y), $(if ($Y) { $Y.Msg } else { "в тесте «после» не встречалась" })))
        }
    } elseif ($B) { [void]$Out.AppendLine("есть только тест «до» ($($B.Time)): переходов $($B.Roams), с потерей связи $($B.Bad). Пройди шаг 6.") }
    else { [void]$Out.AppendLine("тестов роуминга нет — шаги 2 и 6.") }
    [void]$Out.AppendLine("")
    [void]$Out.AppendLine("━━━ СИГНАЛ ПО МЕСТАМ ━━━")
    if ($W.AfterSeries) {
        $Keep = $script:Wplan.CurSeries
        $script:Wplan.CurSeries = $W.AfterSeries
        [void]$Out.AppendLine((Format-WplanCompare))
        $script:Wplan.CurSeries = $Keep
    } else { [void]$Out.AppendLine("проверочного обхода нет — шаг 5.") }
    $Ui.WhSumText.Text = $Out.ToString()
}

function Start-WhAi {
    if (-not $script:Wplan) { return }
    $Sys = "Ты инженер беспроводных сетей (TP-Link Omada, MikroTik). Дан итог настройки объекта: роуминг до/после по точкам (с диагнозами монитора), сравнение уровня сигнала по местам до/после правок мощностей и каналов. Оцени результат, назови что осталось плохим и что сделать дальше — по пунктам, по-русски, кратко."
    $Ui.WhSumAi.IsEnabled = $false
    $Ok = Start-AiRequest -Name "wh-ai" -System $Sys -UserText $Ui.WhSumText.Text -MaxTokens 2000 -OnResult {
        param($M)
        $Ui.WhSumAi.IsEnabled = $true
        if (-not $M.Ok) { Show-Toast "ИИ: $($M.Text)" "fail"; return }
        $Ui.WhSumText.Text = $Ui.WhSumText.Text + "`r`n━━━ СОВЕТ ИИ ━━━`r`n" + $M.Text
        $Ui.WhSumText.ScrollToEnd()
    }
    if (-not $Ok) { $Ui.WhSumAi.IsEnabled = $true }
}

# ---------------------------------------------------------------- wiring

function Show-WifiHub {
    if (-not $script:WhInit) { return }
    Set-WhStep $script:WhStep
    $W = $(if ($script:Wplan) { Get-WhState } else { $null })
    if ($W -and $W.RouterId -and -not $script:WhApsFresh) {
        $R = Get-MtRouter $W.RouterId
        if ($R -and $R.Ready) { $script:WhApsFresh = $true; Start-MtApRefresh $R { param($A) if ($script:WhStep -eq 1) { Update-WhPrep } } }
    }
}

function Initialize-WifiHub {
    # move the existing Wi-Fi panels into the wizard host
    foreach ($N in @("PageWifi", "PageWplan", "PageRoam")) {
        $P = $Ui[$N]
        if ($P.Parent -ne $Ui.WhHost) { $P.Parent.Children.Remove($P); [void]$Ui.WhHost.Children.Add($P) }
        $P.Margin = New-Object System.Windows.Thickness 0
        $P.Visibility = "Collapsed"
    }
    $Ui.WhPrev.Add_Click({ Set-WhStep ($script:WhStep - 1) })
    $Ui.WhNext.Add_Click({
        if ($script:WhStep -eq 1) {
            if (-not $script:Wplan) { Show-Toast "Укажи объект" "warn"; $Ui.WhSite.Focus(); return }
            if (-not (Get-WhState).RouterId -and -not (Show-Confirm "Без роутера?" "Роутер не выбран: тест роуминга не увидит пинг точек и DHCP, имена точек придётся вводить вручную. Продолжить без него?" "Продолжить")) { return }
        }
        Set-WhStep ($script:WhStep + 1)
    })
    $Ui.WhNoRtFind.Add_Click({ Start-MtDiscovery { param($T, $K) Set-MtStatus $T $K } })
    $Ui.WhNoRtAdd.Add_Click({ Show-MtConnectDialog $null; Update-WhPrep })
    $Ui.WhAir.Add_Click({ Show-WhAir })
    Add-PickMenu $Ui.WhSitePick $Ui.WhSite { @(Get-WplanSites | ForEach-Object { [pscustomobject]@{ Label = $_; Value = $_ } }) }
    $Ui.WhSite.Add_LostKeyboardFocus({ $S = $Ui.WhSite.Text.Trim(); if ($S -and (-not $script:Wplan -or $script:Wplan.Site -ne $S)) { Set-WhSite $S } })
    $Ui.WhSite.Add_TextChanged({ $S = $Ui.WhSite.Text.Trim(); if ($S -and (Test-Path (Get-WplanPath $S)) -and (-not $script:Wplan -or $script:Wplan.Site -ne $S)) { Set-WhSite $S } })
    $Ui.WhSsids.Add_LostKeyboardFocus({ if ($script:Wplan) { $Ui.WpSsids.Text = $Ui.WhSsids.Text; Use-WplanSite; Save-Wplan; $script:WplanLastReport = $null; Update-WhPrep } })
    $Ui.WhRouter.Add_SelectionChanged({ Set-WhRouter })
    $Ui.WhFind.Add_Click({ Start-MtDiscovery { param($T, $K) Set-MtStatus $T $K } })
    $Ui.WhPrepare.Add_Click({ $R = Get-MtRouter "$($Ui.WhRouter.SelectedValue)"; Show-MtConnectDialog $R; Update-WhPrep })
    $Ui.WhTest.Add_Click({ $R = Get-MtRouter "$($Ui.WhRouter.SelectedValue)"; if ($R) { Set-MtStatus "$($R.Name): подключаюсь…" "wait"; Test-MtRouter $R } else { Show-Toast "Выбери роутер" "warn" } })
    $Ui.WhApsRefresh.Add_Click({ $R = Get-MtRouter "$($Ui.WhRouter.SelectedValue)"; if ($R) { Start-MtApRefresh $R { param($A) Update-WhPrep } } else { Show-Toast "Выбери роутер" "warn" } })
    $Ui.WhAps.Add_MouseDoubleClick({ Open-WhApDialog })
    $Ui.WhCopySheet.Add_Click({ Use-WplanSite; $T = Get-WplanSheet; if ($T) { Copy-Text $T "лист для Omada" } else { Show-Toast "Нет расчёта — сначала замеры" "warn" } })
    $Ui.WhApplied.Add_Click({ if ($script:Wplan) { (Get-WhState).Applied = [bool]$Ui.WhApplied.IsChecked; Save-Wplan; Update-WhStepper } })
    $Ui.WhAdopt.Add_Click({
        $R = $script:WplanLastReport
        if (-not $R -or $R.Error) { Show-Toast "Нет расчёта" "warn"; return }
        $N = 0
        foreach ($B in $R.Bands.Keys) { foreach ($K in $R.Bands[$B].Aps.Keys) { $A = $R.Bands[$B].Aps[$K]; if ($null -ne $A.Rec -and $script:Wplan.Aps.ContainsKey($K)) { $script:Wplan.Aps[$K]["Tx" + ($B -replace '\.', '')] = "$($A.Rec)"; $N++ } } }
        $script:WplanLastReport = $null
        Save-Wplan; Refresh-Wplan
        Show-Toast "Принято как текущие: $N значений мощности"
    })
    $Ui.WhSumRefresh.Add_Click({ Update-WhSummary })
    $Ui.WhSumHtml.Add_Click({ Use-WplanSite; Export-WplanHtml })
    $Ui.WhSumCopy.Add_Click({ Copy-Text $Ui.WhSumText.Text "итог" })
    $Ui.WhSumAi.Add_Click({ Start-WhAi })
    $script:WhInit = $true
    if ($script:Wplan) { $script:WhStep = [int]$(if ((Get-WhState).Step) { (Get-WhState).Step } else { 1 }) }
}
