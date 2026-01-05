[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Debug', 'Release')]
    [string]
    $Configuration = 'Debug',

    [Parameter(Mandatory = $false)]
    [string[]]
    $PesterTagFilter
)

$RepoPath = Split-Path -Path $PSScriptRoot -Parent
$RepoName = (Get-Item -Path $RepoPath).BaseName
$BuildPath = Join-Path -Path $RepoPath -ChildPath 'out'
$SourcePath = Join-Path -Path $RepoPath -ChildPath 'src'
$ModuleManifiestPath = Join-Path -Path $SourcePath -ChildPath "$RepoName.psd1"
$ModuleManifest = Test-ModuleManifest -Path $ModuleManifiestPath
$ModuleVersion = $ModuleManifest.Version
$ModulePrerelease = $ModuleManifest.PrivateData.PSData.Prerelease
$ModuleName = (Get-Item -Path $ModuleManifiestPath).BaseName
$ModulePath = Join-Path -Path $BuildPath -ChildPath $ModuleName
$ReleasePath = Join-Path -Path $ModulePath -ChildPath $ModuleVersion
$DocsLocale = 'en-US'
$DocsPath = Join-Path -Path $RepoPath -ChildPath 'docs' -AdditionalChildPath $DocsLocale

task Clean {
    try {
        Push-Location -Path $SourcePath

        if (Test-Path -Path $ReleasePath -PathType Container) {
            Write-Log "Deleting $ReleasePath" -Warning
            Remove-Item -Path $ReleasePath -Recurse -Force
        }

        Invoke-Dotnet "clean"
    }
    finally {
        Pop-Location
    }
}

task Publish {
    try {
        Push-Location -Path $SourcePath
        Write-Log "Publishing $Configuration configuration to $ReleasePath"
        Invoke-Dotnet "publish --output ${ReleasePath} --configuration ${Configuration}"
    }
    finally {
        Pop-Location
    }
}

task Restore {
    try {
        Push-Location -Path $SourcePath
        Write-Log "Restoring NuGet packages"
        Invoke-Dotnet "restore"
    }
    finally {
        Pop-Location
    }
}

task ExternalHelp {
    if (Test-Path -Path $DocsPath) {
        $outputPath = Join-Path -Path $ReleasePath -ChildPath $DocsLocale
        $mdfiles = Measure-PlatyPSMarkdown -Path "$DocsPath/*.md"
        $mdfiles | Where-Object Filetype -match 'CommandHelp' |
        Import-MarkdownCommandHelp -Path { $_.FilePath } |
        Export-MamlCommandHelp -OutputFolder $outputPath -Force

        # Microsoft.PowerShell.PlatyPS creates a subfolder with the module name; move XML files up one level
        # https://github.com/PowerShell/platyPS/issues/835
        $mamlSubfolder = Join-Path -Path $outputPath -ChildPath $ModuleName
        if (Test-Path $mamlSubfolder) {
            Get-ChildItem -Path $mamlSubfolder -Filter '*.xml' | ForEach-Object {
                Move-Item -Path $_.FullName -Destination $outputPath -Force
            }
            Remove-Item -Path $mamlSubfolder -Recurse -Force
            Write-Log "Flattened XML files from $mamlSubfolder to $outputPath"
        }
    }
}

task Package {
    $nupkgBaseName = "$ModuleName.$ModuleVersion"
    if ($ModulePrerelease) {
        $nupkgBaseName += "-$ModulePrerelease"
    }

    $nupkgPath = Join-Path -Path $BuildPath -ChildPath "$nupkgBaseName.nupkg"
    if (Test-Path -Path $nupkgPath) {
        Remove-Item -Path $nupkgPath -Force
    }

    $repoParams = @{
        Name               = 'LocalRepo'
        SourceLocation     = $BuildPath
        PublishLocation    = $BuildPath
        InstallationPolicy = 'Trusted'
    }

    if (Get-PSRepository -Name $repoParams.Name -ErrorAction SilentlyContinue) {
        Unregister-PSRepository -Name $repoParams.Name
    }

    Register-PSRepository @repoParams

    try {
        Publish-Module -Path $ReleasePath -Repository $repoParams.Name
    }
    finally {
        Unregister-PSRepository -Name $repoParams.Name
    }
}

