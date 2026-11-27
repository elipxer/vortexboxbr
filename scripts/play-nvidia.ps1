# Starts the title on an NVIDIA card with the Series S settings (VortexBox).
#   scripts\play-nvidia.ps1 -Exe <path of your own copy's executable>
# -NoSmoothMotion  run target\<build>\victory.exe itself (required for DLSS/FSR Frame Generation).
# -SeriesX         the Series X profile instead (slower)
# -Quality         fewer stretched/jumping bodies and less rainbow skin, slower
# -RayTracing      keep the title's ray-tracing passes (off by default)
# -Thin            enable deferred command-list recording (VICTORY_THIN=1)
# -LevelsOnDemand  allocate texture mips on demand (VICTORY_LEVELS_ON_DEMAND=1)
# -Panel           show the on-screen FPS / CPU / GPU / VRAM telemetry panel on start (F3 toggles anytime)
# -Dlss            NVIDIA DLSS Super Resolution via Streamline: off, dlaa, quality, balanced, performance, ultraperformance
# -FsrFrameGen     AMD FSR 3 Frame Generation 2x (works on RTX 20/30/40/50 without HAGS; HUD-less via two-plane compose)
# -FrameGen        Enable frame generation (auto: DLSS FG on RTX 40/50 with HAGS, else FSR 3 FG 2x)
# -FrameGenX       Frame generation multiplier (2..6; FSR 3 uses 2)
# -FgType          auto, dlss, or fsr
# -Fps             Target frame-clock cap (1..1000; 1000 = uncapped)
# -Resolution      Height when DLSS/FSR-FG are off (title's own upscaler): 2160, 1440, 1080, 720, 540, 480, 420, 360
# -Adapter         GPU selector (substring or '#index')
# -Build           diag or release
# -WindowsBarMB    Max MiB of title memory windows in CPU-mapped VRAM
# -More            Additional or override VICTORY_* switches
param(
    [Parameter(Mandatory)][string]$Exe,
    [switch]$NoSmoothMotion,
    [switch]$SeriesX,
    [switch]$Quality,
    [switch]$RayTracing,
    [switch]$Thin,
    [switch]$LevelsOnDemand,
    [switch]$Panel,
    [ValidateSet('off', 'dlaa', 'quality', 'balanced', 'performance', 'ultraperformance')][string]$Dlss = 'off',
    [switch]$FsrFrameGen,
    [switch]$FrameGen,
    [ValidateRange(2, 6)][int]$FrameGenX = 2,
    [ValidateSet('auto', 'dlss', 'fsr')][string]$FgType = 'auto',
    [ValidateRange(0, 1000)][int]$Fps = 0,
    [ValidateSet('2160', '1440', '1080', '720', '540', '480', '420', '360')][string]$Resolution,
    [string]$Adapter,
    [ValidateSet('diag', 'release')][string]$Build = 'diag',
    [hashtable]$More = @{},
    [uint32]$WindowsBarMB
)
$repo = Split-Path $PSScriptRoot -Parent
$settings = @{
    # This fork's play set: the speed set.
    VICTORY_TEXTURE_NO_WAIT = '1'; VICTORY_RELAY = '2'; VICTORY_CARD_STEPS = '2'
    VICTORY_WIDE_BACK = '1'; VICTORY_CARD_REHASH_RUNS = '1'
    VICTORY_JOIN_COPIES = '1'; VICTORY_INDIRECT_WINDOW = '1'; VICTORY_RELAY_COPY = '1'
    VICTORY_INDIRECT_BATCH = '2'; VICTORY_MAP_THREADS = '1'; VICTORY_TITLE_PRIORITIES = '0'; VICTORY_CARD_AWAKE = '1'
    VICTORY_SHOW_AFTER = '1'; VICTORY_AMBIENT = '0.8'; VICTORY_D3D12_DRED = 'light'; VICTORY_SKIP_PIPELINES = 'none'
    # Keep async submission enabled explicitly so VICTORY_THIN='0' does not disable the submit thread or VICTORY_JOIN_PARTS.
    VICTORY_ASYNC_SUBMIT = '1'
    # Prevent the title's 30s GPU watchdog from killing the process during slow first-run shader compiles.
    VICTORY_NO_WATCHDOG = '1'
    VICTORY_THIN = '0'; VICTORY_JOIN_PARTS = '8'; VICTORY_UPLOAD_AHEAD = '1'
    # Cheap picture fixes:
    VICTORY_AMBIENT_AIR = '1.5'; VICTORY_AMBIENT_MOST = '2'
    VICTORY_NAN_SCRUB = '1'
    VICTORY_PIPELINE_WAIT_MS = '10000'
    # NVIDIA 1M shader-visible view heap cap:
    VICTORY_DYNAMIC_SLOTS = '524288'
    # Ray walks end at the root while the structure builder is off:
    VICTORY_BVH_MISS = '1'
    # Memory compares on the card instead of the CPU:
    VICTORY_CARD_BUFFERS_MIN_MB = '1'; VICTORY_CARD_BUFFERS_MB = '1536'
    # Series S presents the interface as a second plane (also supplies HUD-less colour to FSR 3 FG!):
    VICTORY_COMPOSE = '1'
}
$rtList = Join-Path $PSScriptRoot 'rt_off_hashes.txt'
if (-not $RayTracing -and (Test-Path -LiteralPath $rtList -PathType Leaf)) {
    $settings.VICTORY_SKIP_PIPELINES = (Get-Content -LiteralPath $rtList -Raw).Trim()
}
if ($Quality) {
    $settings.VICTORY_RELAY = '1'; $settings.VICTORY_CARD_STEPS = '0'; $settings.VICTORY_TEXTURE_NO_WAIT = '0'
}
if ($Thin) { $settings.VICTORY_THIN = '1' }
if ($LevelsOnDemand) { $settings.VICTORY_LEVELS_ON_DEMAND = '1' }
if ($Panel) { $settings.VICTORY_PANEL = '1' }

