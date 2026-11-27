//! Display profile and FidelityFX upscaler path patches for the supported
//! retail image (GTA VI 1.0.2.1):
//! - `prepare`: 2560x1440 SDR display for Series X (`VICTORY_NATIVE_1440P=1`,
//!   `VICTORY_RENDER_1080P=1`).
//! - `prepare_upscaler`: selects renderer 7 (FidelityFX upscaler path) with
//!   the chosen `Mode` scale (`quality`, `balanced`, `performance`,
//!   `ultraperformance`, `dlaa`) so DLSS Super Resolution and AMD FSR 3 Frame
//!   Generation can intercept `ffxDispatch` cleanly.
//!
//! Ported from DexNom's fork / trustno1-coder/VIctory-NVIDIA (`native_1440p.rs`,
//! GPL-3.0-or-later). Uses `victory_hle::tiled_scanout_pool_bytes` so
//! `apps/victory` needs no direct `victory-formats` dependency (preserving
//! `Cargo.lock` and the shader translation cache key).

use anyhow::{Context, Result, ensure};
use victory_hle::streamline::Mode;
use victory_loader::PreparedImage;

const RETAIL_BUILD: &str = "b99f876b74d4a77f03af5f878223b27bd647b5c35a79d5decd9f716504239e93";
pub(super) const WIDTH: u32 = 2560;
pub(super) const HEIGHT: u32 = 1440;
const SDR_MODE: u32 = 0x0615_c100;
const STOCK_SDR_MODE: [u8; 16] = [0, 15, 0, 0, 112, 8, 0, 0, 60, 0, 0, 0, 1, 0, 0, 0];
const SCANOUT_RESERVATION: u32 = 0x0247_ad4a;
const TEMPORAL_SCALE: u32 = 0x028f_1e7e;
const UI_VIEWPORT_LOAD: u32 = 0x0580_48d4;

/// Patches `image` for a 2560x1440 output; the scene is drawn at 2560x1440,
/// or at 1920x1080 with `render_1080p`. Returns the scene's size.
pub(super) fn prepare(image: &mut PreparedImage, render_1080p: bool) -> Result<(u32, u32)> {
    ensure!(
        image.original_hash.to_hex().as_str() == RETAIL_BUILD,
        "1440p output is only known for the retail build {RETAIL_BUILD}"
    );

    let mode = field::<16>(image, SDR_MODE)?;
    ensure!(*mode == STOCK_SDR_MODE, "unexpected Series X SDR mode");
    mode[..4].copy_from_slice(&WIDTH.to_le_bytes());
    mode[4..8].copy_from_slice(&HEIGHT.to_le_bytes());

    let pool_size = victory_hle::tiled_scanout_pool_bytes(WIDTH, HEIGHT)
        .context("1440p scanout layout")?;
    let reservation = field::<5>(image, SCANOUT_RESERVATION)?;
    ensure!(*reservation == [0xb9, 0, 0, 0, 4], "unexpected Series X scanout reservation");
    reservation[1..].copy_from_slice(&pool_size.to_le_bytes());

    let scale = field::<4>(image, TEMPORAL_SCALE)?;
    ensure!(*scale == (2.0f32 / 3.0).to_le_bytes(), "unexpected Series X temporal scene scale");
    let (render_width, render_height) = if render_1080p { (1920, 1080) } else { (WIDTH, HEIGHT) };
    *scale = (render_width as f32 / WIDTH as f32).to_le_bytes();

    let viewport = field::<8>(image, UI_VIEWPORT_LOAD)?;
    ensure!(
        *viewport == [0xc5, 0xfb, 0x10, 0x0d, 0x10, 0xf0, 0x13, 0x05],
        "unexpected Settings viewport size load"
    );
    let displacement = (SDR_MODE as i32) - (UI_VIEWPORT_LOAD as i32 + 8);
    viewport[4..].copy_from_slice(&displacement.to_le_bytes());
    Ok((render_width, render_height))
}

