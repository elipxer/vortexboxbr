# Tuned VortexBox launcher for Intel Xeon E5-2650 v3 (10c/20t Haswell) + NVIDIA RTX 3050 8 GB (PCIe 3.0 x8, ReBAR off) + 32 GB RAM.
# Examples:
#   scripts\play-rtx3050-xeon.ps1 -Dlss performance -FsrFrameGen -Panel
#   scripts\play-rtx3050-xeon.ps1 -Dlss ultraperformance -FsrFrameGen -Panel
#   scripts\play-rtx3050-xeon.ps1 -Resolution 360 -Panel
param(
    [Parameter(Mandatory)][string]$Exe,
    [ValidateSet('off', 'dlaa', 'quality', 'balanced', 'performance', 'ultraperformance')][string]$Dlss = 'off',
    [Alias('FrameGen')][switch]$FsrFrameGen,
    [ValidateRange(2, 6)][int]$FrameGenX = 2,
    [ValidateSet('auto', 'dlss', 'fsr')][string]$FgType = 'fsr',
    [ValidateRange(1, 1000)][int]$Fps = 1000,
    [ValidateSet('1080', '720', '540', '480', '420', '360')][string]$Resolution = '540',
    [switch]$Quality,
    [switch]$Thin,
    [switch]$Panel,
    [switch]$SmoothMotion,
    [switch]$RayTracing,
    [switch]$LegacySubmit,
    [switch]$FullAmbient,
    [switch]$KeepBink,
    [switch]$NoUploadQueue,
    [switch]$UseMenuSettings,
    [int]$MaxTexDim = 512,
    [string]$LogFile,
    [switch]$NoLog,
    [ValidateSet('diag', 'release')][string]$Build = 'release',
    [hashtable]$More = @{}
)

$menuDir = Join-Path $env:LOCALAPPDATA 'victory'
if (-not (Test-Path $menuDir)) { New-Item -ItemType Directory -Path $menuDir -Force | Out-Null }
$menuFile = Join-Path $menuDir 'vortexbox-settings.txt'
$menu = [ordered]@{}
if ($UseMenuSettings -and (Test-Path -LiteralPath $menuFile -PathType Leaf)) {
    foreach ($line in Get-Content -LiteralPath $menuFile) {
        if ($line -match '^\s*(VICTORY_[A-Z0-9_]+)\s*=(.*)$') { $menu[$Matches[1]] = $Matches[2].Trim() }
    }
    if ($menu['VICTORY_MENU_DLSS'] -in 'off', 'dlaa', 'quality', 'balanced', 'performance', 'ultraperformance') {
        $Dlss = $menu['VICTORY_MENU_DLSS']
    }
    if ($menu.Contains('VICTORY_MENU_FRAMEGEN')) {
        $FsrFrameGen = $menu['VICTORY_MENU_FRAMEGEN'] -match '^[1-6]$'
        if ($menu['VICTORY_MENU_FRAMEGEN'] -match '^[2-6]$') { $FrameGenX = [int]$menu['VICTORY_MENU_FRAMEGEN'] }
    }
    if ($menu['VICTORY_MENU_FG_TYPE'] -in 'auto', 'dlss', 'fsr') { $FgType = $menu['VICTORY_MENU_FG_TYPE'] }
    if ($menu['VICTORY_MENU_FPS'] -match '^\d+$' -and [int]$menu['VICTORY_MENU_FPS'] -ge 1 -and [int]$menu['VICTORY_MENU_FPS'] -le 1000) {
        $Fps = [int]$menu['VICTORY_MENU_FPS']
    }
}

