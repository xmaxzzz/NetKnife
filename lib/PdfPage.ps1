# Renders one PDF page to PNG with the Windows built-in PDF engine (Windows.Data.Pdf). WinRT projections are
# available in Windows PowerShell 5.1, not in PowerShell 7 — NetKnife runs this file with powershell.exe (pagesFloor.ps1), it is not dot-sourced.
#   -Page -1  → prints "PAGES <n>" only
#   output    → "OK <pages>" or "ERR <message>"
param([Parameter(Mandatory)][string]$Pdf, [string]$Out = "", [int]$Page = 0, [int]$Width = 2400)
$ErrorActionPreference = "Stop"
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.StorageFolder, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
    $Ext = [System.WindowsRuntimeSystemExtensions].GetMethods()
    $AsOp = $Ext | Where-Object { $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    $AsAct = $Ext | Where-Object { $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq "IAsyncAction" } | Select-Object -First 1
    function Wait-Op($Op, [type]$T) { $Tk = $AsOp.MakeGenericMethod($T).Invoke($null, @($Op)); $Tk.Wait(); return $Tk.Result }

    $File = Wait-Op ([Windows.Storage.StorageFile]::GetFileFromPathAsync((Resolve-Path $Pdf).Path)) ([Windows.Storage.StorageFile])
    $Doc = Wait-Op ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($File)) ([Windows.Data.Pdf.PdfDocument])
    if ($Page -lt 0) { "PAGES $($Doc.PageCount)"; return }
    if ($Page -ge $Doc.PageCount) { $Page = $Doc.PageCount - 1 }
    $P = $Doc.GetPage([uint32]$Page)
    $Opt = New-Object Windows.Data.Pdf.PdfPageRenderOptions
    $Opt.DestinationWidth = [uint32]$Width
    $Dir = Split-Path ([IO.Path]::GetFullPath($Out))
    $Folder = Wait-Op ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($Dir)) ([Windows.Storage.StorageFolder])
    $Target = Wait-Op ($Folder.CreateFileAsync((Split-Path $Out -Leaf), [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
    $S = Wait-Op ($Target.OpenAsync([Windows.Storage.FileAccessMode]::ReadWrite)) ([Windows.Storage.Streams.IRandomAccessStream])
    $AsAct.Invoke($null, @($P.RenderToStreamAsync($S, $Opt))).Wait()   # PNG by default
    $S.Dispose(); $P.Dispose()
    "OK $($Doc.PageCount)"
} catch {
    # Windows PowerShell 5.1: no ?? operator
    $E = $_.Exception; while ($E.InnerException) { $E = $E.InnerException }
    "ERR $($E.Message)"
}
