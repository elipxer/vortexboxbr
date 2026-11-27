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
    [ValidateSet('diag', 'release')][string]$Build = 'diag',
    [hashtable]$More = @{}
)

$tuned = @{
    # Fix: keep the dedicated submission thread + submission joining active even when VICTORY_THIN=0.
    VICTORY_ASYNC_SUBMIT = '1'
    VICTORY_NO_WATCHDOG = '1'
    # 8 GB VRAM + PCIe 3.0 x8 tuning:
    # - Allocate texture mip levels on demand (~2.2-3.1 GB VRAM saved).
    # - Move small buffers (>= 64 KiB) to VRAM to avoid PCIe 3.0 x8 bus stalls and DDR4-2133 CPU compares.
    # - Right-size card buffer & Series S render-target reservations for an 8 GB WDDM budget (~7.2 GB).
    VICTORY_LEVELS_ON_DEMAND = '1'
    VICTORY_CARD_BUFFERS_MIN_KB = '64'
    VICTORY_CARD_BUFFERS_MB = '1024'
    VICTORY_CARD_ROOM_FOR_TARGETS_MB = '1800'
    VICTORY_TEXTURE_ROOM_PERCENT = '94'
    # Xeon E5-2650 v3 (10c/20t Haswell) thread tuning:
    # - Spread landing, refreshes, descriptor mirroring and under-write merges across spare physical cores.
    # - Short spin wait (50 us) avoids ~5 ms/frame Windows condvar wake latency across ~95 wakes/frame.
    # - Skip redundant read-backs already covered by a later fetch (VICTORY_LAND_SKIP=1).
    # - Cap runtime background pipeline compilers to 6 threads so they don't thrash the 25 MB L3 cache during gameplay.
    VICTORY_LAND_THREADS = '6'
    VICTORY_UNDER_THREADS = '8'
    VICTORY_VIEW_THREADS = '6'
    VICTORY_WIDE_THREADS = '8'
    VICTORY_WIDE_SPIN = '50'
    VICTORY_LAND_SKIP = '1'
    VICTORY_PIPELINE_WORKERS = '6'
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

Write-Host "=== RTX 3050 8GB + Xeon E5-2650 v3 (10c/20t) Tuned Profile ==="
Write-Host "VRAM: Levels-On-Demand ON | Card Buffers >=64KB (cap 1024MB) | Targets Room 1800MB | Texture Room 94%"
Write-Host "CPU : Async Submit ON | Thin=$([bool]$Thin) | Wide/Under=8t Land/View=6t | Spin=50us | Watchdog=OFF"
Write-Host "OPT : Kelvaroq 0053+0055=$(if ($LegacySubmit) { 'OFF (-LegacySubmit)' } else { 'ON (Scratch/BatchGuards/SplitCopy/BatchUploads/BufferSpans)' })"
& "$PSScriptRoot\play-nvidia.ps1" @pass
exit $LASTEXITCODE
