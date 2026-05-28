$buildDir = "C:\etc\adhd_monitor\xiaozhi-esp32-2.2.4\build"
$oldPath = "C:/adhd_monitor/adhd_monitor/xiaozhi-esp32-2.2.4"
$newPath = "C:/etc/adhd_monitor/xiaozhi-esp32-2.2.4"

$files = Get-ChildItem -Path $buildDir -Recurse -File | Where-Object {
    $_.Extension -match '\.(txt|cmake|ninja|json|yaml|S|map|gdbinit|symbols)$' -or
    $_.Name -match '^(CMakeCache|build\.ninja|compile_commands|project_description|\.ninja_log|\.bin_timestamp|TargetDirectories|InstallScripts)$'
}

$count = 0
foreach ($file in $files) {
    try {
        $content = [System.IO.File]::ReadAllText($file.FullName)
        if ($content -match [regex]::Escape($oldPath)) {
            $newContent = $content.Replace($oldPath, $newPath)
            [System.IO.File]::WriteAllText($file.FullName, $newContent)
            Write-Host "Fixed: $($file.FullName)"
            $count++
        }
    } catch {
        Write-Host "Skipped: $($file.FullName) - $_"
    }
}

Write-Host "Total files fixed: $count"
