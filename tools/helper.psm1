$MinimalSDKVersion = '6.0.100'
$IsWindowsEnv = [System.Environment]::OSVersion.Platform -eq "Win32NT"
$LocalDotnetDirPath = if ($IsWindowsEnv) { "$env:LocalAppData\Microsoft\dotnet" } else { "$env:HOME/.dotnet" }

<#
.SYNOPSIS
    Find the dotnet SDK that meets the minimal version requirement.
#>
function Find-Dotnet {
    $dotnetFile = if ($IsWindowsEnv) { "dotnet.exe" } else { "dotnet" }
    $dotnetPath = Join-Path -Path $LocalDotnetDirPath -ChildPath $dotnetFile

    # If dotnet is already in the PATH, check to see if that version of dotnet can find the required SDK.
    # This is "typically" the globally installed dotnet.
    $foundDotnetWithRightVersion = $false
    $dotnetInPath = Get-Command 'dotnet' -ErrorAction Ignore
    if ($dotnetInPath) {
        $foundDotnetWithRightVersion = Test-DotnetSDK $dotnetInPath.Source
    }

    if (-not $foundDotnetWithRightVersion) {
        if (Test-DotnetSDK $dotnetPath) {
            Write-Warning "Can't find the dotnet SDK version $MinimalSDKVersion or higher, prepending '$LocalDotnetDirPath' to PATH."
            $env:PATH = $LocalDotnetDirPath + [IO.Path]::PathSeparator + $env:PATH
        }
        else {
            throw "Cannot find the dotnet SDK with the version $MinimalSDKVersion or higher. Please specify '-Bootstrap' to install build dependencies."
        }
    }
}

<#
.SYNOPSIS
    Check if the dotnet SDK meets the minimal version requirement.
#>
function Test-DotnetSDK {
    param($dotnetPath)

    if (Test-Path $dotnetPath) {
        $installedVersion = & $dotnetPath --version
        return $installedVersion -ge $MinimalSDKVersion
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
        [string]$Version = $MinimalSDKVersion
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