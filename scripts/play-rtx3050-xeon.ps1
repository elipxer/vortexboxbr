# Tuned launcher for Intel Xeon E5-2650 v3 (10c/20t Haswell) + NVIDIA RTX 3050 8 GB (PCIe 3.0 x8, ReBAR off) + 32 GB RAM.
#   scripts\play-rtx3050-xeon.ps1 [-Resolution 480|540|720] [-Quality] [-Thin] [-Panel] [-SmoothMotion] [-LegacySubmit]
param(
    [string]$Exe = 'C:\GTA.6.Recomp-InsaneRamZes\Game\game_scarlett_master.exe',
    [ValidateSet('1080', '720', '540', '480')][string]$Resolution = '540',
    [switch]$Quality,
    [switch]$Thin,
    [switch]$Panel,
    [switch]$SmoothMotion,
    [switch]$RayTracing,
    [switch]$LegacySubmit,
    [string]$LogFile,
    [switch]$NoLog,
    [ValidateSet('diag', 'release')][string]$Build = 'release',
    [hashtable]$More = @{}
)

if (-not $NoLog) {
    if (-not $LogFile) {
        $logDir = Join-Path $env:LOCALAPPDATA 'victory\logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $LogFile = Join-Path $logDir ("run-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
    }
}

$tuned = @{
    # Fix: keep the dedicated submission thread + submission joining active even when VICTORY_THIN=0.
    VICTORY_ASYNC_SUBMIT = '1'
    VICTORY_NO_WATCHDOG = '1'
    # Restore guest streaming-thread priorities (0 left them at IDLE/LOWEST causing 1+ second load lag under load).
    VICTORY_TITLE_PRIORITIES = '1'
    # 8 GB VRAM + PCIe 3.0 x8 tuning (7.1 GB WDDM budget):
    # - Allocate texture mip levels on demand (now fixed in resource.rs:2494 so pool no longer hijacks reserved textures!).
    # - Keep texture room at 85% (~6.0 GB) so render targets + driver + DWM stay strictly below 7.1 GB (zero PCIe paging).
    # - Keep hot small buffers (>= 64 KiB, cap 768 MiB) in VRAM with 1800 MiB reserved for Series S render targets.
    VICTORY_LEVELS_ON_DEMAND = '1'
    VICTORY_CARD_BUFFERS_MIN_KB = '64'
    VICTORY_CARD_BUFFERS_MB = '768'
    VICTORY_CARD_ROOM_FOR_TARGETS_MB = '1800'
    VICTORY_TEXTURE_ROOM_PERCENT = '85'
    # Xeon E5-2650 v3 (10c/20t Haswell, 25 MB L3) right-sized worker pools:
    # - Avoid 75-thread oversubscription and spin-wait CPU burn across 10 physical cores.
    VICTORY_DSTORAGE_THREADS = '6'
    VICTORY_LAND_THREADS = '3'
    VICTORY_UNDER_THREADS = '4'
    VICTORY_VIEW_THREADS = '3'
    VICTORY_WIDE_THREADS = '4'
    VICTORY_WIDE_SPIN = '0'
    VICTORY_LAND_SKIP = '1'
    VICTORY_PIPELINE_WORKERS = '3'
}
if (-not $LegacySubmit) {
    # Ported submit-thread and descriptor optimizations (stellarr-studio/kelvaroq 0053 & 0055):
    # - Reuse thread-local write-watch scratch buffers and skip ask_ahead range builds under kept askings.
    # - Merge short clean read-only gaps (<= 4 blocks) to cut VirtualProtect kernel calls.
    # - Split >= 2 MiB contiguous shadow reads across a dedicated helper lane.
    # - Coalesce pure card upload lists into the consumer ExecuteCommandLists call.
    # - Maintain per-buffer heap view spans incrementally instead of scanning all ~83k slots every frame.
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
foreach ($k in $More.Keys) { $tuned[$k] = $More[$k] }

$pass = @{
    Exe = $Exe
    Resolution = $Resolution
    Build = $Build
    WindowsBarMB = [uint32]0
    LevelsOnDemand = $true
    More = $tuned
}
if (-not $SmoothMotion) { $pass.NoSmoothMotion = $true }
if ($Quality) { $pass.Quality = $true }
if ($Thin) { $pass.Thin = $true }
if ($Panel) { $pass.Panel = $true }
if ($RayTracing) { $pass.RayTracing = $true }

Write-Host "=== VortexBox RTX 3050 8GB + Xeon E5-2650 v3 (10c/20t) Profile ($Build) ==="
Write-Host "VRAM: Levels-On-Demand ON (fixed!) | Card Buffers >=64KB (cap 768MB) | Targets Room 1800MB | Texture Room 85%"
Write-Host "CPU : Async Submit ON | Thin=$([bool]$Thin) | Wide/Under=4t Land/View=3t DStorage=6t | Spin=0 | TitlePrio=1 | Watchdog=OFF"
Write-Host "OPT : Kelvaroq 0053+0055=$(if ($LegacySubmit) { 'OFF (-LegacySubmit)' } else { 'ON (Scratch/BatchGuards/SplitCopy/BatchUploads/BufferSpans)' })"
if ($LogFile) { Write-Host "LOG : $LogFile" }
& "$PSScriptRoot\play-nvidia.ps1" @pass
exit $LASTEXITCODE
