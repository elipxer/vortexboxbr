# Tuned VortexBoxBR Wave 5 launcher (Foxhound + CGBJ 29d8dbf7 base) for
# Intel Xeon E5-2650 v3 (10c/20t Haswell) + NVIDIA RTX 3050 8 GB (PCIe 3.0 x8, ReBAR off) + 32 GB RAM.
#
# Examples:
#   .\scripts\play-rtx3050-xeon.ps1 -Exe 'C:\Path\To\game_scarlett_master.exe' -Dlss performance -FsrFrameGen -Panel
#   .\scripts\play-rtx3050-xeon.ps1 -Exe 'C:\Path\To\game_scarlett_master.exe' -Dlss ultraperformance -FsrFrameGen -HalfAmbient -Panel
#   .\scripts\play-rtx3050-xeon.ps1 -Exe 'C:\Path\To\game_scarlett_master.exe' -Dlss quality -FsrFrameGen -MaxTexDim 1024 -Panel
param(
    [Parameter(Mandatory)][string]$Exe,
    [ValidateSet('off', 'dlaa', 'quality', 'balanced', 'performance', 'ultraperformance')][string]$Dlss = 'performance',
    [Alias('FrameGen')][switch]$FsrFrameGen,
    [ValidateRange(2, 6)][int]$FrameGenX = 2,
    [ValidateSet('auto', 'dlss', 'fsr')][string]$FgType = 'fsr',
    [switch]$NoFrameGenReady,
    [ValidateRange(1, 1000)][int]$Fps = 1000,
    [switch]$SeriesX,
    [ValidateSet('1440', '1080to1440', '4k')][string]$Res = '1440',
    [switch]$NoThin,
    [switch]$Panel,
    [switch]$RayTracing,
    [switch]$HalfAmbient,
    [switch]$KeepBink,
    [switch]$Preload,
    [switch]$UseMenuSettings,
    [ValidateRange(0, 8192)][int]$MaxTexDim = 1024,
    [string]$LogFile,
    [switch]$NoLog,
    [ValidateSet('diag', 'release')][string]$Build = 'release',
    [hashtable]$More = @{}
)

$repo = Split-Path $PSScriptRoot -Parent
$preloadWanted = $Preload -or ($env:VICTORY_PRELOAD -eq '1')

$menuDir = Join-Path $env:LOCALAPPDATA 'victory'
if (-not (Test-Path -LiteralPath $menuDir)) { New-Item -ItemType Directory -Path $menuDir -Force | Out-Null }
$menuFile = Join-Path $menuDir 'vortexbox-settings.txt'
$menu = [ordered]@{}
if ($UseMenuSettings -and (Test-Path -LiteralPath $menuFile -PathType Leaf)) {
    foreach ($line in Get-Content -LiteralPath $menuFile) {
        if ($line -match '^\s*(VICTORY_[A-Z0-9_]+)\s*=(.*)$') { $menu[$Matches[1]] = $Matches[2].Trim() }
    }
    if ($menu.Contains('VICTORY_MENU_CONSOLE')) { $SeriesX = ($menu['VICTORY_MENU_CONSOLE'] -eq 'series-x') }
    if ($menu['VICTORY_MENU_RES'] -in '1440', '1080to1440', '4k') { $Res = $menu['VICTORY_MENU_RES'] }
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

$victory = Join-Path $repo "target\$Build\victory.exe"
if (-not (Test-Path -LiteralPath $victory -PathType Leaf)) {
    Write-Error "Missing $victory. Build VortexBoxBR first: cargo build --locked --release -p victory"
    exit 1
}
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    Write-Error "Game executable not found: $Exe"
    exit 1
}

# Locate external NVIDIA Streamline and AMD FidelityFX SDKs (never tracked in git).
$slCandidates = @()
if ($env:VICTORY_STREAMLINE_DIR) { $slCandidates += $env:VICTORY_STREAMLINE_DIR }
$slCandidates += (Join-Path $menuDir 'nvidia-sdk\Streamline\bin\x64')
$slCandidates += (Join-Path $repo 'nvidia-sdk\Streamline\bin\x64')
$slDir = $slCandidates | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $_ 'sl.interposer.dll') -PathType Leaf) } | Select-Object -First 1

