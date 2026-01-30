$RepoPath = (Get-Item -Path $PSScriptRoot).Parent.Parent.FullName
$GlobalPath = Join-Path -Path $RepoPath -ChildPath 'global.json'
if (-not (Test-Path -Path $GlobalPath)) {
    throw "Cannot find global.json at expected path: $GlobalPath"
}

try {
    $GlobalJsonContent = Get-Content -Path $GlobalPath -Raw | ConvertFrom-Json
}
catch {
    throw "Failed to parse global.json at path: $GlobalPath. Ensure the file contains valid JSON. Error: $($_.Exception.Message)"
}

$Schema = '{
  "type": "object",
  "properties": {
    "sdk": {
      "type": "object",
      "properties": {
        "version": { "type": "string" }
      },
      "required": ["version"]
    }
  },
  "required": ["sdk"]
}'

if (-not (Test-Json -Path $GlobalPath -Schema $Schema)) {
    throw "global.json does not match the required schema."
}

$RequiredSDKVersion = $GlobalJsonContent.sdk.version
$LocalDotnetDirPath = $IsWindows ? "$env:LocalAppData\Microsoft\dotnet" : "$env:HOME/.dotnet"

<#
.SYNOPSIS
    Find the dotnet SDK that meets the required version requirement.
#>
function Find-Dotnet {
    $dotnetFile = $IsWindows ? "dotnet.exe" : "dotnet"
    $dotnetPath = Join-Path -Path $LocalDotnetDirPath -ChildPath $dotnetFile

    Write-Log "Searching for dotnet SDK version $RequiredSDKVersion ..."

    # If dotnet is already in the PATH, check to see if that version of dotnet can find the required SDK.
    # This is typically the globally installed dotnet.
    $dotnetInPath = Get-Command 'dotnet' -ErrorAction Ignore
    if ($dotnetInPath) {
        Write-Log "Found global dotnet at '$($dotnetInPath.Source)'. Checking version..."

        if (Find-RequiredDotnetSDK $dotnetInPath.Source) {
            Write-Log "Found global dotnet SDK version '$RequiredSDKVersion' in PATH."
            return
        }
    }

    # Check the local dotnet installation next.
    # This is typically where we install the required SDK if it's not found globally.
    Write-Log "Dotnet SDK version '$RequiredSDKVersion' not found in PATH."
    if (Find-RequiredDotnetSDK $dotnetPath) {
        Write-Log "Local dotnet SDK version '$RequiredSDKVersion' found at '$dotnetPath'." -Warning
        Add-LocalDotnetToPath
    }
    else {
        throw "Cannot find global or local dotnet SDK with the version $RequiredSDKVersion."
    }
}

<#
.SYNOPSIS
    Add the local dotnet installation directory to PATH if not already present.
#>
function Add-LocalDotnetToPath {
    $dotnetInPath = $env:PATH.Split([System.IO.Path]::PathSeparator) -contains $LocalDotnetDirPath
    if (-not $dotnetInPath) {
        Write-Log "Prepending '$LocalDotnetDirPath' to PATH." -Warning
        $env:PATH = $LocalDotnetDirPath + [System.IO.Path]::PathSeparator + $env:PATH
    }
}

<#
.SYNOPSIS
    Check if the dotnet SDK meets the required version.
#>
function Find-RequiredDotnetSDK {
    param($dotnetPath)

    if (Test-Path $dotnetPath) {
        $sdkList = & $dotnetPath --list-sdks 2>$null

        foreach ($sdk in $sdkList) {
            $version = $sdk.Split(' ')[0]
            if ($version -eq $RequiredSDKVersion) {
                return $true
            }
        }
    }
    return $false
}

<#
.SYNOPSIS
    Install the dotnet SDK if we cannot find an existing one.
#>
function Install-Dotnet {
    [CmdletBinding()]
    param(
        [string]$Channel = 'release',
        [string]$Version = $RequiredSDKVersion
    )

    try {
        Find-Dotnet
        return  # Simply return if we find dotnet SDK with the correct version
    }
    catch { }

    Write-Log "Installing dotnet SDK version '$Version' to '$LocalDotnetDirPath'." -Warning

    $installScript = $IsWindows ? "dotnet-install.ps1" : "dotnet-install.sh"

    # Recommended from https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-install-script#recommended-version
    $scriptUrl = "https://dot.net/v1/$installScript"

    try {
        Invoke-WebRequest -Uri $scriptUrl -OutFile $installScript

        if ($IsWindows) {
            & .\$installScript -Channel $Channel -Version $Version -InstallDir $LocalDotnetDirPath
        }
        else {
            bash ./$installScript -c $Channel -v $Version --install-dir $LocalDotnetDirPath
        }

        Add-LocalDotnetToPath
    }
    finally {
        Remove-Item $installScript -Force -ErrorAction Ignore
    }
}

