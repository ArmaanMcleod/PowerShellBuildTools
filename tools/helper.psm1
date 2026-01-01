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
$IsWindowsEnv = [System.Environment]::OSVersion.Platform -eq "Win32NT"
$LocalDotnetDirPath = if ($IsWindowsEnv) { "$env:LocalAppData\Microsoft\dotnet" } else { "$env:HOME/.dotnet" }

<#
.SYNOPSIS
    Find the dotnet SDK that meets the required version requirement.
#>
function Find-Dotnet {
    $dotnetFile = if ($IsWindowsEnv) { "dotnet.exe" } else { "dotnet" }
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

    $installScript = if ($IsWindowsEnv) { "dotnet-install.ps1" } else { "dotnet-install.sh" }

    # Recommended from https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-install-script#recommended-version
    $scriptUrl = "https://dot.net/v1/$installScript"

    try {
        Invoke-WebRequest -Uri $scriptUrl -OutFile $installScript

        if ($IsWindowsEnv) {
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

    $foregroundColor = if ($Warning) { "Yellow" } else { "Green" }
    $indentPrefix = if ($Indent) { "    " } else { "" }
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
    $moduleName = (Get-Item -Path $ModuleManfifestPath).BaseName

    $destPath = Join-Path -Path $OutputPath -ChildPath $moduleName -AdditionalChildPath $moduleVersion
    if (-not(Test-Path -LiteralPath $destPath)) {
        New-Item -Path $destPath -ItemType Directory | Out-Null
    }

    $nupkgPath = Join-Path -Path $OutputPath -ChildPath "$moduleName.$moduleVersion.nupkg"
    Rename-Item -Path $nupkgPath -NewName "$moduleName.$moduleVersion.zip"
    $zipPath = Join-Path -Path $OutputPath -ChildPath "$moduleName.$moduleVersion.zip"

    Expand-Archive -Path $zipPath -DestinationPath $destPath -Force
}

<#
.SYNOPSIS
    Helper to run a git command and check for errors
#>
function Invoke-Git {
    param(
        [string]$Command
    )
    Write-Host ">> [GIT] ${Command}"
    $gitArgs = $Command -split ' '
    & git @gitArgs
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
        $rest  = $msysPath.Substring(2)
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

    Write-Host ">> [MINGW64] ${Command}"

    $env:MSYSTEM = "MINGW64"
    $env:CHERE_INVOKING = "1"

    & "C:\msys64\usr\bin\bash.exe" --login -c "$Command"

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

    Write-Host ">> [WINGET] ${Command}"
    $wingetArgs = $Command -split ' '
    & winget @wingetArgs

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

    Write-Host ">> [DOTNET] ${Command}"
    $dotnetArgs = $Command -split ' '
    & dotnet @dotnetArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Dotnet command failed with exit code ${LASTEXITCODE}: dotnet ${Command}"
    }
}
