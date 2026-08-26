$ErrorActionPreference = "Stop"

$project = Join-Path $PSScriptRoot "DisplaySwitcher.Windows\DisplaySwitcher.Windows.csproj"
$output = Join-Path $PSScriptRoot "dist"

dotnet publish $project `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=None `
    --output $output

Write-Host "构建完成：$output\DisplaySwitcher.Windows.exe"