<#
.SYNOPSIS
    Write log message for the build.
#>
function Write-Log {
    param(
        [string] $Message,
        [switch] $Warning,
        [switch] $Indent
    )

    $foregroundColor = $Warning ? "Yellow" : "Green"
    $indentPrefix = $Indent ? "    " : ""
    Write-Host -ForegroundColor $foregroundColor "${indentPrefix}${Message}"
}

<#
.SYNOPSIS
    Expands Nupkg package contents by first converting to ZIP then expanding archive.
#>
function Expand-Nupkg {
    param (
        [string] $ModuleManfifestPath,
        [string] $OutputPath
    )

    $moduleManifest = Test-ModuleManifest -Path $ModuleManfifestPath
    $moduleVersion = $moduleManifest.Version
    $preRelease = $moduleManifest.PrivateData.PSData.Prerelease
    $moduleName = (Get-Item -Path $ModuleManfifestPath).BaseName

    $destPath = Join-Path -Path $OutputPath -ChildPath $moduleName -AdditionalChildPath $moduleVersion
    if (-not (Test-Path $destPath)) {
        New-Item -Path $destPath -ItemType Directory | Out-Null
    }

    $archiveBaseName = "$moduleName.$moduleVersion"
    if ($preRelease) {
        $archiveBaseName += "-$preRelease"
    }

    $nupKgFileName = "$archiveBaseName.nupkg"
    $zipFileName = "$archiveBaseName.zip"

    $nupkgPath = Join-Path -Path $OutputPath -ChildPath $nupKgFileName
    if (-not (Test-Path $nupkgPath)) {
        throw "Cannot find nupkg at expected path: $nupkgPath"
    }

    $zipPath = Join-Path -Path $OutputPath -ChildPath $zipFileName

    try {
        Rename-Item -Path $nupkgPath -NewName $zipFileName -Force
        Expand-Archive -Path $zipPath -DestinationPath $destPath -Force
    }
    finally {
        if (Test-Path $zipPath) {
            Rename-Item -Path $zipPath -NewName $nupKgFileName -Force
        }
    }
}

<#
.SYNOPSIS
    Helper to run a git command and check for errors
#>
function Invoke-Git {
    param(
        [string]$Command
    )
    Write-Log ">> [GIT] ${Command}"
    $gitArgs = $Command -split ' '
    & git @gitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed with exit code ${LASTEXITCODE}: git ${Command}"
    }
}

<#
.SYNOPSIS
    Convert Windows path to MSYS2 path
#>
function Convert-ToMsysPath {
    param([string]$winPath)

    $msysPath = $winPath -replace '\\', '/'
    if ($msysPath -match '^([A-Za-z]):') {
        $drive = $matches[1].ToLower()
        $rest = $msysPath.Substring(2)
        return "/${drive}${rest}"
    }
    return $msysPath
}

<#
.SYNOPSIS
    Helper to run a command in MinGW64 environment
#>
function Invoke-Mingw64 {
    param(
        [string]$Command,
        [switch]$IgnoreError
    )

    Write-Log ">> [MINGW64] ${Command}"

    $env:MSYSTEM = "MINGW64"
    $env:CHERE_INVOKING = "1"

    & "C:\msys64\usr\bin\bash.exe" --login -c "$Command" 2>&1

    if (-not $IgnoreError -and $LASTEXITCODE -ne 0) {
        throw "MINGW64 command failed with exit code ${LASTEXITCODE}: ${Command}"
    }
}

<#
.SYNOPSIS
    Helper to run a winget command and check for errors
#>
function Invoke-Winget {
    param(
        [string]$Command
    )

    Write-Log ">> [WINGET] ${Command}"
    $wingetArgs = $Command -split ' '
    & winget @wingetArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Winget command failed with exit code ${LASTEXITCODE}: winget ${Command}"
    }
}

<#
.SYNOPSIS
    Helper to run a dotnet command and check for errors
#>
function Invoke-Dotnet {
    param(
        [string]$Command
    )

    Write-Log ">> [DOTNET] ${Command}"
    $dotnetArgs = $Command -split ' '
    & dotnet @dotnetArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Dotnet command failed with exit code ${LASTEXITCODE}: dotnet ${Command}"
    }
}