$fxCandidates = @()
if ($env:VICTORY_FIDELITYFX_DIR) { $fxCandidates += $env:VICTORY_FIDELITYFX_DIR }
$fxCandidates += (Join-Path $menuDir 'fidelityfx')
$fxCandidates += (Join-Path $repo 'amd-sdk\FidelityFX\bin')
$fxDir = $fxCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) } | Select-Object -First 1

$fgActive = [bool]$FsrFrameGen
$dlssActive = ($Dlss -ne 'off') -and [bool]$slDir
$texRoom = if ($fgActive) { '85' } elseif ($dlssActive -or -not $NoFrameGenReady) { '86' } else { '88' }
$console = if ($SeriesX) { 'series-x' } else { 'series-s' }

$settings = [ordered]@{
    # Foxhound + CGBJ submission, relay, indirect batching and async pipeline
    VICTORY_THIN = if ($NoThin) { '0' } else { '1' }
    VICTORY_THIN_THREADS = '8'
    VICTORY_JOIN_PARTS = '8'
    VICTORY_RELAY = '2'
    VICTORY_RELAY_COPY = '1'
    VICTORY_WIDE_BACK = '1'
    VICTORY_CARD_REHASH_RUNS = '1'
    VICTORY_JOIN_COPIES = '1'
    VICTORY_CARD_STEPS = '2'
    VICTORY_CARD_AWAKE = '1'
    VICTORY_INDIRECT_WINDOW = '1'
    VICTORY_INDIRECT_BATCH = '2'
    VICTORY_UPLOAD_AHEAD = '1'
    VICTORY_SHOW_AFTER = '1'
    VICTORY_MAP_THREADS = '1'
    VICTORY_ASYNC_SUBMIT = '1'
    VICTORY_TITLE_PRIORITIES = '1'
    VICTORY_HELPER_PRIORITY = '1'
    VICTORY_NO_WATCHDOG = '1'
    VICTORY_SKIP_BINK = if ($KeepBink) { '0' } else { '1' }

    # Foxhound major CPU/PCIe wins: keep big WC writes on GPU + soft views (no cutscene freezes)
    VICTORY_WC_NO_BACK = '1'
    VICTORY_WC_NO_BACK_MIN_KB = '1024'
    VICTORY_SOFT_VIEWS = 'copies'

    # Foxhound descriptor-heap sync breakthroughs + Kelvaroq 0053/0055
    VICTORY_HEAP_SYNC_FIRST = '1'
    VICTORY_SYNC_IN_PLACE = '1'
    VICTORY_SPANS_QUICK = '1'
    VICTORY_SYNC_FINE = '1'
    VICTORY_HEAP_SYNC_AT_SUBMIT = '1'
    VICTORY_DESCRIPTOR_BUFFER_SPANS = '1'
    VICTORY_REFRESH_SCRATCH = '1'

    # 8 GB VRAM survival kit (7.1 GiB WDDM budget, ReBAR off):
    # VICTORY_CARD_ROOM_FOR_TARGETS_MB is intentionally unset so PR #76 targets_kept_from_peak runs.
    VICTORY_LEVELS_ON_DEMAND = '1'
    VICTORY_TEXTURE_POOL = '1'
    VICTORY_RIPE_BLOCKS = '0'
    VICTORY_TEXTURE_NO_WAIT = '1'
    VICTORY_TEXTURE_CATCHUP = '0'
    VICTORY_TEXTURE_STAGE_MS = '16'
    VICTORY_PRELUDE_UPLOADS = '1'
    VICTORY_SHOW_NEW_LATER = '1'
    VICTORY_POOL_SMALL = '0'
    VICTORY_TABLED_REREAD = '1'
    VICTORY_QUEUE_HOST_TEXTURES = '0'
    VICTORY_MAX_TEXTURE_DIM = $MaxTexDim.ToString([Globalization.CultureInfo]::InvariantCulture)
    VICTORY_CARD_BUFFERS_MIN_KB = '256'
    VICTORY_CARD_BUFFERS_MB = '640'
    VICTORY_CARD_WINDOWS_MB = '128'
    VICTORY_WINDOWS_BAR_MB = '0'
    VICTORY_TEXTURE_ROOM_PERCENT = $texRoom

    # Graphics, lighting, water & RTX 3050 wave32 accuracy (PR #30 + early-Z + specular reflections)
    VICTORY_EARLY_DEPTH = '1'
    VICTORY_THREAD_TICKET = '1'
    VICTORY_AMBIENT = '0.8'
    VICTORY_AMBIENT_AIR = '1.5'
    VICTORY_AMBIENT_SPECULAR = '1'
    VICTORY_AMBIENT_SPECULAR_ALPHA = '0'
    VICTORY_AMBIENT_HALF = if ($HalfAmbient) { '1' } else { '0' }
    VICTORY_LEAVE_OUT = '02384a60fda6f2d0,731a39171b568298'

    # Xeon E5-2650 v3 (10c/20t Haswell, 25 MB L3) right-sized worker pools
    VICTORY_DSTORAGE_THREADS = '6'
    VICTORY_LAND_THREADS = '5'
    VICTORY_UNDER_THREADS = '4'
    VICTORY_VIEW_THREADS = '4'
    VICTORY_WIDE_THREADS = '5'
    VICTORY_WIDE_SPIN = '0'
    VICTORY_LAND_SKIP = '1'
    VICTORY_PIPELINE_WORKERS = '6'
    # Never stall gameplay frames for 500 ms waiting on cold non-screen PSO compiles.
    VICTORY_PIPELINE_WAIT_MS = '16'

    # Record used pipelines for `victory warm --used` + HUD counters
    VICTORY_PIPELINE_BOOK = '1'
    VICTORY_FPS_LINE = '1'
    VICTORY_PANEL = if ($Panel) { '1' } else { '0' }
    VICTORY_FRAME_INTERVAL_US = [string][int][math]::Round(1000000 / $Fps)
}

