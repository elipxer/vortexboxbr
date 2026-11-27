//! Opt-in buffer uploads (`VICTORY_UPLOAD_QUEUE=1`): COPY queue -> private VRAM
//! bounce -> DIRECT queue at the original position (PR #60, adapted with total
//! live + free VRAM cap for 8 GB cards). Only DIRECT writes the title's card
//! buffers; buffers promote from COMMON and decay after ExecuteCommandLists.
use super::*;
use std::sync::atomic::AtomicU64;

pub(super) fn on() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var_os("VICTORY_UPLOAD_QUEUE").is_some_and(|v| v == "1"))
}

/// Total VRAM (in-flight + free) allowed for upload bounce buffers.
/// Defaults to 128 MiB on <= 8 GiB local budget, 256 MiB otherwise.
fn max_live_bytes(host: &Host) -> u64 {
    static CAP: OnceLock<u64> = OnceLock::new();
    *CAP.get_or_init(|| {
        if let Some(mb) = std::env::var("VICTORY_UPLOAD_QUEUE_MB")
            .ok()
            .and_then(|v| v.trim().parse::<u64>().ok())
        {
            return mb.clamp(16, 512) << 20;
        }
        let budget = host.video_memory().map_or(0, |[b, ..]| b);
        if budget != 0 && budget <= (8u64 << 30) {
            128 << 20
        } else {
            256 << 20
        }
    })
}

pub(super) struct Slot {
    allocator: ID3D12CommandAllocator,
    list: ID3D12GraphicsCommandList,
    bounce: Option<(ID3D12Resource, u64)>,
}

impl Drop for Slot {
    fn drop(&mut self) {
        if let Some((_, size)) = self.bounce.take() {
            LIVE_BYTES.fetch_sub(size, Ordering::Relaxed);
        }
    }
}

impl Slot {
    pub(super) fn bounce(&self) -> Option<&ID3D12Resource> {
        self.bounce.as_ref().map(|b| &b.0)
    }

    fn set_bounce(&mut self, new: Option<(ID3D12Resource, u64)>) {
        if let Some((_, old_size)) = self.bounce.take() {
            LIVE_BYTES.fetch_sub(old_size, Ordering::Relaxed);
        }
        if let Some((_, new_size)) = &new {
            LIVE_BYTES.fetch_add(*new_size, Ordering::Relaxed);
        }
        self.bounce = new;
    }
}

struct Queue {
    queue: ID3D12CommandQueue,
    fence: ID3D12Fence,
    sent: u64,
    free: Vec<Slot>,
}

// SAFETY: free-threaded D3D12 objects; each slot has one owning submission.
unsafe impl Send for Slot {}
// SAFETY: queue access and the free slots are serialized by QUEUE.
unsafe impl Send for Queue {}
static QUEUE: Mutex<Option<Option<Queue>>> = Mutex::new(None);
static STATS: [AtomicU64; 3] = [const { AtomicU64::new(0) }; 3];
/// Total bounce VRAM across both in-flight and pooled slots.
static LIVE_BYTES: AtomicU64 = AtomicU64::new(0);

fn make_queue(device: &ID3D12Device) -> Option<Queue> {
    // SAFETY: plain object creation.
    let made = unsafe {
        (|| -> windows::core::Result<Queue> {
            let queue = device.CreateCommandQueue(&D3D12_COMMAND_QUEUE_DESC {
                Type: D3D12_COMMAND_LIST_TYPE_COPY,
                ..Default::default()
            })?;
            let fence = device.CreateFence(0, D3D12_FENCE_FLAG_NONE)?;
            Ok(Queue {
                queue,
                fence,
                sent: 0,
                free: Vec::new(),
            })
        })()
    };
    match made {
        Ok(q) => {
            tracing::info!("VICTORY_UPLOAD_QUEUE=1: independent buffer copy queue ready");
            Some(q)
        }
        Err(e) => {
            tracing::warn!(error = %e, "upload copy queue unavailable; using original uploads");
            None
        }
    }
}

