<#
.SYNOPSIS
  把 plugins/ 下每个插件目录打成 .natsume-plugin.zip，并输出 sha256 与登记表条目。

.DESCRIPTION
  打包口径按《PLUGIN_DEVELOPMENT.md》第 3 节：
    · 把**目录内容**打进去，清单必须在包根（不套外层文件夹）；
    · 条目名用 `/`——用 ZipArchive 逐条写并替换分隔符，打完还会自检
      （CreateFromDirectory 在 Windows PowerShell 下会写成 `\`，宿主在 Android / Linux
      上会因此读不到 `prompts/*` 与 `kb/*`）；
    · 打完算 sha256，直接生成可贴进 registry.json 的条目。

  默认先跑一次 tool/validate_plugins.dart，不通过就不打包。

.PARAMETER Root
  仓库根（默认取本脚本的上一级）。

.PARAMETER OutDir
  输出目录（默认 <Root>/dist）。

.PARAMETER Repo
  发布用的 GitHub 仓库，形如 owner/repo；用于拼 download_url。

.PARAMETER SkipValidate
  跳过 dart 校验（不建议）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool/build_plugins.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool/build_plugins.ps1 -Repo Lamitis/Natsume-Plugins
#>
param(
    [string]$Root = '',
    [string]$OutDir = '',
    [string]$Repo = 'YOUR_GITHUB_USER/YOUR_REPO',
    [switch]$SkipValidate
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
$pluginsDir = Join-Path $Root 'plugins'
if (-not (Test-Path -LiteralPath $pluginsDir)) { throw "找不到插件目录：$pluginsDir" }
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $Root 'dist' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ---- 1. 先校验（清单字段 / 能力白名单 / 资产 / 示例题库 / 槽位）----
if (-not $SkipValidate) {
    $dart = Get-Command dart -ErrorAction SilentlyContinue
    if ($null -eq $dart) {
        Write-Warning '没找到 dart，跳过校验（打包仍会继续）'
    } else {
        Write-Host '== 校验插件 =='
        & dart run (Join-Path $Root 'tool\validate_plugins.dart') $pluginsDir
        if ($LASTEXITCODE -ne 0) { throw '校验未通过，已中止打包' }
        Write-Host ''
    }
}

# ---- 2. 打包 ----
$entries = New-Object System.Collections.ArrayList
foreach ($dir in (Get-ChildItem -LiteralPath $pluginsDir -Directory | Sort-Object Name)) {
    $manifestPath = Join-Path $dir.FullName 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { continue }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Warning "$($dir.Name)：manifest.json 解析失败，跳过（$($_.Exception.Message)）"
        continue
    }

    $id = "$($manifest.id)"
    $version = "$($manifest.version)"
    if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($version)) {
        Write-Warning "$($dir.Name)：manifest 缺 id/version，跳过"
        continue
    }

    $zipName = "$id-$version.natsume-plugin.zip"
    $zipPath = Join-Path $OutDir $zipName
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    # 逐条写 zip 并**强制用 `/` 作条目名**。
    # 为什么不用 [ZipFile]::CreateFromDirectory：在 .NET Framework / Windows PowerShell 下
    # 它会写成 `prompts\cheat_sheet.md`。宿主 PluginLoader.loadFromZip 原样拿条目名落盘
    # （`File('$installDir/${entry.key}')`），在 Android / Linux 上 `\` 不是路径分隔符 →
    # 装出来的目录里只有一堆带反斜杠的文件名，`prompts/`、`kb/` 都不存在 →
    # prompt.md 与功能模板读不到（应用里表现为「插件装上了但没效果」）。
    $base = $dir.FullName.TrimEnd('\', '/')
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
    try {
        foreach ($f in (Get-ChildItem -LiteralPath $base -Recurse -File)) {
            $rel = $f.FullName.Substring($base.Length + 1).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $f.FullName, $rel,
                [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally {
        $zip.Dispose()
    }

    # 打包后自检：条目名必须是 `/`，清单必须在包根（多套一层文件夹宿主就找不到）
    $check = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names = @($check.Entries | ForEach-Object { $_.FullName })
    } finally {
        $check.Dispose()
    }
    $badNames = @($names | Where-Object { $_ -like '*\*' })
    if ($badNames.Count -gt 0) {
        throw "$zipName：条目名含反斜杠，宿主在 Android / Linux 上读不到 kb/* 与 prompts/*：$($badNames -join ', ')"
    }
    if (-not ($names -contains 'manifest.json' -or $names -contains 'plugin.json')) {
        throw "$zipName：清单不在包根（把目录内容打进去，不要多套一层文件夹）"
    }

    $sha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
    $sizeKb = (Get-Item -LiteralPath $zipPath).Length / 1KB
    Write-Host ("  打包 {0}  ({1:N1} KB，{2} 个条目)" -f $zipName, $sizeKb, $names.Count)
    Write-Host ("        sha256 = {0}" -f $sha)

    # 登记条目：只写客户端认识的字段（未知字段会被整条丢弃，见 RegistryPlugin.tryParse）
    # tags：优先取清单里的 tags（发布期提示，客户端不解释）；没有就退回能力名（≤16 字才收）
    $tags = @()
    if ($manifest.tags) {
        foreach ($t in $manifest.tags) {
            if ($tags.Count -ge 6) { break }
            $s = "$t".Trim()
            if ([string]::IsNullOrWhiteSpace($s) -or $s.Length -gt 16) { continue }
            $tags += $s
        }
    }
    if ($tags.Count -eq 0 -and $manifest.capabilities) {
        foreach ($cap in $manifest.capabilities) {
            if ($tags.Count -ge 6) { break }
            if ($null -eq $cap) { continue }
            $s = "$cap".Trim()
            if ($s.Length -gt 16) { continue }
            $tags += $s
        }
    }
    $permissions = @()
    if ($manifest.capabilities) {
        foreach ($cap in $manifest.capabilities) {
            if ($permissions.Count -ge 12) { break }
            if ($null -eq $cap -or "$cap".Length -gt 32) { continue }
            $permissions += "$cap"
        }
    }

    $entry = [ordered]@{
        id           = $id
        name         = "$($manifest.name)"
        author       = "$($manifest.author)"
        version      = $version
        description  = "$($manifest.description)"
        download_url = "https://github.com/$Repo/releases/download/v$version/$zipName"
        sha256       = $sha
        category     = '学习辅助'
        tags         = $tags
        permissions  = $permissions
    }
    [void]$entries.Add($entry)
}

if ($entries.Count -eq 0) {
    Write-Warning '没有可打包的插件'
    exit 1
}

# ---- 3. 输出登记条目（不带 BOM：客户端直接 jsonDecode）----
$payload = [ordered]@{
    schema       = 1
    generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    disclaimer   = '插件是声明式包（清单 + 提示词 + 资产），安装前请确认来源与能力声明。'
    plugins      = $entries
}
$jsonPath = Join-Path $OutDir 'registry.entries.json'
$json = $payload | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($jsonPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "== 完成：$($entries.Count) 个包 =="
Write-Host "输出目录：$OutDir"
Write-Host "登记条目：$jsonPath"
Write-Host ''
Write-Host '提醒：'
Write-Host '  1. 发布后**不要覆盖同名资产**——sha256 一变，老客户端会把它当坏包丢弃；升级请改名 + 换 sha256。'
Write-Host "  2. download_url 里的 $Repo 需要换成真实仓库；下载域名必须是 https 的 GitHub 系域名。"