<#
.SYNOPSIS
    Helper to run a docker command and check for errors
#>
function Invoke-Docker {
    param(
        [string]$Command,
        [switch]$SuppressOutput,
        [switch]$IgnoreError
    )

    Write-Log ">> [DOCKER] ${Command}"
    $dockerArgs = $Command -split ' '
    if ($SuppressOutput) {
        & docker @dockerArgs 2>$null | Out-Null
    }
    else {
        & docker @dockerArgs
    }

    if (-not $IgnoreError -and $LASTEXITCODE -ne 0) {
        throw "Docker command failed with exit code ${LASTEXITCODE}: docker ${Command}"
    }
}

<#
.SYNOPSIS
    Remove unnecessary files from target directory.
#>
function Remove-NonEssentialFiles {
    param(
        [string]$TargetDir,
        [string[]]$KeepFilePatterns,
        [string[]]$KeepDirs
    )

    Write-Log "Stripping non-essential files..."
    $files = Get-ChildItem -Path $TargetDir -Recurse -File
    if (-not $files -or $files.Count -eq 0) {
        throw "No files found in $TargetDir - download or extraction may have failed"
    }
    $beforeSize = ($files | Measure-Object -Property Length -Sum).Sum / 1MB

    Write-Log "Initial File Count: $($files.Count), Size: $([math]::Round($beforeSize, 2)) MB"

    $removedCount = 0

    Write-Log "Keeping files matching patterns: $($KeepFilePatterns -join ', ')"

    # Remove root directory files except essential ones
    $rootFiles = Get-ChildItem -Path $TargetDir -File
    foreach ($file in $rootFiles) {
        $keep = $false
        foreach ($pattern in $KeepFilePatterns) {
            if ($file.Name -like $pattern) {
                $keep = $true
                break
            }
        }
        if (-not $keep) {
            Remove-Item $file.FullName -Force -ErrorAction SilentlyContinue
            $removedCount++
        }
    }

    Write-Log "Keeping directories: $($KeepDirs -join ', ')"

    # Remove directories not in keep list
    $allDirs = Get-ChildItem -Path $TargetDir -Directory
    foreach ($dir in $allDirs) {
        if ($dir.Name -notin $KeepDirs) {
            $removedCount += (Get-ChildItem $dir.FullName -Recurse -File).Count
            Remove-Item $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $filesAfter = Get-ChildItem -Path $TargetDir -Recurse -File
    if (-not $filesAfter -or $filesAfter.Count -eq 0) {
        throw "All files were removed from $TargetDir - file removal logic may be incorrect"
    }
    $afterSize = ($filesAfter | Measure-Object -Property Length -Sum).Sum / 1MB
    $saved = $beforeSize - $afterSize

    Write-Log "Removed $removedCount files (saved $([math]::Round($saved, 2)) MB)"

    $fileCount = (Get-ChildItem $TargetDir -Recurse -File).Count
    Write-Log "`nDownload completed successfully!"
    Write-Log "Kept $fileCount essential files ($([math]::Round($afterSize, 2)) MB) in: $TargetDir"
}

function Start-MinGwBootstrap {
    param(
        [switch]$UpdatePackages
    )
    Write-Log "Checking for MSYS2 installation..."

    $msys2Root = "C:\msys64"
    $envExe = Join-Path $msys2Root "usr\bin\env.exe"

    if (-not (Test-Path $envExe)) {
        Write-Log "MSYS2 not found at $msys2Root. Installing via winget..."
        Invoke-Winget "install -e --id MSYS2.MSYS2"
    }

    if (-not (Test-Path $envExe)) {
        throw "MSYS2 installation not found at $envExe even after install attempt."
    }

    if ($UpdatePackages) {
        Write-Log "Updating MSYS2 packages..."
        Invoke-Mingw64 "pacman -Syu --noconfirm --needed"
    }

    $packages = @(
        'mingw-w64-x86_64-pkgconf'
        'mingw-w64-x86_64-gcc'
        'mingw-w64-x86_64-cmake'
        'mingw-w64-x86_64-ninja'
        'make'
        'unzip'
    )

    $pkgList = $packages -join " "

    Write-Log "Ensuring MSYS2 MinGW64 packages are installed..."
    Invoke-Mingw64 "pacman --needed --noconfirm -S $pkgList"
}
