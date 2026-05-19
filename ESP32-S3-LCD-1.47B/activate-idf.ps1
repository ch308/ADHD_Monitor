# 在当前 PowerShell 会话加载 ESP-IDF 环境，并注册命令 idf（等同 idf.py）。
# 用法（注意第一个点后面有空格，表示“点加载”）：
#   . .\activate-idf.ps1
# 然后在本窗口可直接：
#   idf menuconfig
#   idf build
#
# 说明：PowerShell 不能把命令注册成 “idf.py”（名称里不能带点），
#       裸敲 idf.py 也不会自动用当前目录下的脚本，所以请用 idf 或 .\idf.ps1。

$envScript = Join-Path $PSScriptRoot ".vscode\esp-idf-env.ps1"
if (-not (Test-Path -LiteralPath $envScript)) {
    Write-Error "Missing: $envScript"
    return
}
. $envScript

$global:IDF_PROJECT_DIR = $PSScriptRoot

function global:idf {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]] $IdfArgs
    )
    & python "$env:IDF_PATH\tools\idf.py" -C $global:IDF_PROJECT_DIR @IdfArgs
}

Write-Host "ESP-IDF 已载入本会话。工程目录: $global:IDF_PROJECT_DIR" -ForegroundColor Green
Write-Host "请执行:  idf menuconfig   或   idf build   （不要敲裸的 idf.py）" -ForegroundColor Cyan