const RENDERER_SELECTION: u32 = 0x007e_9421;
const STOCK_RENDERER_SELECTION: [u8; 8] = [0xb8, 6, 0, 0, 0, 0x0f, 0x45, 0xc1];
const UPSCALER_SIZING: u32 = 0x028e_f69a;
const STOCK_UPSCALER_SIZING: [u8; 14] = [0x0f, 0xb6, 0xc0, 0x41, 0x89, 0x86, 0x90, 0, 0, 0, 0x84, 0xc0, 0x75, 0x0a];
const NATIVE_LOAD: u32 = 0x028e_f6a8;
const STOCK_NATIVE_LOAD: [u8; 10] = [0xc5, 0xfa, 0x10, 0x05, 0x28, 0x78, 0x6d, 0x03, 0xeb, 0x08];
const SCALED_LOAD: u32 = 0x028e_f6b2;
const STOCK_SCALED_LOAD: [u8; 8] = [0xc5, 0xfa, 0x10, 0x05, 0xa2, 0xe2, 0x86, 0x03];
const UPSCALER_SCALE: u32 = 0x0615_d95c;

/// Makes the title render through its FidelityFX upscaler path (renderer 7)
/// with the scene at `mode`'s scale of the output, so that DLSS Super
/// Resolution and AMD FSR 3 Frame Generation intercept `ffxDispatch`.
pub(super) fn prepare_upscaler(image: &mut PreparedImage, mode: Mode) -> Result<()> {
    ensure!(
        image.original_hash.to_hex().as_str() == RETAIL_BUILD,
        "the upscaler path is only known for the retail build {RETAIL_BUILD}"
    );
    ensure!(*field::<8>(image, RENDERER_SELECTION)? == STOCK_RENDERER_SELECTION, "unexpected renderer selection");
    ensure!(*field::<14>(image, UPSCALER_SIZING)? == STOCK_UPSCALER_SIZING, "unexpected upscaler render size selection");
    ensure!(*field::<10>(image, NATIVE_LOAD)? == STOCK_NATIVE_LOAD, "unexpected upscaler native scale load");
    ensure!(*field::<8>(image, SCALED_LOAD)? == STOCK_SCALED_LOAD, "unexpected upscaler scaled load");
    ensure!(*field::<4>(image, UPSCALER_SCALE)? == (2.0f32 / 3.0).to_le_bytes(), "unexpected upscaler scale");
    let temporal = f32::from_le_bytes(*field::<4>(image, TEMPORAL_SCALE)?);
    ensure!(
        temporal == 2.0 / 3.0 || temporal == 1.0,
        "unexpected temporal scene scale {temporal} (stock 2/3, or 1 with the 1440p output)"
    );
    *field::<8>(image, RENDERER_SELECTION)? = [0xb8, 7, 0, 0, 0, 0x90, 0x90, 0x90];
    *field::<14>(image, UPSCALER_SIZING)? = [0xb8, mode.ffx_mode(), 0, 0, 0, 0x41, 0x89, 0x86, 0x90, 0, 0, 0, 0xeb, 0x0a];
    if mode != Mode::Quality {
        let literal = NATIVE_LOAD + 4;
        *field::<4>(image, literal)? = mode.scale().to_le_bytes();
        let displacement = literal as i32 - (SCALED_LOAD as i32 + 8);
        *field::<4>(image, SCALED_LOAD + 4)? = displacement.to_le_bytes();
    }
    *field::<4>(image, TEMPORAL_SCALE)? = mode.scale().to_le_bytes();
    Ok(())
}

fn field<const N: usize>(image: &mut PreparedImage, rva: u32) -> Result<&mut [u8; N]> {
    let offset = image.info.rva_to_file_offset(rva).context("display profile field missing")? as usize;
    image
        .bytes
        .get_mut(offset..offset + N)
        .context("incomplete display profile field")?
        .try_into()
        .context("invalid display profile field length")
}