$outHeight = if ($SeriesX) { 2160 } else { 1080 }
$console = if ($SeriesX) { 'X' } else { 'S' }

# Upscaler / Frame Generation path (renderer 7 FidelityFX interpose) vs legacy title upscaler (renderer 6).
$wantFg = $FsrFrameGen -or $FrameGen
$wantDlss = $Dlss -ne 'off'
$usingFfxPath = $false

if ($wantDlss) {
    $slCandidates = @(
        $env:VICTORY_STREAMLINE_DIR,
        (Join-Path $env:LOCALAPPDATA 'victory\nvidia-sdk\Streamline\bin\x64'),
        (Join-Path $repo 'nvidia-sdk\Streamline\bin\x64')
    ) | Where-Object { $_ }
    $sl = $slCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'sl.interposer.dll') -PathType Leaf } | Select-Object -First 1
    if ($sl) {
        $settings.VICTORY_DLSS = '1'
        $settings.VICTORY_DLSS_MODE = $Dlss
        $settings.VICTORY_STREAMLINE_DIR = $sl
        $usingFfxPath = $true
        if ($FrameGen -and -not $FsrFrameGen -and $FgType -ne 'fsr') {
            $settings.VICTORY_FRAMEGEN = '1'
            $settings.VICTORY_FRAMEGEN_X = [string]$FrameGenX
        }
    } else {
        Write-Host "WARNING: sl.interposer.dll not found (run Get-NVIDIA-DLSS.cmd or set VICTORY_STREAMLINE_DIR); falling back without DLSS."
    }
}

if ($FsrFrameGen -or ($FrameGen -and $FgType -ne 'dlss')) {
    $fxCandidates = @(
        $env:VICTORY_FIDELITYFX_DIR,
        (Join-Path $env:LOCALAPPDATA 'victory\fidelityfx'),
        (Join-Path $repo 'amd-sdk\FidelityFX\bin')
    ) | Where-Object { $_ }
    $fx = $fxCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'amd_fidelityfx_loader_dx12.dll') -PathType Leaf } | Select-Object -First 1
    if ($fx) {
        $settings.VICTORY_FSR_FRAMEGEN = '1'
        $settings.VICTORY_FIDELITYFX_DIR = $fx
        $settings.VICTORY_FRAMEGEN_X = [string]$FrameGenX
        $settings.VICTORY_FRAMEGEN_HUDLESS = '1'
        if ($FsrFrameGen -or $FgType -eq 'fsr') {
            $settings.Remove('VICTORY_FRAMEGEN')
        }
        if (-not $settings.ContainsKey('VICTORY_DLSS_MODE')) {
            $settings.VICTORY_DLSS_MODE = if ($wantDlss) { $Dlss } else { 'performance' }
        }
        $usingFfxPath = $true
    } else {
        Write-Host "WARNING: amd_fidelityfx_loader_dx12.dll not found (set VICTORY_FIDELITYFX_DIR); running without AMD FSR 3 FG."
    }
}

