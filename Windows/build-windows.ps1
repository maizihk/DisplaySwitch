$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$project = Join-Path $PSScriptRoot "DisplaySwitcher.Windows\DisplaySwitcher.Windows.csproj"
$output = Join-Path $PSScriptRoot "dist"

Push-Location $root
try {
    $sdkVersion = & dotnet --version
    if ($LASTEXITCODE -ne 0 -or -not $sdkVersion.StartsWith("8.")) {
        throw "需要 .NET 8 SDK，当前版本：$sdkVersion"
    }

    if (Test-Path -LiteralPath $output) {
        Remove-Item -LiteralPath $output -Recurse -Force
    }

    & dotnet publish $project `
        --configuration Release `
        --runtime win-x64 `
        --self-contained true `
        -p:Platform=x64 `
        -p:WindowsAppSDKSelfContained=true `
        -p:PublishSingleFile=false `
        -p:DebugType=None `
        --output $output

    if ($LASTEXITCODE -ne 0) {
        throw "Windows 发布失败，dotnet publish 退出码：$LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

Write-Host "构建完成：$output"
Write-Host "请保留并复制 dist 目录中的全部文件。"
