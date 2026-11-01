<#
.SYNOPSIS
  把 dist/ 里的插件包发布到 GitHub Release，并把登记条目写进 Natsume-Registry。

.DESCRIPTION
  分三段，每段都能单独跳过：

  1. Release —— 用 GitHub REST API 建 <Tag> 发布页，把 dist/*.natsume-plugin.zip 作为
     release asset 上传（同名 asset 已存在就跳过，**不覆盖**：覆盖会改 sha256，
     老客户端会把包当坏包丢弃）。
  2. 校验 —— 把 asset 真下载回来重算 sha256，与本地文件比对。这一步就是登记表 CI
     （scripts/validate_pr.py）干的事，先在这里跑一遍，免得 PR 红。
  3. 登记 —— 在 Natsume-Registry 里写 plugins/<id>.json（严格 7 个字段）、
     用仓库自带脚本重建 registry.json、提交并推送。

  凭据：从 git 的 credential helper 取（`git credential fill`），不落盘、不写进任何文件。

.PARAMETER Repo
  发布插件包的仓库（默认主程序仓库；官方插件包与 App 版本分开发布）。

.PARAMETER Tag
  发布页 tag（默认 plugins-v1.0.0）。改 tag 等于换下载地址，登记表要跟着改。

.PARAMETER RegistryDir
  本地 Natsume-Registry 克隆目录。

.PARAMETER StopBeforePush
  只做本地提交，不推送（先看 diff 时用）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tool/publish_plugins.ps1 -StopBeforePush
#>
param(
    [string]$Root = '',
    [string]$Repo = 'Lamitis/NatsumeQuizMaster',
    [string]$Tag = 'plugins-v1.0.0',
    [string]$RegistryDir = 'D:\Natsume-Registry',
    [switch]$SkipRelease,
    [switch]$SkipRegistry,
    [switch]$StopBeforePush
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}
$distDir = Join-Path $Root 'dist'
if (-not (Test-Path -LiteralPath $distDir)) { throw "找不到 dist：$distDir（先跑 tool/build_plugins.ps1）" }

# ---- 0. 收集要发布的包（id / version / 文件 / 哈希 都以本地文件为准）----
# v1.1 起插件目录平铺在仓库根（与 publish-plugins.yml 一致）
$items = @()
foreach ($dir in (Get-ChildItem -LiteralPath $Root -Directory | Sort-Object Name)) {
    $manifestPath = Join-Path $dir.FullName 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $id = "$($manifest.id)"
    $version = "$($manifest.version)"
    if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($version)) { continue }
    $zipName = "$($dir.Name)-$version.natsume-plugin.zip"
    $zipPath = Join-Path $distDir $zipName
    if (-not (Test-Path -LiteralPath $zipPath)) { throw "缺少包：$zipPath（先跑 tool/build_plugins.ps1）" }
    $items += [pscustomobject]@{
        Id          = $id
        Name        = "$($manifest.name)"
        Author      = "$($manifest.author)"
        Version     = $version
        Description = "$($manifest.description)"
        ZipName     = $zipName
        ZipPath     = $zipPath
        Sha256      = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
    }
}
if ($items.Count -eq 0) { throw '没有可发布的插件' }

Write-Host "== 待发布 $($items.Count) 个插件（tag: $Tag, repo: $Repo）=="
foreach ($it in $items) {
    Write-Host ("   {0} v{1}  sha256={2}" -f $it.Id, $it.Version, $it.Sha256)
}

# ---- 1. 取凭据（git 的 credential helper）----
$cred = "protocol=https`nhost=github.com`n`n" | & git credential fill
$tokenLine = ($cred | Select-String '^password=' | Select-Object -First 1)
if ($null -eq $tokenLine) { throw '拿不到 GitHub 凭据（git credential fill 没有返回 password）' }
$token = $tokenLine.ToString().Substring('password='.Length).Trim()
$headers = @{
    Authorization = "Bearer $token"
    'User-Agent'  = 'natsume-plugins-publish'
    Accept        = 'application/vnd.github+json'
}
$api = "https://api.github.com/repos/$Repo"

# ---- 2. 建 / 复用 Release，并上传 asset ----
if (-not $SkipRelease) {
    $release = $null
    try {
        $release = Invoke-RestMethod -Uri "$api/releases/tags/$Tag" -Headers $headers -Method Get
        Write-Host "== Release $Tag 已存在（id=$($release.id)），复用"
    } catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -ne 404) { throw }

        $lines = @(
            'NatsumeQuizMaster 官方插件包（声明式包：清单 + 提示词 + 资产，不含可执行代码）。',
            ''
        )
        foreach ($it in $items) {
            $lines += "- $($it.Id) v$($it.Version) — $($it.Name)：$($it.Description)"
        }
        $lines += ''
        $lines += '安装：世界总览 → 导入插件 → 选 .natsume-plugin.zip；或经 Natsume-Registry 安装。'
        $lines += '校验：每个包的 sha256 见 release assets 与 Natsume-Registry 登记条目。'

        $body = [ordered]@{
            tag_name         = $Tag
            name             = "官方插件包 $($Tag -replace '^plugins-', '')"
            target_commitish = 'main'
            body             = ($lines -join "`n")
            draft            = $false
            prerelease       = $false
        }
        $json = $body | ConvertTo-Json -Depth 5
        $release = Invoke-RestMethod -Uri "$api/releases" -Headers $headers -Method Post `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
        Write-Host "== 已创建 Release $Tag（id=$($release.id)）"
    }

    $existing = @{}
    foreach ($a in $release.assets) { $existing["$($a.name)"] = $a }

    foreach ($it in $items) {
        if ($existing.ContainsKey($it.ZipName)) {
            Write-Host ("   跳过（已存在）：{0}" -f $it.ZipName)
            continue
        }
        $bytes = [System.IO.File]::ReadAllBytes($it.ZipPath)
        $upload = "https://uploads.github.com/repos/$Repo/releases/$($release.id)/assets?name=$($it.ZipName)"
        $asset = Invoke-RestMethod -Uri $upload -Headers $headers -Method Post `
            -ContentType 'application/zip' -Body $bytes
        Write-Host ("   已上传：{0}（{1} bytes）" -f $asset.name, $asset.size)
    }
}

# ---- 3. 下载回来重算哈希（登记表 CI 的核心校验）----
Write-Host '== 校验下载地址与 sha256'
$verified = @{}
foreach ($it in $items) {
    $url = "https://github.com/$Repo/releases/download/$Tag/$($it.ZipName)"
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('natsume_verify_' + $it.ZipName)
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing `
        -Headers @{ 'User-Agent' = 'natsume-plugins-publish' }
    $remote = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLower()
    Remove-Item -LiteralPath $tmp -Force
    if ($remote -ne $it.Sha256) {
        throw "sha256 不一致：$($it.ZipName) 远端 $remote / 本地 $($it.Sha256)（不要覆盖同名 asset，发新版本）"
    }
    $verified[$it.Id] = $url
    Write-Host ("   OK {0}" -f $url)
}

if ($SkipRegistry) {
    Write-Host '== 跳过登记表（-SkipRegistry）'
    exit 0
}

# ---- 4. 写登记条目（严格 7 个字段：validate_pr.py 多一个就拒）----
if (-not (Test-Path -LiteralPath $RegistryDir)) { throw "找不到登记表仓库：$RegistryDir" }
$pluginsJsonDir = Join-Path $RegistryDir 'plugins'
if (-not (Test-Path -LiteralPath $pluginsJsonDir)) {
    New-Item -ItemType Directory -Path $pluginsJsonDir | Out-Null
}

$written = @()
foreach ($it in $items) {
    $entry = [ordered]@{
        id           = $it.Id
        name         = $it.Name
        author       = $it.Author
        version      = $it.Version
        description  = $it.Description
        download_url = $verified[$it.Id]
        sha256       = $it.Sha256
    }
    $path = Join-Path $pluginsJsonDir "$($it.Id).json"
    $json = $entry | ConvertTo-Json -Depth 3
    [System.IO.File]::WriteAllText($path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
    $written += $path
    Write-Host "   写入 $path"
}

Push-Location $RegistryDir
try {
    # ---- 5. 用仓库自带脚本逐条校验（一个 PR 只允许一个文件，所以分开跑）----
    foreach ($path in $written) {
        $rel = 'plugins/' + [System.IO.Path]::GetFileName($path)
        $changed = Join-Path ([System.IO.Path]::GetTempPath()) 'natsume_changed.txt'
        [System.IO.File]::WriteAllText($changed, $rel + "`n", (New-Object System.Text.UTF8Encoding($false)))
        python scripts/validate_pr.py $changed $RegistryDir
        if ($LASTEXITCODE -ne 0) { throw "登记表校验未通过：$rel" }
    }

    # ---- 6. 重建 registry.json ----
    python scripts/build_registry.py
    if ($LASTEXITCODE -ne 0) { throw '重建 registry.json 失败' }

    # ---- 7. 提交 + 推送 ----
    git add plugins
    git add registry.json
    $msgLines = @(
        "feat: register $($items.Count) first-party plugins ($Tag)",
        ''
    )
    foreach ($it in $items) {
        $msgLines += "- $($it.Id) v$($it.Version)：$($it.Name)"
    }
    $msgLines += ''
    $msgLines += 'download_url 指向 GitHub Release 的 asset，sha256 已下载回来重算比对；'
    $msgLines += 'registry.json 由 scripts/build_registry.py 重建。'
    git commit -m ($msgLines -join "`n")
    if ($LASTEXITCODE -ne 0) { throw '提交失败（工作区可能没有变化）' }

    if ($StopBeforePush) {
        Write-Host '== 已本地提交（-StopBeforePush，未推送）'
        exit 0
    }

    $env:GIT_TERMINAL_PROMPT = '0'
    git push origin HEAD:main
    if ($LASTEXITCODE -ne 0) { throw '推送失败（检查凭据 / 分支保护）' }
    Write-Host '== 已推送到 registry main'
} finally {
    Pop-Location
}


