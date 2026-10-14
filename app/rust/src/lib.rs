pub mod api;
mod frb_generated;

/// The system allocator, which also holds scripts to their memory limit.
#[global_allocator]
static ALLOCATOR: reqorb_alloc::Counting = reqorb_alloc::Counting;