/// None means nothing was submitted; the caller must record its original uploads.
/// # Safety
/// The source's first `total` bytes are initialized and immutable until drawing finishes.
/// The caller holds drawing submission order and retains the returned slot too.
pub(super) unsafe fn send(
    host: &Host,
    drawing: &ID3D12CommandQueue,
    source: &ID3D12Resource,
    total: u64,
) -> Option<Slot> {
    let cap = max_live_bytes(host);
    if total == 0 || total > cap {
        return None;
    }
    let mut guard = QUEUE.lock().unwrap_or_else(|e| e.into_inner());
    let q = guard.get_or_insert_with(|| make_queue(&host.device)).as_mut()?;
    // SAFETY: free slots have completed their drawing fence; caller retains sources.
    let made = unsafe {
        (|| -> windows::core::Result<Option<Slot>> {
            // Pick the smallest free slot that already fits, or the last free slot.
            let idx = q
                .free
                .iter()
                .enumerate()
                .filter(|(_, s)| s.bounce.as_ref().is_some_and(|b| b.1 >= total))
                .min_by_key(|(_, s)| s.bounce.as_ref().map_or(u64::MAX, |b| b.1))
                .map(|(i, _)| i);
            let mut slot = match idx {
                Some(i) => q.free.swap_remove(i),
                None => match q.free.pop() {
                    Some(slot) => slot,
                    None => {
                        let allocator = host.device.CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_COPY)?;
                        let list: ID3D12GraphicsCommandList =
                            host.device.CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_COPY, &allocator, None)?;
                        list.Close()?;
                        Slot {
                            allocator,
                            list,
                            bounce: None,
                        }
                    }
                },
            };
            if slot.bounce.as_ref().is_none_or(|b| b.1 < total) {
                let old_size = slot.bounce.as_ref().map_or(0, |b| b.1);
                let size = total.next_power_of_two().max(4 << 20).min(cap);
                let live_without = LIVE_BYTES.load(Ordering::Relaxed).saturating_sub(old_size);
                if live_without.saturating_add(size) > cap {
                    // Evict pooled free slots to stay within the 8 GB VRAM cap.
                    while !q.free.is_empty()
                        && LIVE_BYTES.load(Ordering::Relaxed).saturating_sub(old_size).saturating_add(size) > cap
                    {
                        q.free.pop();
                    }
                }
                if LIVE_BYTES.load(Ordering::Relaxed).saturating_sub(old_size).saturating_add(size) > cap {
                    q.free.push(slot);
                    return Ok(None);
                }
                slot.set_bounce(None);
                let Some(buffer) = host.uav_buffer(size) else {
                    q.free.push(slot);
                    return Ok(None);
                };
                slot.set_bounce(Some((buffer, size)));
            }
            let bounce = slot.bounce().unwrap();
            slot.allocator.Reset()?;
            slot.list.Reset(&slot.allocator, None)?;
            slot.list.CopyBufferRegion(bounce, 0, source, 0, total);
            slot.list.Close()?;
            let list = slot.list.cast()?;
            q.queue.ExecuteCommandLists(&[Some(list)]);
            q.sent += 1;
            // After Execute, failure must never return a live slot to the pool.
            if let Err(e) = q.queue.Signal(&q.fence, q.sent) {
                fail(format_args!("upload copy queue signal failed ({e})"));
            }
            if let Err(e) = drawing.Wait(&q.fence, q.sent) {
                tracing::warn!(error = %e, "upload queue GPU wait failed; waiting on CPU");
                if let Err(e) = q.fence.SetEventOnCompletion(q.sent, HANDLE::default()) {
                    fail(format_args!("upload copy queue CPU wait failed ({e})"));
                }
            }
            STATS[0].fetch_add(1, Ordering::Relaxed);
            STATS[1].fetch_add(total, Ordering::Relaxed);
            Ok(Some(slot))
        })()
    };
    match made {
        Ok(slot) => slot,
        Err(e) => {
            tracing::warn!(error = %e, "upload queue preparation failed; using original uploads");
            None
        }
    }
}

/// Called only after the plan's DIRECT fence, which follows the COPY fence.
pub(super) fn give_back(slot: Slot) {
    let mut guard = QUEUE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(Some(q)) = guard.as_mut() {
        q.free.push(slot);
        let free_cap = host().map_or(128 << 20, max_live_bytes);
        while LIVE_BYTES.load(Ordering::Relaxed) > free_cap && !q.free.is_empty() {
            q.free.pop();
        }
    }
}

pub(super) fn fallback() {
    STATS[2].fetch_add(1, Ordering::Relaxed);
}

pub(super) fn line(frames: f64) {
    if on() {
        let [sent, bytes, fallback] = [0, 1, 2].map(|i| STATS[i].swap(0, Ordering::Relaxed) as f64 / frames);
        let live_mb = LIVE_BYTES.load(Ordering::Relaxed) >> 20;
        tracing::info!(
            "VICTORY_UPLOAD_QUEUE: {sent:.1} uploads/frame, {:.1} MB/frame, {fallback:.1} fallbacks/frame ({live_mb} MB bounce VRAM)",
            bytes / 1048576.0
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uploads_preserve_bytes_and_reuse_only_after_drawing() {
        let Some(host) = host() else {
            return;
        };
        // SAFETY: test-owned buffers; all commands finish before resources are reused.
        unsafe {
            let (source, data) = host.upload_buffer(1024).unwrap();
            let (readback, result) = host.shared_buffer(1024).unwrap();
            let card = host.uav_buffer(1024).unwrap();
            let (allocator, list) = host.make_prelude().unwrap();
            let fence: ID3D12Fence = host.device.CreateFence(0, D3D12_FENCE_FLAG_NONE).unwrap();
            assert!(send(host, &host.queue, &source, 0).is_none());
            assert!(send(host, &host.queue, &source, (512 << 20) + 1).is_none());
            for round in 1..=3u64 {
                let expected: Vec<u8> = (0..1024).map(|i| (i as u8).wrapping_mul(37).wrapping_add(round as u8)).collect();
                std::ptr::copy_nonoverlapping(expected.as_ptr(), data, 1024);
                allocator.Reset().unwrap();
                list.Reset(&allocator, None).unwrap();
                let slot = send(host, &host.queue, &source, 1024).expect("copy queue must upload");
                let bounce = slot.bounce().unwrap();
                for (dst, src, len) in [(0, 3, 13), (300, 311, 257), (600, 3, 13)] {
                    list.CopyBufferRegion(&card, dst, bounce, src, len);
                }
                list.ResourceBarrier(&[transition(&card, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COPY_SOURCE)]);
                list.CopyBufferRegion(&readback, 0, &card, 0, 1024);
                list.Close().unwrap();
                host.queue.ExecuteCommandLists(&[Some(list.cast().unwrap())]);
                host.queue.Signal(&fence, round).unwrap();
                fence.SetEventOnCompletion(round, HANDLE::default()).unwrap();
                let bytes = std::slice::from_raw_parts(result, 1024);
                assert_eq!(&bytes[..13], &expected[3..16]);
                assert_eq!(&bytes[300..557], &expected[311..568]);
                assert_eq!(&bytes[600..613], &expected[3..16]);
                give_back(slot);
            }
        }
    }
}