if (-not $usingFfxPath) {
    # Legacy renderer 6 (title's own temporal upscaler)
    $settings.VICTORY_RENDER_SCALE = '0.5'
    $settings.VICTORY_OWN_UPSCALER = '1'
    if ($Resolution) {
        if ([int]$Resolution -gt $outHeight) {
            Write-Host "Series $console outputs ${outHeight}p: ${Resolution}p is above it."
            exit 1
        }
        $settings.VICTORY_RENDER_SCALE = ([int]$Resolution / $outHeight).ToString('0.####', [Globalization.CultureInfo]::InvariantCulture)
    }
}

if ($Fps -gt 0) {
    $settings.VICTORY_FRAME_INTERVAL_US = [string][int][math]::Round(1000000 / $Fps)
}
if ($Adapter) { $settings.VICTORY_ADAPTER = $Adapter }
if ($PSBoundParameters.ContainsKey('WindowsBarMB')) {
    $settings.VICTORY_WINDOWS_BAR_MB = $WindowsBarMB.ToString([Globalization.CultureInfo]::InvariantCulture)
} else {
    $ram = try { (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory } catch { 0 }
    if ($ram -gt 0 -and $ram -lt 24GB) {
        $settings.VICTORY_WINDOWS_BAR_MB = '3072'
        Write-Host "$([math]::Round($ram / 1GB)) GB of RAM: title memory windows in the card's memory the CPU maps, up to 3 GB (-WindowsBarMB 0 turns this off)"
    }
}
foreach ($k in $More.Keys) {
    if ($null -eq $More[$k] -or $More[$k] -eq '') {
        $settings.Remove($k)
    } else {
        $settings[$k] = $More[$k]
    }
}

# Re-check whether DLSS/FSR-FG are active after -More overrides; never leave legacy renderer 6 active alongside renderer 7!
if ($settings.VICTORY_DLSS -eq '1' -or $settings.VICTORY_FRAMEGEN -eq '1' -or $settings.VICTORY_FSR_FRAMEGEN -eq '1' -or $settings.VICTORY_FSR_PATH -eq '1') {
    $settings.Remove('VICTORY_OWN_UPSCALER')
    $settings.Remove('VICTORY_RENDER_SCALE')
    $dlssDesc = if ($settings.VICTORY_DLSS -eq '1') { "DLSS $($settings.VICTORY_DLSS_MODE)" } else { 'FidelityFX path' }
    $fgDesc = if ($settings.VICTORY_FSR_FRAMEGEN -eq '1') { " + AMD FSR 3 FG $($settings.VICTORY_FRAMEGEN_X)x" }
              elseif ($settings.VICTORY_FRAMEGEN -eq '1') { " + DLSS FG $($settings.VICTORY_FRAMEGEN_X)x" }
              else { '' }
    Write-Host "Series $console, ${outHeight}p output via $dlssDesc$fgDesc"
} elseif ($settings.ContainsKey('VICTORY_RENDER_SCALE')) {
    $scale = [double]::Parse($settings.VICTORY_RENDER_SCALE, [Globalization.CultureInfo]::InvariantCulture)
    Write-Host "Series $console, rendering at $([int]($outHeight * $scale))p (render scale $($settings.VICTORY_RENDER_SCALE))"
}

$victory = Join-Path $PSScriptRoot "..\target\$Build\victory.exe"
if (-not (Test-Path -LiteralPath $victory -PathType Leaf)) { Write-Host "No $victory. Build it first (README.md)."; exit 1 }
if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { Write-Host "No $Exe."; exit 1 }
if (-not $NoSmoothMotion -and -not $wantFg) {
    $sm = Join-Path (Split-Path $victory) 'victory_sm.exe'
    if (-not (Test-Path -LiteralPath $sm -PathType Leaf) -or (Get-Item -LiteralPath $sm).LastWriteTime -lt (Get-Item -LiteralPath $victory).LastWriteTime) {
        Copy-Item -LiteralPath $victory -Destination $sm -Force -ErrorAction Stop
    }
    $victory = $sm
}
# (Other settings left over in this window go; where your files are stays.)
$paths = 'VICTORY_CONFIG', 'VICTORY_GAME_DIR', 'VICTORY_CACHE_DIR', 'VICTORY_DATA_DIR', 'VICTORY_STREAMLINE_DIR', 'VICTORY_FIDELITYFX_DIR'
Get-ChildItem Env:VICTORY_* -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin $paths } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
foreach ($k in $settings.Keys) { Set-Item "Env:$k" $settings[$k] }
$Exe = (Resolve-Path -LiteralPath $Exe).Path
$runArgs = @('run', $Exe, '--execute')
if (-not $SeriesX) { $runArgs += @('--console', 'series-s') }
Push-Location -LiteralPath $repo   # victory.toml is looked for here
try {
    & $victory @runArgs
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $exitCode
