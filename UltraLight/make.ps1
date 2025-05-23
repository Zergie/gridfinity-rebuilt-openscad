[cmdletbinding()]
param(
    [Parameter(ParameterSetName="BuildParameterSet")]
    [switch]
    $BuildStls,

    [Parameter(ParameterSetName="BuildParameterSet")]
    [switch]
    $BuildMarkdown,
    
    [Parameter(ParameterSetName="BuildParameterSet")]
    [switch]
    $BuildImages,

    [Parameter(ParameterSetName="BuildParameterSet")]
    [switch]
    $Force,

    [Parameter(ParameterSetName="BuildParameterSet")]
    [int]
    $Processes = 10
)
$ErrorActionPreference = 'Break'
$Debug = $PSBoundParameters.Debug
if (!$BuildStls -and !$BuildMarkdown -and !$BuildImages) {
    $BuildStls = $true
    $BuildMarkdown = $true
    $BuildImages = $true
}
Write-Host -ForegroundColor Magenta $PSScriptRoot
$openscad      = . $PSScriptRoot\..\Get-OpenScad.ps1
$scadFile      = (Resolve-Path "$PSScriptRoot\..\UltraLightGridfinityBins.scad").Path
$parameterFile = (Resolve-Path "$PSScriptRoot\config.json").Path
$basedir       = [System.IO.Path]::GetDirectoryName($PSScriptRoot)
$tempdir       =  (New-Item -ItemType Directory -Path "$env:TEMP\$([System.IO.Path]::GetRandomFileName())" ).FullName

$json = [System.Collections.ArrayList]::new()
ForEach-Object {@(
@"
{
    "Grids_X": [1,2,3,4,5,6],
    "Grids_Y": 1,
    "Grids_Z": [3,6],
    "Scoops": ["true", "false"],
    "Dividers_Y": 0,
}
"@ 
@"
{
    "Grids_X": 2,
    "Grids_Y": 1,
    "Grids_Z": [3,6],
    "Scoops": "true",
    "Dividers": "true",
    "Dividers_X": [1,2,3],
}
"@
)} |
    ConvertFrom-Json -AsHashtable |
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
                $item.OpenScad = [PSCustomObject]@{
                    Path      = $openscad
                    File      = $scadFile
                    Arguments = $item.GetEnumerator() |
                        ForEach-Object `
                            -Process { "-D '$($_.Name)=$($_.Value)'" } `
                            -End {
                                "-p '$($parameterFile)'"
                                "-P 'make.ps1'"
                            } |
                        Join-String -Separator " "
                }
                
                $item.filename = @(
                        $item.Grids_X
                        "x"
                        $item.Grids_Y
                        "x"
                        $item.Grids_Z
                        if ($item.Dividers_X -gt 0){ "x$($item.Dividers_X + 1)" }
                        if ($item.Scoops -eq $false){"_noscoop"}
                        if ($item.Labels -eq $false){"_notab"}
                    ) | Join-String -Separator ""
                $item.Paths = [PSCustomObject]@{
                    Stl = [System.IO.Path]::GetFullPath(
                        [System.IO.Path]::Combine($PSScriptRoot, "STLS", $item.filename + ".stl")
                    )
                    Image = [System.IO.Path]::GetFullPath(
                        [System.IO.Path]::Combine($PSScriptRoot, "Images", $item.filename + ".png")
                    )
                    Temp = $tempdir
                }

                $item | ConvertTo-Json | Write-Debug
                $json.Add($item) | Out-Null
            }
        }
    }
 
function Clear-Directory {
    param ( 
        # Specifies a path to one or more locations.
        [Parameter(Position=0)]
        [string]
        $Path = $PSScriptRoot,

        [string] $Filter 
    )

    if ($Force) {
        # remove ALL files
        @(
            Get-ChildItem $Path -Recurse -Filter $Filter
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
    } else {
        # remove files not listed in the JSON configuration
        Get-ChildItem $Path -Recurse -Filter $Filter |
            Where-Object {
                $filename = [System.IO.Path]::GetFileNameWithoutExtension($_.FullName)
                $filename -notin $json.filename } |
            ForEach-Object {
                Write-Host -ForegroundColor Red "deleting .$($_.FullName.SubString($basedir.Length).Replace("\","/"))"; $_
            } |
            Remove-Item -Confirm
    }
}

function Get-Configurations {
    param(
        [string] $Activity = "test",
        [switch] $Delay
    )
    Write-Progress -Activity $Activity -PercentComplete 1
    $done = 0
    $overall = ($json | Measure-Object).Count
    foreach ($item in $json) {
        if ($Delay) {
            Start-Sleep -Milliseconds (Get-Random -Minimum 100 -Maximum 500)
        }

        $done += 1.0
        $percent = 1 + [Math]::Round(99 * $done / $overall, 1)
        $p = @{
            Activity = $Activity
            Status   = "$done / $overall - $($percent.ToString("0.0")) %"
            PercentComplete = [Math]::Floor($percent)
        }
        Write-Progress @p

        $item
    }
    Write-Progress -Activity $Activity -Completed
}

if ($BuildStls) {
    Push-Location $PSScriptRoot/STLs

    Get-Process openscad -ErrorAction SilentlyContinue |
        Stop-Process -Force

    Clear-Directory . -Filter *.stl

    Get-Configurations -Activity "building stl files" -Delay |
        ForEach-Object -Parallel {
            $filename = $_.filename
            $openscad = $_.OpenScad

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

                ". '$($openscad.Path)' '$($openscad.File)' $($openscad.Arguments) --export-format binstl -o '$filename.stl'" |
                    ForEach-Object {
                        if ($using:Debug) {
                            Write-Host -ForegroundColor Yellow $_
                        }
                        Write-Host -ForegroundColor Green "building $filename.stl"
                        Invoke-Expression $_
                    }
            }
        } 

    Get-Process openscad -ErrorAction SilentlyContinue |
        ForEach-Object `
            -Begin   { Start-Sleep -Seconds 1 } `
            -Process { $_.WaitForExit() }

    # delete empty directories
    Get-ChildItem -Directory -Recurse |
        Where-Object { ($_ | Get-ChildItem -Recurse -File | Measure-Object).Count -eq 0 } |
        Remove-Item -Recurse -Force

    Pop-Location
}

