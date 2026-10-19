# Page: app settings (startup page, window behavior, data folder).

function Initialize-SettingsPage {
    # startup page dropdown — list every page by its sidebar title
    $Items = foreach ($K in $script:Pages.get_Keys()) {
        if ($K -eq "settings") { continue }
        [pscustomobject]@{ Key = $K; Label = $script:Pages[$K].Title }
    }
    $Ui.SetStartupPage.ItemsSource = @($Items)
    $Ui.SetStartupPage.DisplayMemberPath = "Label"
    $Ui.SetStartupPage.SelectedValuePath = "Key"
    $Cur = "$($script:Settings.StartupPage)"
    if (-not $script:Pages.Contains($Cur)) { $Cur = "hosts" }
    $Ui.SetStartupPage.SelectedValue = $Cur
    $Ui.SetStartupPage.Add_SelectionChanged({
        $V = $Ui.SetStartupPage.SelectedValue
        if ($V) { $script:Settings.StartupPage = "$V"; Save-Settings }
    })

    $Ui.SetTheme.ItemsSource = @(foreach ($K in $script:Themes.Keys) { [pscustomobject]@{ Key = $K; Label = $script:Themes[$K] } })
    $Ui.SetTheme.DisplayMemberPath = "Label"; $Ui.SetTheme.SelectedValuePath = "Key"
    $Ui.SetTheme.SelectedValue = $(if ($script:Themes.Contains("$($script:Settings.Theme)")) { "$($script:Settings.Theme)" } else { "system" })
    $Ui.SetTheme.Add_SelectionChanged({
        $V = "$($Ui.SetTheme.SelectedValue)"
        if ($V -and $V -ne "$($script:Settings.Theme)") { $script:Settings.Theme = $V; Save-Settings; Restart-App }
    })

    $Ui.SetTray.IsChecked = [bool]$script:Settings.MinimizeToTray
    $Ui.SetTray.Add_Click({ $script:Settings.MinimizeToTray = [bool]$Ui.SetTray.IsChecked; Save-Settings })

    $Ui.SetHotKey.IsChecked = [bool]$script:Settings.HotKey
    $Ui.SetHotKey.Add_Click({ $script:Settings.HotKey = [bool]$Ui.SetHotKey.IsChecked; Save-Settings })

    $Ui.SetVersion.Text = "NetKnife $($script:AppVersion)"
    $Ui.SetUpdStatus.Text = "Релизы: github.com/$($script:UpdateRepo)"
    $Ui.SetUpdCheck.Add_Click({ Start-UpdateCheck -Manual })
    $Ui.SetUpdApply.Add_Click({ Install-AppUpdate })
    $Ui.SetUpdSite.Add_Click({ Start-Process "https://github.com/$($script:UpdateRepo)/releases" })
    $Ui.SetUpdAuto.IsChecked = [bool]$script:Settings.AutoUpdateCheck
    $Ui.SetUpdAuto.Add_Click({ $script:Settings.AutoUpdateCheck = [bool]$Ui.SetUpdAuto.IsChecked; Save-Settings })

    Initialize-MtSettings

    $Ui.SetDataPath.Text = $script:DataDir
    $Ui.SetOpenData.Add_Click({ Start-Process explorer.exe -ArgumentList (Quote-Arg $script:DataDir) })
    $Ui.SetOpenLog.Add_Click({
        if (Test-Path $script:LogPath) { Start-Process notepad.exe -ArgumentList (Quote-Arg $script:LogPath) }
        else { Show-Toast "Журнал пока пуст" "info" }
    })
}