task BuildTestProjects {
    $testPath = Join-Path -Path $RepoPath -ChildPath 'test'
    $testProjects = Get-ChildItem -Path $testPath -Filter '*.csproj' -Recurse
    foreach ($proj in $testProjects) {
        $buildOutput = Invoke-Dotnet "build $($proj.FullName) --configuration ${Configuration}"
        $dllPathMatch = $buildOutput | Select-String -Pattern '-> (.+\.dll)'
        $dllPath = $dllPathMatch.Matches[0].Groups[1].Value.Trim()
        Add-Type -Path $dllPath
    }
}

task RunPesterTests {
    $testScriptPaths = Join-Path -Path $RepoPath -ChildPath 'test' -AdditionalChildPath '*.Tests.ps1'

    $testResultsPath = Join-Path -Path $BuildPath -ChildPath 'TestResults'
    if (-not(Test-Path -Path $testResultsPath)) {
        New-Item -Path $testResultsPath -ItemType Directory
    }

    $testResultsFile = Join-Path -Path $testResultsPath -ChildPath 'Pester.xml'
    if (Test-Path -Path $testResultsFile) {
        Remove-Item -Path $testResultsFile -Force
    }

    $configuration = [PesterConfiguration]::Default
    $configuration.Output.Verbosity = 'Detailed'
    $configuration.Run.Exit = $true
    $configuration.Run.Path = $testScriptPaths
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = $testResultsFile
    $configuration.TestResult.OutputFormat = 'NUnitXml'

    if ($PesterTagFilter) {
        Write-Log "Applying Pester tag filter: $PesterTagFilter"
        $configuration.Filter.Tag = $PesterTagFilter
    }
    else {
        Write-Log "No Pester tag filter applied; running all tests"
    }

    Invoke-Pester -Configuration $configuration
}

task MarkdownHelp {
    Import-Module $ModulePath -Force

    New-Item -Path $DocsPath -ItemType Directory -Force | Out-Null
    $commands = Get-Command -Module $ModuleName | Where-Object { $_.CommandType -in 'Cmdlet', 'Function' }

    foreach ($command in $commands) {
        $docFile = Join-Path -Path $DocsPath -ChildPath "$($command.Name).md"
        if (-not (Test-Path -Path $docFile)) {
            Write-Log "Creating new markdown help for $($command.Name)"

            # Workaround for PlatyPS not respecting culture during help generation when using -Locale 'en-US'
            # https://github.com/PowerShell/platyPS/issues/763
            try {
                $originalCulture = [System.Globalization.CultureInfo]::CurrentCulture
                [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($DocsLocale)
                New-MarkdownCommandHelp -Command $command -OutputFolder $DocsPath -Force | Out-Null
            }
            finally {
                [System.Globalization.CultureInfo]::CurrentCulture = $originalCulture
            }
        }
        else {
            Write-Log "Updating markdown help for $($command.Name)"
            Update-MarkdownCommandHelp -Path $docFile -NoBackup | Out-Null
        }
    }

    # Microsoft.PowerShell.PlatyPS creates a subfolder with the module name; move .md files up one level
    # https://github.com/PowerShell/platyPS/issues/835
    $moduleDocsPath = Join-Path -Path $DocsPath -ChildPath $ModuleName
    if (Test-Path $moduleDocsPath) {
        Get-ChildItem -Path $moduleDocsPath -Filter '*.md' | ForEach-Object {
            Move-Item -Path $_.FullName -Destination $DocsPath -Force
        }
        Remove-Item -Path $moduleDocsPath -Recurse -Force
        Write-Log "Flattened $moduleDocsPath into $DocsPath"
    }
}

task Build -Jobs Restore, Clean, Publish, ExternalHelp, Package

task Test -Jobs Publish, BuildTestProjects, RunPesterTests

task TestPackage -Jobs BuildTestProjects, RunPesterTests

task Docs -Jobs Publish, MarkdownHelp

task . Build
