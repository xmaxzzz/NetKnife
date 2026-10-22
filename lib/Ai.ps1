# AI client for in-app analysis. Two providers:
#   gateway   — our AI Gateway (OpenAI-compatible chat/completions, default https://ai.butlerdc.ae/v1, model
#               "sonnet", Claude subscription) — the default;
#   anthropic — Claude API directly (api.anthropic.com/v1/messages).
# Keys are DPAPI-encrypted in settings.json (AiGwKeyEnc / AiKeyEnc); env ANTHROPIC_API_KEY overrides the direct one.
# A picture (floor plan, walk map) is optional: if the gateway refuses it, the request is repeated as text only
# and the reply carries NoImage = $true (callers that need the picture say so).

$script:AiDefaults = @{
    gateway   = @{ Url = "https://ai.butlerdc.ae/v1"; Model = "sonnet"; Title = "AI Gateway Butler" }
    anthropic = @{ Url = "https://api.anthropic.com/v1"; Model = "claude-sonnet-5-5"; Title = "Claude API напрямую" }
}

function Get-AiProvider { $P = "$($script:Settings.AiProvider)"; if ($script:AiDefaults.ContainsKey($P)) { return $P }; return "gateway" }

function Get-AiConf {
    $P = Get-AiProvider
    $D = $script:AiDefaults[$P]
    if ($P -eq "gateway") {
        return @{ Provider = $P; Url = $(if ($script:Settings.AiGwUrl) { "$($script:Settings.AiGwUrl)".TrimEnd('/') } else { $D.Url }); Model = $(if ($script:Settings.AiGwModel) { "$($script:Settings.AiGwModel)" } else { $D.Model }); Title = $D.Title }
    }
    return @{ Provider = $P; Url = $D.Url; Model = $(if ($script:Settings.AiModel) { "$($script:Settings.AiModel)" } else { $D.Model }); Title = $D.Title }
}

function Unprotect-AiKey { param([string]$Enc) if (-not $Enc) { return "" }; try { return [System.Net.NetworkCredential]::new("", (ConvertTo-SecureString $Enc)).Password } catch { return "" } }
function Protect-AiKey { param([string]$Key) if (-not $Key) { return "" }; return (ConvertTo-SecureString $Key -AsPlainText -Force | ConvertFrom-SecureString) }

function Get-AiKey {
    param([string]$Provider = (Get-AiProvider))
    if ($Provider -eq "gateway") { return Unprotect-AiKey "$($script:Settings.AiGwKeyEnc)" }
    if ($env:ANTHROPIC_API_KEY) { return $env:ANTHROPIC_API_KEY }
    return Unprotect-AiKey "$($script:Settings.AiKeyEnc)"
}

function Get-AiStatusText {
    $C = Get-AiConf
    return "$($C.Title) · $($C.Model)$(if ($C.Provider -eq 'gateway') { ' · ' + $C.Url }) · $(if (Get-AiKey) { 'ключ задан' } else { 'ключ не задан' })"
}