if ($RayTracing) { $settings.VICTORY_BVH_BUILDER = '1' }
if ($SeriesX) {
    if ($Res -eq '1440') { $settings.VICTORY_NATIVE_1440P = '1' }
    elseif ($Res -eq '1080to1440') { $settings.VICTORY_RENDER_1080P = '1' }
}

if ($dlssActive) {
    $settings.VICTORY_DLSS = '1'
    $settings.VICTORY_DLSS_MODE = $Dlss
    $settings.VICTORY_STREAMLINE_DIR = $slDir
    if ($FgType -ne 'fsr') {
        if ($fgActive) {
            $settings.VICTORY_FRAMEGEN = '1'
            $settings.VICTORY_FRAMEGEN_X = [string]$FrameGenX
        } elseif (-not $NoFrameGenReady) {
            $settings.VICTORY_FRAMEGEN = '1'
            $settings.VICTORY_FRAMEGEN_X = '0'
        }
    }
} elseif ($Dlss -ne 'off') {
    Write-Warning "NVIDIA Streamline SDK not found; running without DLSS. Run `victory get-dlss` or set VICTORY_STREAMLINE_DIR."
}

if ($FgType -ne 'dlss' -and ($fgActive -or -not $NoFrameGenReady)) {
    if ($fxDir) {
        $settings.VICTORY_FSR_FRAMEGEN = '1'
        $settings.VICTORY_FIDELITYFX_DIR = $fxDir
        $settings.VICTORY_FRAMEGEN_HUDLESS = '1'
        if ($FgType -eq 'fsr') { $settings.Remove('VICTORY_FRAMEGEN') }
        if (-not $settings.Contains('VICTORY_FRAMEGEN_X')) {
            $settings.VICTORY_FRAMEGEN_X = if ($fgActive) { [string]$FrameGenX } else { '0' }
        }
    } else {
        Write-Warning "AMD FidelityFX SDK not found; running without FSR 3 Frame Generation. Set VICTORY_FIDELITYFX_DIR."
    }
}

# Apply non-menu switches saved by the F1 menu (only when restarted via -UseMenuSettings).
foreach ($k in $menu.Keys) {
    if ($k -like 'VICTORY_MENU_*') { continue }
    if ($menu[$k]) { $settings[$k] = $menu[$k] } else { $settings.Remove($k) }
}
foreach ($k in $More.Keys) {
    if ($null -eq $More[$k] -or $More[$k] -eq '') { $settings.Remove($k) } else { $settings[$k] = [string]$More[$k] }
}

