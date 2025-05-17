[cmdletbinding()]
param(
    [Parameter(ParameterSetName="BuildParameterSet")]
    [switch]
    $Rebuild,

    [Parameter(ParameterSetName="BuildParameterSet")]
    [int]
    $Processes = 10
)
$ErrorActionPreference = 'Break'
$Debug = $PSBoundParameters.Debug

$openscad = . $PSScriptRoot\..\Get-OpenScad.ps1
$scadFile = (Resolve-Path "$PSScriptRoot\..\UltraLightGridfinityBins.scad").Path
$parameterFile = (Resolve-Path "$PSScriptRoot\..\UltraLightGridfinityBins.json").Path

$json = [System.Collections.ArrayList]::new()
ForEach-Object {
@"
{
    "Grids_X": $(1..6 | ConvertTo-Json),
    "Grids_Y": "1",
    "Grids_Z": [3,6],
    "Scoops": ["true", "false"],
}
"@ } |
    ConvertFrom-Json -AsHashtable -OutVariable template |
    ForEach-Object {
        $stack = [System.Collections.Stack]::new()
        $stack.Push($_)

        while ($stack.Count -gt 0) {
            $item = $stack.Pop()
            $yieldItem = $true

            foreach ($key in $_.Keys) {
                $value = $item.$key
                if ($value.GetType().FullName -eq "System.Object[]") {
                    $yieldItem = $false
                    foreach ($configuration in $value) {
                        $new_item = $item | ConvertTo-Json | ConvertFrom-Json -AsHashtable
                        $new_item.$key = $configuration
                        $stack.Push($new_item)
                    }
                    break
                }
            }

            if ($yieldItem) {
                $item.filename = @(
                        $item.Grids_X
                        "x"
                        $item.Grids_Y
                        "x"
                        $item.Grids_Z
                        if ($item.Scoops -eq $false){"_noscoop"}
                        if ($item.Labels -eq $false){"_notab"}
                    ) | Join-String -Separator ""
                $item.filename = "STLs/$($item.filename)"
                $json.Add($item) | Out-Null
            }
        }
    } 
Push-Location $PSScriptRoot

Get-Process openscad -ErrorAction SilentlyContinue |
    Stop-Process -Force

$basedir = [System.IO.Path]::GetDirectoryName($PSScriptRoot)
if ($Rebuild) {
    @(
        Get-ChildItem -Recurse -Filter *.stl
    ) |
        ForEach-Object {
            Write-Host -ForegroundColor Red "deleting .$($_.FullName.SubString($basedir.Length).Replace("\","/"))"; $_
        } |
        Remove-Item

        0..1 |
            ForEach-Object {
                Get-ChildItem -Recurse -Directory |
                    Where-Object{ (Get-ChildItem $_ | Measure-Object).Count -eq 0} |
                    Remove-Item
            }
}

# remove STL files not listed in the JSON configuration
Get-ChildItem -Recurse -Filter *.stl |
    Where-Object {
        $filename = [System.IO.Path]::GetRelativePath(
                        "$PSScriptRoot",
                        ($_.FullName -replace "\.stl", "")
                    ).Replace("\","/")
        $filename -notin $json.filename } |
    ForEach-Object {
        Write-Host -ForegroundColor Red "deleting .$($_.FullName.SubString($basedir.Length).Replace("\","/"))"; $_
    } |
    Remove-Item -Confirm

# build stl files
Write-Progress -Activity "building stl files" -PercentComplete 1
$done = 0
$overall = ($json | Measure-Object).Count
$json |
    ForEach-Object -Parallel {
        Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum 500)

        $openscad      = $using:openscad
        $template      = $using:template
        $parameterFile = $using:parameterFile
        $Debug         = $using:Debug

        $filename = $_.filename
        $arguments = $_.GetEnumerator() |
            Where-Object Name -In $template.Keys |
            ForEach-Object { "-D '$($_.Name)=$($_.Value)'" } |
            Join-String -Separator " "
        $arguments += "-p '$($parameterFile)'"
        $arguments += "-P 'make.ps1'"

        if (!(Test-Path "$filename.stl")) {
            $process = Get-Process openscad -ErrorAction SilentlyContinue
            if ($null -ne $process.Name) {
                while ((Get-Process openscad | Measure-Object).Count -ge $using:Processes) {
                    Start-Sleep -Seconds 1
                }
            }

            $directory = [System.IO.Path]::GetDirectoryName($filename)
            if ($directory.Length -gt 0) {
                mkdir $directory -ErrorAction SilentlyContinue | Out-Null
            }

            ". '$openscad' '$using:scadFile' $arguments --export-format binstl -o '$filename.stl'" |
                ForEach-Object {
                    if ($Debug) {
                        Write-Host -ForegroundColor Yellow $_
                    }
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