function Show-AiKeyDialog {
    $C = Get-AiConf
    $D = New-Dialog "ИИ-анализ" @"
<StackPanel>
    <TextBlock Text="ИИ-анализ" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="Разбор замеров, прогулок и плана помещений. Ключи хранятся зашифрованными (DPAPI, только этот пользователь Windows) в settings.json и на экран не возвращаются." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,14" FontSize="12.5"/>
    <TextBlock Text="ПРОВАЙДЕР" Style="{StaticResource Caption}"/>
    <ComboBox x:Name="FProv" Margin="0,2,0,0"/>
    <TextBlock x:Name="FUrlCap" Text="BASE URL (OpenAI-совместимый)" Style="{StaticResource Caption}" Margin="2,12,0,6"/>
    <TextBox x:Name="FUrl" Style="{StaticResource MonoField}"/>
    <TextBlock Text="МОДЕЛЬ" Style="{StaticResource Caption}" Margin="2,12,0,6"/>
    <TextBox x:Name="FModel" Style="{StaticResource MonoField}"/>
    <TextBlock x:Name="FKeyCap" Style="{StaticResource Caption}" Margin="2,12,0,6"/>
    <PasswordBox x:Name="FKey" FontFamily="{StaticResource MonoFont}" Padding="10,8"/>
    <TextBlock x:Name="FStatus" FontSize="12.5" TextWrapping="Wrap" Margin="2,10,0,0" Visibility="Collapsed"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button x:Name="FClear" Style="{StaticResource Btn}" Content="Удалить ключ" MinWidth="110"/>
        <Button x:Name="FTest" Style="{StaticResource Btn}" Content="Проверить" MinWidth="100" Margin="8,0,0,0"/>
        <Button Style="{StaticResource Btn}" Content="Отмена" MinWidth="90" IsCancel="True" Margin="8,0,0,0"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Сохранить" MinWidth="110" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@ 560
    $F = @{}; foreach ($N in @("FProv", "FUrl", "FUrlCap", "FModel", "FKey", "FKeyCap", "FStatus", "FClear", "FTest", "FOk")) { $F[$N] = $D.FindName($N) }
    $F.FProv.ItemsSource = @(foreach ($K in @("gateway", "anthropic")) { [pscustomobject]@{ Key = $K; Label = $script:AiDefaults[$K].Title } })
    $F.FProv.DisplayMemberPath = "Label"; $F.FProv.SelectedValuePath = "Key"
    $script:AiDlg = @{ F = $F; D = $D }
    $Fill = {
        $F = $script:AiDlg.F
        $P = "$($F.FProv.SelectedValue)"
        $Gw = ($P -eq "gateway")
        $F.FUrl.Visibility = $(if ($Gw) { "Visible" } else { "Collapsed" }); $F.FUrlCap.Visibility = $F.FUrl.Visibility
        $F.FUrl.Text = $(if ($script:Settings.AiGwUrl) { "$($script:Settings.AiGwUrl)" } else { $script:AiDefaults.gateway.Url })
        $F.FModel.Text = $(if ($Gw) { if ($script:Settings.AiGwModel) { "$($script:Settings.AiGwModel)" } else { $script:AiDefaults.gateway.Model } } else { if ($script:Settings.AiModel) { "$($script:Settings.AiModel)" } else { $script:AiDefaults.anthropic.Model } })
        $Has = [bool](Get-AiKey $P)
        $F.FKeyCap.Text = $(if ($Has) { "API-КЛЮЧ · ЗАДАН — ОСТАВЬ ПУСТЫМ, ЧТОБЫ НЕ МЕНЯТЬ" } elseif ($Gw) { "API-КЛЮЧ ШЛЮЗА (sk-…)" } else { "API-КЛЮЧ CLAUDE (sk-ant-…)" })
        $F.FKey.Password = ""
    }
    $script:AiDlg.Fill = $Fill
    $F.FProv.SelectedValue = $C.Provider
    & $Fill
    $F.FProv.Add_SelectionChanged({ & $script:AiDlg.Fill })
    $Save = {
        $F = $script:AiDlg.F
        $P = "$($F.FProv.SelectedValue)"
        $script:Settings.AiProvider = $P
        $K = $F.FKey.Password.Trim()
        if ($P -eq "gateway") {
            $U = $F.FUrl.Text.Trim().TrimEnd('/'); if ($U) { $script:Settings.AiGwUrl = $U }
            $M = $F.FModel.Text.Trim(); if ($M) { $script:Settings.AiGwModel = $M }
            if ($K) { $script:Settings.AiGwKeyEnc = Protect-AiKey $K }
        } else {
            $M = $F.FModel.Text.Trim(); if ($M) { $script:Settings.AiModel = $M }
            if ($K) { $script:Settings.AiKeyEnc = Protect-AiKey $K }
        }
        Save-Settings
        $F.FKey.Password = ""
    }
    $script:AiDlg.Save = $Save
    $F.FClear.Add_Click({
        $P = "$($script:AiDlg.F.FProv.SelectedValue)"
        if ($P -eq "gateway") { $script:Settings.AiGwKeyEnc = "" } else { $script:Settings.AiKeyEnc = "" }
        Save-Settings; & $script:AiDlg.Fill
    })
    $F.FTest.Add_Click({
        & $script:AiDlg.Save; & $script:AiDlg.Fill
        $S = $script:AiDlg.F.FStatus
        $S.Visibility = "Visible"; $S.Foreground = Get-Brush "Warn"; $S.Text = "Проверяю $((Get-AiConf).Title)…"
        $Ok = Start-AiRequest -Name "ai-test" -System "Отвечай одним словом." -UserText "Ответь: готов" -MaxTokens 20 -NoPrompt -OnResult {
            param($M)
            $S = $script:AiDlg.F.FStatus
            if (-not $script:AiDlg.D.IsVisible) { return }
            $S.Foreground = Get-Brush $(if ($M.Ok) { "Ok" } else { "Fail" })
            $S.Text = $(if ($M.Ok) { "Работает: «$("$($M.Text)".Trim())»$(if ($M.InTok) { " · токенов $($M.InTok)+$($M.OutTok)" })" } else { "Ошибка: $($M.Text)" })
        }
        if (-not $Ok) { $S.Foreground = Get-Brush "Fail"; $S.Text = "Нет ключа" }
    })
    $F.FOk.Add_Click({ & $script:AiDlg.Save; $script:AiDlg.D.DialogResult = $true })
    $D.Add_ContentRendered({ [void]$script:AiDlg.F.FKey.Focus() })
    $R = $D.ShowDialog()
    Stop-Worker "ai-test"
    if ($Ui.SetAiStatus) { $Ui.SetAiStatus.Text = Get-AiStatusText }
    if ($R) { Show-Toast $(if (Get-AiKey) { "ИИ: $((Get-AiConf).Title)" } else { "ИИ: ключ не задан" }) "info" }
}

