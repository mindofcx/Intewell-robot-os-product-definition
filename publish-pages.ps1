[CmdletBinding()]
param(
    [string]$CommitMessage = "docs: update documentation"
)

$ErrorActionPreference = "Stop"

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $false)][string[]]$ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "命令执行失败（退出码 $LASTEXITCODE）：$FilePath $($ArgumentList -join ' ')"
    }
}

$repoRoot = (Resolve-Path $PSScriptRoot).Path
$requiredFiles = @(
    (Join-Path $repoRoot "mkdocs.yml"),
    (Join-Path $repoRoot "requirements.txt"),
    (Join-Path $repoRoot "docs")
)

foreach ($path in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "当前目录不是已配置的文档仓库，缺少：$path"
    }
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    throw "找不到 git。请先安装 Git for Windows。"
}

$branch = (& $git.Source -C $repoRoot branch --show-current).Trim()
if ([string]::IsNullOrWhiteSpace($branch)) {
    throw "当前处于 detached HEAD，无法自动推送。"
}

$bootstrapPython = $null
$pyLauncher = Get-Command py -ErrorAction SilentlyContinue
if ($pyLauncher) {
    $bootstrapPython = $pyLauncher.Source
    $bootstrapArgs = @("-3")
} else {
    $pythonLauncher = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonLauncher) {
        throw "找不到 Python。请安装 Python 3 后重新运行。"
    }
    $bootstrapPython = $pythonLauncher.Source
    $bootstrapArgs = @()
}

$venvDir = Join-Path $repoRoot ".pages-venv"
$venvPython = Join-Path $venvDir "Scripts\python.exe"
$requirements = Join-Path $repoRoot "requirements.txt"
$requirementsHash = (Get-FileHash -LiteralPath $requirements -Algorithm SHA256).Hash
$stamp = Join-Path $venvDir ".requirements.sha256"

if (-not (Test-Path -LiteralPath $venvPython)) {
    Write-Host "创建本地 Pages 构建环境..."
    Invoke-CheckedCommand -FilePath $bootstrapPython -ArgumentList ($bootstrapArgs + @("-m", "venv", $venvDir))
}

$installedHash = if (Test-Path -LiteralPath $stamp) {
    (Get-Content -LiteralPath $stamp -Raw).Trim()
} else {
    ""
}

if ($installedHash -ne $requirementsHash) {
    Write-Host "安装或更新 MkDocs 依赖..."
    Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @("-m", "pip", "install", "--upgrade", "-r", $requirements)
    Set-Content -LiteralPath $stamp -Value $requirementsHash -NoNewline -Encoding ascii
}

Write-Host "检查 Markdown 格式..."
Invoke-CheckedCommand -FilePath $git.Source -ArgumentList @("-C", $repoRoot, "diff", "--check")

Write-Host "构建文档站点..."
Invoke-CheckedCommand -FilePath $venvPython -ArgumentList @("-m", "mkdocs", "build", "--strict", "-f", (Join-Path $repoRoot "mkdocs.yml"))

$statusBefore = @(& $git.Source -C $repoRoot status --short)
if ($statusBefore.Count -eq 0) {
    Write-Host "没有检测到新的文件变更，不需要提交。"
    exit 0
}

Write-Host "将提交以下变更："
$statusBefore | ForEach-Object { Write-Host "  $_" }

# 排除本地虚拟环境，其余文档仓库变更统一提交。
Invoke-CheckedCommand -FilePath $git.Source -ArgumentList @(
    "-C", $repoRoot, "add", "-A", "--", ".", ":(exclude).pages-venv/"
)

& $git.Source -C $repoRoot diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    Write-Host "没有可提交的变更。"
    exit 0
}

Invoke-CheckedCommand -FilePath $git.Source -ArgumentList @("-C", $repoRoot, "commit", "-m", $CommitMessage)
Invoke-CheckedCommand -FilePath $git.Source -ArgumentList @("-C", $repoRoot, "push", "origin", $branch)

Write-Host "发布完成。GitHub Actions 将自动重新构建并部署 Pages。"
Write-Host "站点地址：https://mindofcx.github.io/Intewell-robot-os-product-definition/"
