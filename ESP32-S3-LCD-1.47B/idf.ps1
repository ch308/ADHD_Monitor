# 在项目根目录运行 ESP-IDF（不依赖全局 PATH 里的 idf.py）
#
# PowerShell 里请二选一（不要裸敲 idf.py，当前目录脚本不会自动执行）：
#   .\idf.ps1 menuconfig
#   . .\activate-idf.ps1    # 点加载后，本窗口可用： idf menuconfig
#
# CMD 里可用：  idf.cmd menuconfig
#
# 路径在 .vscode\esp-idf-env.ps1 中按本机修改。

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $IdfArgs = @("build")
)

$manual = Join-Path $PSScriptRoot ".vscode\esp-idf-manual.ps1"
if (-not (Test-Path -LiteralPath $manual)) {
    Write-Error "Missing: $manual"
    exit 1
}

& $manual @IdfArgs
exit $LASTEXITCODE