# Worker body: one request, returns text. Runs in a thread job (no UI access).
$script:AiBody = {
    param($Q, $Ctl, $Conf, $Key, $System, $UserText, $MaxTokens, $ImageB64, $ImageType)
    $Err = { param($E) while ($E.InnerException) { $E = $E.InnerException }; return "$($E.Message)" }
    $Send = {
        param([bool]$WithImage)
        $H = [System.Net.Http.HttpClient]::new()
        $H.Timeout = [TimeSpan]::FromSeconds(180)
        if ($Conf.Provider -eq "anthropic") {
            $H.DefaultRequestHeaders.Add("x-api-key", $Key)
            $H.DefaultRequestHeaders.Add("anthropic-version", "2023-06-01")
            # the picture goes before the text, as the API recommends
            $Content = $(if ($WithImage) { @(@{ type = "image"; source = @{ type = "base64"; media_type = $ImageType; data = $ImageB64 } }, @{ type = "text"; text = $UserText }) } else { $UserText })
            $Body = @{ model = $Conf.Model; max_tokens = $MaxTokens; system = $System; messages = @(@{ role = "user"; content = $Content }) }
            $Url = "$($Conf.Url)/messages"
        } else {
            $H.DefaultRequestHeaders.Add("Authorization", "Bearer $Key")
            $Content = $(if ($WithImage) { @(@{ type = "image_url"; image_url = @{ url = "data:$ImageType;base64,$ImageB64" } }, @{ type = "text"; text = $UserText }) } else { $UserText })
            $Body = @{ model = $Conf.Model; max_tokens = $MaxTokens; messages = @(@{ role = "system"; content = $System }, @{ role = "user"; content = $Content }) }
            $Url = "$($Conf.Url)/chat/completions"
        }
        $C = [System.Net.Http.StringContent]::new(($Body | ConvertTo-Json -Depth 10), [System.Text.Encoding]::UTF8, "application/json")
        $R = $H.PostAsync($Url, $C).Result
        $Txt = $R.Content.ReadAsStringAsync().Result
        $H.Dispose()
        return @{ Code = [int]$R.StatusCode; Ok = $R.IsSuccessStatusCode; Text = $Txt }
    }
    try {
        $NoImage = $false
        $R = & $Send ([bool]$ImageB64)
        # the gateway may not accept pictures: retry with text only (auth/limit errors are not retried)
        if (-not $R.Ok -and $ImageB64 -and $R.Code -in @(400, 413, 415, 422, 500, 502)) { $NoImage = $true; $R = & $Send $false }
        if (-not $R.Ok) { $Q.Enqueue(@{ Type = "ai"; Ok = $false; Text = "HTTP $($R.Code): $($R.Text)"; NoImage = $NoImage }); return }
        $J = $R.Text | ConvertFrom-Json
        if ($Conf.Provider -eq "anthropic") {
            $Out = ($J.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n"
            $In = $J.usage.input_tokens; $Ot = $J.usage.output_tokens
        } else {
            $Msg = $J.choices[0].message.content
            $Out = $(if ($Msg -is [string]) { $Msg } else { (@($Msg) | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n" })
            $In = $J.usage.prompt_tokens; $Ot = $J.usage.completion_tokens
        }
        $Q.Enqueue(@{ Type = "ai"; Ok = $true; Text = "$Out"; InTok = $In; OutTok = $Ot; NoImage = $NoImage })
    } catch {
        $Q.Enqueue(@{ Type = "ai"; Ok = $false; Text = (& $Err $_.Exception) })
    }
}

function Start-AiRequest {
    param([string]$Name, [string]$System, [string]$UserText, [int]$MaxTokens = 2500, [scriptblock]$OnResult, [string]$ImageB64 = "", [string]$ImageType = "image/jpeg", [switch]$NoPrompt)
    $Key = Get-AiKey
    if (-not $Key) {
        if ($NoPrompt) { return $false }
        Show-Toast "ИИ не настроен — укажи ключ" "warn"; Show-AiKeyDialog; $Key = Get-AiKey; if (-not $Key) { return $false }
    }
    $Conf = Get-AiConf
    if (-not $script:AiCallbacks) { $script:AiCallbacks = @{} }
    $script:AiCallbacks[$Name] = $OnResult
    [void](Start-Worker -Name $Name -Replace -Body $script:AiBody -ArgList @($Conf, $Key, $System, $UserText, $MaxTokens, $ImageB64, $ImageType) -State @{ Name = $Name } -OnMessage {
        param($M)
        if ($M.Type -ne "ai") { return }
        & $script:AiCallbacks[$State.Name] $M
    })
    return $true
}

# Pull the first JSON object out of a model reply (handles ```json fences and prose around it)
function ConvertFrom-AiJson {
    param([string]$Text)
    $T = $Text -replace '(?s)```(?:json)?\s*(.*?)```', '$1'
    $Start = $T.IndexOf('{'); $End = $T.LastIndexOf('}')
    if ($Start -lt 0 -or $End -le $Start) { return $null }
    try { return ($T.Substring($Start, $End - $Start + 1) | ConvertFrom-Json) } catch { return $null }
}