if ($BuildImages) {
    Push-Location $PSScriptRoot/Images

    Get-Process openscad -ErrorAction SilentlyContinue |
        Stop-Process -Force

    Clear-Directory . -Filter *.png

    Get-Configurations -Activity "building image files" -Delay |
        ForEach-Object -Parallel {
            $stl      = $_.Paths.Stl.Replace("\", "/")
            $filename = $_.filename
            $openscad = $_.OpenScad
            $scadFile = $_.Paths.Temp + "\" + [System.IO.Path]::ChangeExtension([System.IO.Path]::GetRandomFileName(), ".scad")
            
            if (!(Test-Path "$filename.png")) {
                $process = Get-Process openscad -ErrorAction SilentlyContinue
                if ($null -ne $process.Name) {
                    while ((Get-Process openscad | Measure-Object).Count -ge $using:Processes) {
                        Start-Sleep -Seconds 1
                    }
                }

                @(
                    # '$vpt = [0, 0, 0];'
                    # '$vpd = 500;'
                    # '$vpr = [35, 0, 350];'
                    'color("DarkCyan")'
                    "import(`"$stl`");"
                ) |
                    Set-Content $scadFile

                ". '$($openscad.Path)' '$scadFile' --imgsize=300,200 --projection ortho --colorscheme Tomorrow -o '$filename.png'" |
                    ForEach-Object {
                        if ($using:Debug) {
                            Write-Host -ForegroundColor Yellow $_
                        }
                        Write-Host -ForegroundColor Green "building $filename.png"
                        Invoke-Expression $_
                    }
            }
        } 

    Get-Process openscad -ErrorAction SilentlyContinue |
        ForEach-Object `
            -Begin   { Start-Sleep -Seconds 1 } `
            -Process { $_.WaitForExit() }

    Remove-Item -Recurse -Force $tempdir
    Pop-Location
}

if ($BuildMarkdown) {
@"
# Gridfinity UltraLight STL Files

$(
    $data = Get-Configurations -Activity "building index.md" | 
        ForEach-Object {
            [ordered]@{
                Size = $_.Grids_X
                Bins = $_.Dividers_X + 1
                Scoop = $(if ($_.Scoops) {"✅"} else {""})
                Print = "[Print](orcaslicer://open?file=$($_.filename).stl)"
            }
        }    
    
    # header
    $data | 
        Select-Object -First 1 |
        ForEach-Object {
            $col = 0
            $header = $_.GetEnumerator() | 
                ForEach-Object { " $($_.Name) " } |
                ForEach-Object {
                    $r = $_
                    switch($col) {
                        3       { $r.PadRight(47)  }
                        default { $r } 
                    }
                    $col++
                }
            
            "|$($header -join "|")|"
            "|$(($header | ForEach-Object {''.PadLeft($_.Length, '-')}) -join '|' )|"
        }    
    
    #rows
    $data |
        ForEach-Object {
            $col = 0
            $row = $_.GetEnumerator() | 
                    ForEach-Object { " $($_.Value) " } |
                    ForEach-Object {
                        $r = $_
                        switch($col) {
                            2       { $r.PadLeft($header[$col].Length - 1) } 
                            3       { $r.PadRight($header[$col].Length)  }
                            default { $r.PadLeft($header[$col].Length) } 
                        }
                        $col++
                    }

            "|$($row -join "|")|"
        } |
        Join-String -Separator "`n"
)
"@ |
    Set-Content -Path "$PSScriptRoot/index.md"
    Get-Content -Path "$PSScriptRoot/index.md"
}
