# PowerShellBuildTools

Build automation tools for PowerShell module development. It is designed to simplify common tasks such as building, testing, and generating documentation for PowerShell modules.

## Setup

Add repository as a submodule to your PowerShell module project:

```powershell
git submodule add https://github.com/ArmaanMcleod/PowerShellBuildTools.git
```

## Usage

```powershell
# Build module (default)
.\build.ps1

# Run tests
.\build.ps1 -Task Test

# Run tests against packaged module
.\build.ps1 -Task TestPackage

# Run tests with tag filter
.\build.ps1 -Task Test -PesterTagFilter @('Unit','Integration')

# Build with custom environment variables
.\build.ps1 -EnvironmentVariables @{ 'MY_ENV_VAR' = 'SomeValue'; 'ANOTHER_VAR' = 'AnotherValue' }

# Generate documentation
.\build.ps1 -Task Docs

# Build in Release mode
.\build.ps1 -Configuration Release
```

## What Happens

When you run `build.ps1`, it automatically:

1. Checks for .NET SDK version in `global.json`. If not found, it downloads and installs the specified .NET SDK version.
2. Installs required PowerShell modules from `requirements-dev.psd1`.
3. Runs the selected task using InvokeBuild.

**Available tasks:**

- `Build` - Cleans, compiles, generates help, and packages the module.
- `Test` - Compiles and runs Pester tests.
- `TestPackage` - Runs tests against the packaged module.
- `Docs` - Compiles and updates Markdown documentation.
