# Claude API client for in-app analysis. Key: env ANTHROPIC_API_KEY, else DPAPI-encrypted in settings (AiKeyEnc).

$script:AiModel = "claude-sonnet-5-5"

function Get-AiKey {
    if ($env:ANTHROPIC_API_KEY) { return $env:ANTHROPIC_API_KEY }
    $Enc = $script:Settings.AiKeyEnc
    if (-not $Enc) { return "" }
    try {
        $Sec = ConvertTo-SecureString $Enc
        return [System.Net.NetworkCredential]::new("", $Sec).Password
    } catch { return "" }
}

function Set-AiKey {
    param([string]$Key)
    if (-not $Key) { $script:Settings.AiKeyEnc = ""; Save-Settings; return }
    $script:Settings.AiKeyEnc = (ConvertTo-SecureString $Key -AsPlainText -Force | ConvertFrom-SecureString)
    Save-Settings
}

function Show-AiKeyDialog {
    $Has = [bool](Get-AiKey)
    $D = New-Dialog "Ключ Claude API" @"
<StackPanel>
    <TextBlock Text="Ключ Claude API" FontFamily="{StaticResource DisplayFont}" FontSize="20" FontWeight="SemiBold"/>
    <TextBlock Text="Хранится зашифрованным (DPAPI, только этот пользователь Windows) в settings.json. Если задана переменная окружения ANTHROPIC_API_KEY — используется она." Foreground="{StaticResource Sub}" TextWrapping="Wrap" Margin="0,6,0,14" FontSize="12.5"/>
    <TextBlock Text="$(if ($Has) { 'КЛЮЧ ЗАДАН · ВСТАВЬ НОВЫЙ, ЧТОБЫ ЗАМЕНИТЬ' } else { 'ВСТАВЬ КЛЮЧ (sk-ant-…)' })" Style="{StaticResource Caption}"/>
    <TextBox x:Name="FKey" Style="{StaticResource MonoField}" Tag="sk-ant-api03-…"/>
    <TextBlock Text="МОДЕЛЬ" Style="{StaticResource Caption}" Margin="2,12,0,6"/>
    <TextBox x:Name="FModel" Style="{StaticResource MonoField}" Text="$($script:Settings.AiModel ?? $script:AiModel)"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,18,0,0">
        <Button x:Name="FClear" Style="{StaticResource Btn}" Content="Удалить ключ" MinWidth="110"/>
        <Button x:Name="FCancel" Style="{StaticResource Btn}" Content="Отмена" MinWidth="96" IsCancel="True" Margin="8,0,0,0"/>
        <Button x:Name="FOk" Style="{StaticResource AccentBtn}" Content="Сохранить" MinWidth="120" Margin="8,0,0,0" IsDefault="True"/>
    </StackPanel>
</StackPanel>
"@ 520
    $FKey = $D.FindName("FKey"); $FModel = $D.FindName("FModel")
    $D.FindName("FClear").Add_Click({ Set-AiKey ""; $D.DialogResult = $true })
    $D.FindName("FOk").Add_Click({
        $K = $FKey.Text.Trim()
        if ($K) { Set-AiKey $K }
        $M = $FModel.Text.Trim(); if ($M) { $script:Settings.AiModel = $M; Save-Settings }
        $D.DialogResult = $true
    })
    $D.Add_ContentRendered({ [void]$FKey.Focus() })
    if ($D.ShowDialog()) { Show-Toast $(if (Get-AiKey) { "Ключ Claude сохранён" } else { "Ключ Claude удалён" }) "info" }
}

# Worker body: one messages call, returns text. Runs in a thread job (no UI access).
$script:AiBody = {
    param($Q, $Ctl, $Key, $Model, $System, $UserText, $MaxTokens)
    try {
        $H = [System.Net.Http.HttpClient]::new()
        $H.Timeout = [TimeSpan]::FromSeconds(120)
        $H.DefaultRequestHeaders.Add("x-api-key", $Key)
        $H.DefaultRequestHeaders.Add("anthropic-version", "2023-06-01")
        $Body = @{ model = $Model; max_tokens = $MaxTokens; system = $System; messages = @(@{ role = "user"; content = $UserText }) } | ConvertTo-Json -Depth 6
        $C = [System.Net.Http.StringContent]::new($Body, [System.Text.Encoding]::UTF8, "application/json")
        $R = $H.PostAsync("https://api.anthropic.com/v1/messages", $C).Result
        $Txt = $R.Content.ReadAsStringAsync().Result
        if (-not $R.IsSuccessStatusCode) { $Q.Enqueue(@{ Type = "ai"; Ok = $false; Text = "HTTP $([int]$R.StatusCode): $Txt" }); return }
        $J = $Txt | ConvertFrom-Json
        $Out = ($J.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n"
        $Q.Enqueue(@{ Type = "ai"; Ok = $true; Text = $Out; InTok = $J.usage.input_tokens; OutTok = $J.usage.output_tokens })
    } catch {
        $Q.Enqueue(@{ Type = "ai"; Ok = $false; Text = "$($_.Exception.InnerException.Message ?? $_.Exception.Message)" })
    }
}

function Start-AiRequest {
    param([string]$Name, [string]$System, [string]$UserText, [int]$MaxTokens = 2500, [scriptblock]$OnResult)
    $Key = Get-AiKey
    if (-not $Key) { Show-Toast "Нет ключа Claude API — задай в настройках ИИ" "warn"; Show-AiKeyDialog; $Key = Get-AiKey; if (-not $Key) { return $false } }
    $Model = if ($script:Settings.AiModel) { $script:Settings.AiModel } else { $script:AiModel }
    [void](Start-Worker -Name $Name -Replace -Body $script:AiBody -ArgList @($Key, $Model, $System, $UserText, $MaxTokens) -OnMessage {
        param($M)
        if ($M.Type -ne "ai") { return }
        & $script:AiCallbacks[$Name] $M
    })
    if (-not $script:AiCallbacks) { $script:AiCallbacks = @{} }
    $script:AiCallbacks[$Name] = $OnResult
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