# Wire F1 live settings menu metadata so Save, Save & Restart, and Preload work cleanly.
$settings.VICTORY_MENU_CONSOLE = $console
$settings.VICTORY_MENU_RES = $Res
$settings.VICTORY_MENU_DLSS = if ($settings.VICTORY_DLSS -eq '1') { $Dlss } else { 'off' }
$settings.VICTORY_MENU_FRAMEGEN = if ($settings.VICTORY_FRAMEGEN -eq '1' -or $settings.VICTORY_FSR_FRAMEGEN -eq '1') { [string]$settings.VICTORY_FRAMEGEN_X } else { '0' }
$settings.VICTORY_MENU_FG_TYPE = $FgType
$settings.VICTORY_MENU_FPS = [string]$Fps
$settings.VICTORY_MENU_FILE = $menuFile
$settings.VICTORY_MENU_PLAY = $MyInvocation.MyCommand.Path
$settings.VICTORY_MENU_ARGS = "-Exe '$($Exe -replace "'", "''")' -Build $Build -MaxTexDim $MaxTexDim -UseMenuSettings$(if ($Panel) { ' -Panel' })$(if ($NoThin) { ' -NoThin' })$(if ($HalfAmbient) { ' -HalfAmbient' })$(if ($NoFrameGenReady) { ' -NoFrameGenReady' })"

if (-not $NoLog) {
    if (-not $LogFile) {
        $logDir = Join-Path $menuDir 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $LogFile = Join-Path $logDir ('vortexbox-wave5-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
    }
}

Write-Host "=== VortexBoxBR Wave 5 (Foxhound+CGBJ) | RTX 3050 8GB + Xeon E5-2650 v3 [$Build] ==="
Write-Host "VRAM: PeakTargetRoom (PR#76) | LevelsOnDemand | MaxTexDim=${MaxTexDim}px | CardBuf 640MB | CardWin 128MB | TexRoom ${texRoom}%"
Write-Host "UPS : Console=$console | DLSS=$(if ($dlssActive) { $Dlss } else { 'OFF' }) | AMD FSR 3 FG=$(if ($fgActive -and $fxDir) { "${FrameGenX}x (HUD-less)" } elseif ($fxDir -and -not $NoFrameGenReady) { 'READY (F1)' } else { 'OFF' }) | FpsCap=$Fps"
Write-Host "GPU : EarlyDepth=1 | ThreadTicket=1 | AmbientSpecular=1 | AmbientHalf=$([bool]$HalfAmbient) | WaterLight=SKIP | LeaveOut=ON | RT=$([bool]$RayTracing)"
Write-Host "CPU : Thin=$(-not $NoThin)(8t) | WcNoBack=1 | SoftViews=copies | HeapSync(5x)+BufSpans=1 | RefreshScratch=1 | DStorage=6t | NoWatchdog=1"
Write-Host "UI  : F1 = Settings Menu (Save & Restart) | F3 = Telemetry Panel"
if ($LogFile) { Write-Host "LOG : $LogFile" }

# Clear inherited VICTORY_* switches except path overrides, then apply Wave 5 profile.
$keepPaths = 'VICTORY_CONFIG', 'VICTORY_GAME_DIR', 'VICTORY_CACHE_DIR', 'VICTORY_DATA_DIR', 'VICTORY_STREAMLINE_DIR', 'VICTORY_FIDELITYFX_DIR'
Get-ChildItem Env:VICTORY_* -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $keepPaths } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
foreach ($k in $settings.Keys) { Set-Item "Env:$k" $settings[$k] }

$writer = $null
if ($LogFile) {
    $writer = [IO.StreamWriter]::new($LogFile, $false, [Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    $switchLine = ($settings.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '
    $writer.WriteLine("# console=$console build=$Build preload=$preloadWanted switches: $switchLine")
}

$exitCode = 0
Push-Location $repo
try {
    if ($preloadWanted) {
        Write-Host 'Preloading shaders before the game starts...'
        $began = Get-Date
        $gameDir = [IO.Path]::GetDirectoryName($Exe)
        & $victory preload $gameDir 2>&1 | ForEach-Object {
            $line = "$_"
            if ($writer) { $writer.WriteLine("# preload: $line") }
            $line
        }
        $how = if ($LASTEXITCODE -eq 0) { 'done' } else { "ended with code $LASTEXITCODE" }
        $said = 'Preload {0} after {1:N1} min. Starting the game.' -f $how, ((Get-Date) - $began).TotalMinutes
        if ($writer) { $writer.WriteLine("# $said") }
        Write-Host $said
    }

    & $victory run $Exe --console $console --execute 2>&1 | ForEach-Object {
        $line = "$_"
        if ($writer) { $writer.WriteLine($line) }
        $line
    }
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
    if ($writer) { $writer.Dispose() }
}
exit $exitCode
