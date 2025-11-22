# PowerShellBuildTools

Build automation tools for PowerShell module development.

## Usage

```powershell
# Build module (default)
.\build.ps1

# Run tests
.\build.ps1 -Task Test

# Generate documentation
.\build.ps1 -Task Docs

# Build in Release mode
.\build.ps1 -Configuration Release
```

## What Happens

When you run `build.ps1`, it automatically:

1. Checks for .NET SDK 6.0.100+ (installs to AppData if missing)
2. Installs required PowerShell modules (InvokeBuild, Pester, platyPS)
3. Runs the selected task using InvokeBuild

**Available tasks:**

- `Build` - Cleans, compiles, generates help, and packages the module
- `Test` - Compiles and runs Pester tests
- `Docs` - Compiles and updates Markdown documentation