if (-not $NoLog) {
    if (-not $LogFile) {
        $logDir = Join-Path $env:LOCALAPPDATA 'victory\logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $LogFile = Join-Path $logDir ("run-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    }
}

$fgActive = [bool]$FsrFrameGen
$dlssActive = $Dlss -ne 'off'
# Reserve ~20% of the 7.1 GiB WDDM VRAM budget when DLSS / FSR 3 FG are active so FG history/optical-flow surfaces never spill.
$texRoom = if ($fgActive -or $dlssActive) { '80' } else { '85' }

$tuned = @{
    # Keep async submission + joining active even when VICTORY_THIN=0.
    VICTORY_ASYNC_SUBMIT = '1'
    VICTORY_NO_WATCHDOG = '1'
    VICTORY_TITLE_PRIORITIES = '1'
    # Wave 4: Helper thread priority discipline (PR #22) prevents background workers starving the main/submit threads on 10c/20t Xeon.
    VICTORY_HELPER_PRIORITY = '1'
    # Wave 4: Lockless + batched texture refresh (PR #59) removes mutex stalls on descriptor/texture uploads.
    VICTORY_REFRESH_LOCKLESS = '1'
    VICTORY_REFRESH_BATCH = '1'
    # Wave 4: Dedicated async upload queue (PR #60) capped at 128 MiB for 8 GB VRAM safety.
    VICTORY_UPLOAD_QUEUE = if ($NoUploadQueue) { '0' } else { '1' }
    VICTORY_UPLOAD_QUEUE_MB = '128'
    # Wave 4: Skip intro Bink videos by default for fast gameplay testing (pass -KeepBink to watch them).
    VICTORY_SKIP_BINK = if ($KeepBink) { '0' } else { '1' }
    # Wave 4: Skip decal heap defrag (-5.6 ms GPU/frame!) and smeared heat-haze pass (upstream 29d8dbf7).
    VICTORY_LEAVE_OUT = '02384a60fda6f2d0,731a39171b568298'
    # 8 GB VRAM + PCIe 3.0 x8 tuning (7.1 GiB WDDM budget):
    # Note: VICTORY_CARD_ROOM_FOR_TARGETS_MB is intentionally UNSET so PR #76 targets_kept_from_peak (~195 MiB on Series S) frees ~1.2 GiB VRAM!
    VICTORY_LEVELS_ON_DEMAND = '1'
    VICTORY_MAX_TEXTURE_DIM = $MaxTexDim.ToString([Globalization.CultureInfo]::InvariantCulture)
    VICTORY_CARD_BUFFERS_MIN_KB = '256'
    VICTORY_CARD_BUFFERS_MB = '1536'
    VICTORY_CARD_WINDOWS_MB = '768'
    VICTORY_TEXTURE_ROOM_PERCENT = $texRoom
    VICTORY_AMBIENT_HALF = if ($FullAmbient) { '0' } else { '1' }
    # On-screen top-left FPS + FG counter (even when F3 panel is hidden).
    VICTORY_FPS_LINE = '1'
    # Xeon E5-2650 v3 (10c/20t Haswell, 25 MB L3) right-sized worker pools:
    VICTORY_DSTORAGE_THREADS = '6'
    VICTORY_LAND_THREADS = '5'
    VICTORY_UNDER_THREADS = '4'
    VICTORY_VIEW_THREADS = '4'
    VICTORY_WIDE_THREADS = '5'
    VICTORY_WIDE_SPIN = '0'
    VICTORY_LAND_SKIP = '1'
    VICTORY_PIPELINE_WORKERS = '3'
}
if (-not $LegacySubmit) {
    # Kelvaroq 0053 & 0055 submit/descriptor optimizations:
    $tuned.VICTORY_REFRESH_SCRATCH = '1'
    $tuned.VICTORY_BATCH_GUARDS = '1'
    $tuned.VICTORY_REFRESH_SPLIT_COPY = '1'
    $tuned.VICTORY_BATCH_UPLOAD_LISTS = '1'
    $tuned.VICTORY_DESCRIPTOR_BUFFER_SPANS = '1'
} else {
    $tuned.VICTORY_REFRESH_SCRATCH = '0'
}
if ($Thin) {
    $tuned.VICTORY_THIN = '1'
    $tuned.VICTORY_THIN_THREADS = '8'
}
if ($LogFile) {
    $tuned.VICTORY_LOG_FILE = $LogFile
}

# Apply non-menu switches saved by the F1 menu (only when restarted from F1 menu via -UseMenuSettings).
foreach ($k in $menu.Keys) {
    if ($k -like 'VICTORY_MENU_*') { continue }
    if ($menu[$k]) { $tuned[$k] = $menu[$k] } else { $tuned[$k] = '' }
}
foreach ($k in $More.Keys) { $tuned[$k] = $More[$k] }

# Wire F1 live settings menu metadata so Save and Save & Restart work out of the box!
$tuned.VICTORY_MENU_CONSOLE = 'series-s'
$tuned.VICTORY_MENU_RES = '1440'
$tuned.VICTORY_MENU_DLSS = $Dlss
$tuned.VICTORY_MENU_FRAMEGEN = if ($fgActive) { [string]$FrameGenX } else { '0' }
$tuned.VICTORY_MENU_FG_TYPE = $FgType
$tuned.VICTORY_MENU_FPS = [string]$Fps
$tuned.VICTORY_MENU_FILE = $menuFile
$tuned.VICTORY_MENU_PLAY = $MyInvocation.MyCommand.Path
$tuned.VICTORY_MENU_ARGS = "-Exe '$($Exe -replace "'", "''")' -Build $Build -UseMenuSettings$(if ($Panel) { ' -Panel' })$(if ($Thin) { ' -Thin' })"

$pass = @{
    Exe = $Exe
    Dlss = $Dlss
    FgType = $FgType
    FrameGenX = $FrameGenX
    Fps = $Fps
    Resolution = $Resolution
    Build = $Build
    WindowsBarMB = [uint32]0
    LevelsOnDemand = $true
    More = $tuned
}
if ($FsrFrameGen) { $pass.FsrFrameGen = $true }
if (-not $SmoothMotion -or $fgActive) { $pass.NoSmoothMotion = $true }
if ($Quality) { $pass.Quality = $true }
if ($Thin) { $pass.Thin = $true }
if ($Panel) { $pass.Panel = $true }
if ($RayTracing) { $pass.RayTracing = $true }

Write-Host "=== VortexBox Wave 4 | RTX 3050 8GB + Xeon E5-2650 v3 (10c/20t) [$Build] ==="
Write-Host "VRAM: PeakTargetRoom (PR#76) | LevelsOnDemand | MaxTexDim=${MaxTexDim}px | CardBuf 1536MB | CardWin 768MB | TexRoom ${texRoom}%"
if ($dlssActive -or $fgActive) {
    Write-Host "UPS : DLSS=$Dlss | AMD FSR 3 FrameGen=$(if ($fgActive) { "${FrameGenX}x (HUD-less 2-plane)" } else { 'OFF' }) | FpsCap=$Fps"
} else {
    Write-Host "UPS : Legacy Renderer 6 (${Resolution}p -> 1080p) | FpsCap=$Fps"
}
Write-Host "GPU : AmbientHalf=$(-not $FullAmbient) | WaterLight=SKIP | DecalDefrag+HeatHaze=SKIP | RT=OFF"
Write-Host "CPU : AsyncSubmit | HelperPrio=1 | RefreshLockless+Batch=1 | UpQ=$(-not $NoUploadQueue)(128MB) | SkipBink=$(-not $KeepBink) | Thin=$([bool]$Thin)"
Write-Host "UI  : F1 = Settings Menu (Save & Restart) | F3 = Telemetry Panel"
if ($LogFile) { Write-Host "LOG : $LogFile" }
& "$PSScriptRoot\play-nvidia.ps1" @pass
exit $LASTEXITCODE
