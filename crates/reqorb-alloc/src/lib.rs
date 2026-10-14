//! The allocator reqorb's programs use: the system's, which also keeps
//! count of the memory held by a thread that runs a script, so that a
//! script can be held to a limit.
//!
//! The script engine cannot recover from an allocation that fails: the
//! whole program would stop. So a thread that goes over its limit is not
//! refused memory. It says so, through the flag it was given, and then
//! waits for ever, allocating nothing more, while whoever was waiting for
//! it carries on. What it held until then is not given back.
//!
//! A program uses it by declaring
//!
//! ```ignore
//! #[global_allocator]
//! static ALLOCATOR: reqorb_alloc::Counting = reqorb_alloc::Counting;
//! ```
//!
//! Without that declaration [`limit`] has no effect.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// The system allocator, counting for threads under a [`limit`].
pub struct Counting;

thread_local! {
    /// How much this thread may hold; zero when it is not limited.
    static LIMIT: Cell<usize> = const { Cell::new(0) };
    /// How much this thread holds, of what it allocated while limited.
    static HELD: Cell<usize> = const { Cell::new(0) };
    /// Raised when the thread goes over its limit.
    static OVER: Cell<*const AtomicBool> = const { Cell::new(ptr::null()) };
}

/// Holds the calling thread to `bytes` of memory until the guard is
/// dropped. Going over sets `over` and stops the thread for good.
#[must_use = "the limit ends when the guard is dropped"]
pub fn limit(bytes: usize, over: Arc<AtomicBool>) -> Limit {
    HELD.with(|held| held.set(0));
    OVER.with(|flag| flag.set(Arc::as_ptr(&over)));
    LIMIT.with(|limit| limit.set(bytes.max(1)));
    Limit { _over: over }
}

/// Keeps a thread to its limit while it lives.
pub struct Limit {
    // Keeps the flag alive while the allocator may raise it.
    _over: Arc<AtomicBool>,
}

impl Drop for Limit {
    fn drop(&mut self) {
        LIMIT.with(|limit| limit.set(0));
        OVER.with(|flag| flag.set(ptr::null()));
    }
}

/// Counts `size` more bytes for this thread, and stops it if that takes it
/// over its limit.
fn take(size: usize) {
    let limit = LIMIT.with(Cell::get);
    if limit == 0 {
        return;
    }
    let held = HELD.with(|held| {
        let now = held.get().saturating_add(size);
        held.set(now);
        now
    });
    if held > limit {
        // Nothing more is counted, or this would come back here.
        LIMIT.with(|limit| limit.set(0));
        let over = OVER.with(Cell::get);
        if !over.is_null() {
            // SAFETY: the pointer is set from an `Arc` that the `Limit`
            // guard keeps alive, and the guard outlives this thread's use
            // of it, as the thread never gets past this point.
            unsafe { (*over).store(true, Ordering::Release) };
        }
        loop {
            std::thread::park();
        }
    }
}

fn give(size: usize) {
    if LIMIT.with(Cell::get) != 0 {
        HELD.with(|held| held.set(held.get().saturating_sub(size)));
    }
}

// SAFETY: every call is passed to the system allocator as it came; the
// counting around it allocates nothing.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        take(layout.size());
        // SAFETY: the caller's guarantees for `layout` are passed on.
        unsafe { System.alloc(layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        take(layout.size());
        // SAFETY: as for `alloc`.
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        give(layout.size());
        // SAFETY: `ptr` came from this allocator, which is the system's.
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if new_size > layout.size() {
            take(new_size - layout.size());
        } else {
            give(layout.size() - new_size);
        }
        // SAFETY: as for `dealloc` and `alloc`.
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[global_allocator]
    static ALLOCATOR: Counting = Counting;

    #[test]
    fn a_thread_over_its_limit_stops_and_says_so() {
        let over = Arc::new(AtomicBool::new(false));
        let flag = over.clone();
        let (done, finished) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _limit = limit(1 << 20, flag);
            // Within the limit, freed as it goes.
            for _ in 0..100 {
                drop(vec![0u8; 512 * 1024]);
            }
            let _ = done.send("within");
            let _held: Vec<Vec<u8>> = (0..8).map(|_| vec![0u8; 512 * 1024]).collect();
            let _ = done.send("past it");
        });
        assert_eq!(finished.recv().unwrap(), "within");
        std::thread::sleep(Duration::from_millis(200));
        assert!(over.load(Ordering::Acquire));
        assert!(finished.try_recv().is_err(), "it went no further");
    }

    #[test]
    fn other_threads_are_not_limited() {
        let big = vec![0u8; 64 << 20];
        assert_eq!(big.len(), 64 << 20);
    }
}
