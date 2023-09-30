[cmdletbinding()]
param(
    [Parameter(ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$false)]
    [switch]
    $Rebuild,

    [Parameter(ValueFromPipeline=$true,
               ValueFromPipelineByPropertyName=$false)]
    [int]
    $Processes = 10
)

$openscad = "C:\Program Files\OpenSCAD\openscad.exe"
$scadFile = (Resolve-Path "$PSScriptRoot\..\gridfinity-rebuilt-bins.scad").Path

$parameter = [System.Collections.ArrayList]::new()
foreach ($divx in 1..6) {
    foreach ($divy in 1..1) {
        foreach ($gridz in @(3,6)) {
            foreach ($gridx in 1..6) {
                foreach ($gridy in 1..4) {
                    foreach ($style_tab in @(0, 5)) {
                        foreach ($scoop in @(0, 1)) {

                            $continue = $true
                            $continue = $continue -and ($gridx / $divx) -ge 0.33

                            if ($scoop -ne 0 -or $style_tab -ne 5) {
                                $continue = $continue -and (($gridy / $divy) -ge 1)
                                $continue = $continue -and ($gridy -eq 1)
                            }

                            # when 'noscoop' and 'notab'
                            if ($scoop -eq 0 -and $style_tab -eq 5) {
                                $continue = $continue -and ($gridx -le $gridy)
                            }
                            
                            if ($continue) {
                                $parameter.Add([pscustomobject]@{
                                    divx      = $divx
                                    divy      = $divy
                                    gridz     = $gridz
                                    gridx     = $gridx
                                    gridy     = $gridy
                                    style_tab = $style_tab
                                    scoop     = $scoop
                                }) | Out-Null
                            }
                        }
                    }
                }
            }
        }
    }
}

$parameter.Add([pscustomobject]@{
    divx      = 2
    divy      = 4
    gridz     = 6
    gridx     = 1
    gridy     = 2
    style_tab = 5
    scoop     = 0
}) | Out-Null

$json = [System.Collections.ArrayList]::new()
$parameter |
ForEach-Object {
@"
{
    "div_base_x": "0",
    "div_base_y": "0",
    "divx": "$($_.divx)",
    "divy": "$($_.divy)",
    "enable_zsnap": "false",
    "gridx": "$($_.gridx)",
    "gridy": "$($_.gridy)",
    "gridz": "$($_.gridz)",
    "gridz_define": "0",
    "height_internal": "0",
    "only_corners": "false",
    "scoop": "$($_.scoop)",
    "style_hole": "3",
    "style_lip": "0",
    "style_tab": "$($_.style_tab)",
    "filename": "$(
        [System.IO.Path]::Combine(
            "$($_.divx * $_.divy)",
            "x$($_.gridz)",
            (@(
                if ($_.scoop -eq 0){"noscoop"}
                if ($_.style_tab -eq 5){"notab"}
            ) | Join-String -Separator "-"),
            "$($_.gridx)x$($_.gridy)"
        ).Replace("\","/")
    )"
}
"@ } |
    ConvertFrom-Json -AsHashtable |
    ForEach-Object { $json.Add($_) } |
    Out-Null
Push-Location $PSScriptRoot

Get-Process openscad -ErrorAction SilentlyContinue |
    Stop-Process -Force

if ($Rebuild) {
    @(
        Get-ChildItem -Recurse -Filter *.stl
    ) |
        ForEach-Object {
            Write-Host -ForegroundColor Red "deleting $_"; $_
        } |
        Remove-Item

        0..1 |
            ForEach-Object {
                Get-ChildItem -Recurse -Directory |
                    Where-Object{ (Get-ChildItem $_ | Measure-Object).Count -eq 0} |
                    Remove-Item
            }
}

Get-ChildItem -Recurse -Filter *.stl |
    Where-Object {
        $filename = [System.IO.Path]::GetRelativePath(
                        "$PSScriptRoot",
                        ($_.FullName -replace "\.stl", "")
                    ).Replace("\","/")
        $filename -notin $json.filename } |
    ForEach-Object {
        Write-Host -ForegroundColor Red "deleting $_"; $_
    } |
    Remove-Item -Confirm

# build stl files
Write-Progress -Activity "building stl files" -PercentComplete 1
$done = 0
$overall = ($json | Measure-Object).Count
$json |
    ForEach-Object -Parallel {
        Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum 500)

        $filename = $_.filename
        $arguments = $_.GetEnumerator() |
            Where-Object Name -In @(
                "div_base_x", "div_base_y", "divx", "divy", "enable_zsnap", "gridx", "gridy",
                "gridz", "gridz_define", "height_internal", "only_corners", "scoop", "style_hole",
                "style_lip", "style_tab" ) |
            ForEach-Object { "--D $($_.Name)=$($_.Value)" } |
            Join-String -Separator " "

        if (!(Test-Path "$filename.stl")) {
            $process = Get-Process openscad -ErrorAction SilentlyContinue
            if ($null -ne $process.Name) {
                while ((Get-Process openscad | Measure-Object).Count -ge $using:Processes) {
                    Start-Sleep -Seconds 1
                }
            }

            mkdir ([System.IO.Path]::GetDirectoryName($filename)) -ErrorAction SilentlyContinue | Out-Null

            ". '$using:openscad' '$using:scadFile' $arguments --export-format binstl -o '$filename.stl'" |
                ForEach-Object {
                    # Write-Host -ForegroundColor Cyan $_
                    Write-Host -ForegroundColor Green "building $filename.stl"
                    Invoke-Expression $_
                }
        }

        1
    } |
    ForEach-Object {
        $done += [int]$_
        $percent = 1 + [Math]::Round(99 * $done / $overall, 1)
        Write-Progress -Activity "building stl files" -Status "$done / $overall - $($percent.ToString("0.0")) %" -PercentComplete $percent
    }
    Write-Progress -Activity "building stl files" -Completed


# wait for process to finish
Get-Process openscad -ErrorAction SilentlyContinue |
    ForEach-Object `
        -Begin   { Start-Sleep -Seconds 1 } `
        -Process { $_.WaitForExit() }

# delete empty directories
Get-ChildItem -Directory -Recurse |
    Where-Object { ($_ | Get-ChildItem -Recurse -File | Measure-Object).Count -eq 0 } |
    Remove-Item -Recurse -Force

Pop-Location
