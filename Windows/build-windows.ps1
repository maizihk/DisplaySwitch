$ErrorActionPreference = "Stop"

$project = Join-Path $PSScriptRoot "DisplaySwitcher.Native\DisplaySwitcher.Native.vcxproj"
$buildOutput = Join-Path $PSScriptRoot "DisplaySwitcher.Native\bin\x64\Release"
$dist = Join-Path $PSScriptRoot "dist"

function Find-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $installation = & $vswhere -latest -prerelease -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if ($LASTEXITCODE -eq 0 -and $installation) {
            $candidate = Join-Path ($installation | Select-Object -First 1) "MSBuild\Current\Bin\amd64\MSBuild.exe"
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    $roots = @(
        (Join-Path $env:ProgramFiles "Microsoft Visual Studio"),
        (Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio")
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $candidate = Get-ChildItem -LiteralPath $root -Filter MSBuild.exe -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*\MSBuild\Current\Bin\amd64\MSBuild.exe" } |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($candidate) { return $candidate.FullName }
    }
    throw "找不到 64 位 MSBuild。请安装 Visual Studio 的 C++ 桌面开发和 Windows App SDK C++ 组件。"
}

function Invoke-CleanEnvironmentProcess([string]$fileName, [string[]]$arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $fileName
    $startInfo.UseShellExecute = $false
    # 某些终端会同时注入 Path/PATH；MSBuild 的工具任务要求环境变量名不重复。
    $environment = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()) {
        if (-not $environment.ContainsKey([string]$entry.Key)) {
            $environment[[string]$entry.Key] = [string]$entry.Value
        }
    }
    $startInfo.Environment.Clear()
    foreach ($entry in $environment.GetEnumerator()) { $startInfo.Environment[$entry.Key] = $entry.Value }
    foreach ($argument in $arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "Windows 构建失败，MSBuild 退出码：$($process.ExitCode)" }
}

$msbuild = Find-MSBuild
Invoke-CleanEnvironmentProcess $msbuild @(
    $project, "/restore", "/m", "/t:Rebuild", "/p:Configuration=Release", "/p:Platform=x64", "/v:minimal"
)

$distPath = [IO.Path]::GetFullPath($dist)
$windowsPath = [IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar
if (-not $distPath.StartsWith($windowsPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝清理 Windows 目录以外的输出路径：$distPath"
}
if (Test-Path -LiteralPath $distPath) { Remove-Item -LiteralPath $distPath -Recurse -Force }
New-Item -ItemType Directory -Path $distPath | Out-Null
$releaseFiles = @(
    "DisplaySwitcher.Windows.exe",
    "DisplaySwitcher.Windows.pri",
    "DisplaySwitcher.Native.winmd",
    "Microsoft.WindowsAppRuntime.Bootstrap.dll",
    "App.xbf",
    "SettingsWindow.xbf"
)
foreach ($name in $releaseFiles) {
    $source = Join-Path $buildOutput $name
    if (-not (Test-Path -LiteralPath $source)) { throw "构建完成但缺少发布文件：$source" }
    Copy-Item -LiteralPath $source -Destination $distPath
}

$entryPoint = Join-Path $distPath "DisplaySwitcher.Windows.exe"
if (-not (Test-Path -LiteralPath $entryPoint)) { throw "构建完成但未找到入口：$entryPoint" }
$bytes = (Get-ChildItem -LiteralPath $distPath -File -Recurse | Measure-Object Length -Sum).Sum
if ($bytes -ge 20MB) { throw ("dist 体积为 {0:N2} MiB，超过 20 MiB 目标。" -f ($bytes / 1MB)) }
Write-Host ("构建完成：{0}" -f $entryPoint)
Write-Host ("绿色版目录体积：{0:N2} MiB；请复制 dist 中的全部文件。" -f ($bytes / 1MB))
Write-Host "这是 framework-dependent 版本，目标电脑需安装 Windows App Runtime 2.4 x64。"
