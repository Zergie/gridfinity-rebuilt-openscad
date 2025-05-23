[cmdletbinding()]
param(
    [Parameter()]
    [switch]
    $Update
)
$openscad = Get-ChildItem "$env:ProgramFiles\OpenSCAD*" -Directory | Get-ChildItem -File -Filter openscad.exe | Sort-Object VersionInfo -Top 1 
$version_installed = $openscad.VersionInfo.FileVersion |
                        Select-String "\d{4}\.\d{2}\.\d{2}" |
                        ForEach-Object { $_.Matches.Value }
$version_online = (Invoke-WebRequest "https://files.openscad.org/snapshots/").links.href |
            ForEach-Object { "https://files.openscad.org/snapshots/$_" } |
            Where-Object { $_ -like "*-Installer.exe" } | 
            Sort-Object -Bottom 1 |
            Select-String "\d{4}\.\d{2}\.\d{2}" |
            ForEach-Object { $_.Matches.Value }

if ($Update) {
    if ($version_installed -lt $version_online) {
        (Invoke-WebRequest "https://files.openscad.org/snapshots/").links.href |
            ForEach-Object { "https://files.openscad.org/snapshots/$_" } |
            Where-Object { $_ -like "*-Installer.exe" } |
            Sort-Object -Bottom 1 |
            ForEach-Object {
                Invoke-WebRequest $_ -OutFile $env:TEMP\openscad-installer.exe
            }
        Start-Process $env:TEMP\openscad-installer.exe -ArgumentList "/D=C:\Program Files\OpenSCAD (Nightly)" -Wait
        # Remove-Item $env:TEMP\openscad-installer.exe
    } else {
        Write-Host ""
        Write-Host "OpenScad already up-to-date!"
        Write-Host " Version online:    $version_online"
        Write-Host " Version installed: $version_installed"
        Write-Host ""
    }
    exit
} elseif ($version_installed -lt $version_online) {
    Write-Host -ForegroundColor Yellow "********************************************************************************"
    Write-Host -ForegroundColor Yellow "* $("New OpenScad Nightly available: $version_online (installed: $version_installed)".PadRight(76)) *"
    Write-Host -ForegroundColor Yellow "* $("Run  $($MyInvocation.MyCommand) -Update  to install.".PadRight(76))*"
    Write-Host -ForegroundColor Yellow "********************************************************************************"
    Write-Host -ForegroundColor Yellow ""
}

$openscad.FullName
