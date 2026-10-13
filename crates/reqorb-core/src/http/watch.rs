//! Following a send while it is under way, and stopping it.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tokio::sync::Notify;

use crate::Header;

/// What a send reports before it is finished.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SendEvent {
    /// A response has begun: its status line and headers are in. A redirect
    /// or an authorization round trip begins one of its own, so the last
    /// `Head` is the one the body that follows belongs to.
    Head {
        status: u16,
        status_text: String,
        http_version: String,
        headers: Vec<Header>,
    },
    /// More of the body has arrived. `text` is the new part, empty when the
    /// body is not text; `received` counts every byte so far.
    Body { text: String, received: u64 },
}

/// Lets whoever started a send stop it. A send stopped while its body is
/// arriving ends with the part that had arrived; one stopped earlier ends
/// with [`crate::Error::Cancelled`].
#[derive(Clone, Default)]
pub struct Cancel(Arc<(AtomicBool, Notify)>);

impl Cancel {
    pub fn cancel(&self) {
        self.0.0.store(true, Ordering::SeqCst);
        self.0.1.notify_waiters();
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.0.load(Ordering::SeqCst)
    }

    /// Completes once the send has been cancelled.
    pub(crate) async fn cancelled(&self) {
        loop {
            let notified = self.0.1.notified();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }
}

/// How a send is followed: where its progress goes, and what can stop it.
#[derive(Clone, Default)]
pub struct Watch {
    progress: Option<Arc<dyn Fn(SendEvent) + Send + Sync>>,
    pub cancel: Cancel,
}

impl Watch {
    /// Reports progress to `progress`, and stops when `cancel` says so.
    pub fn new(progress: impl Fn(SendEvent) + Send + Sync + 'static, cancel: Cancel) -> Self {
        Self {
            progress: Some(Arc::new(progress)),
            cancel,
        }
    }

    pub(crate) fn watched(&self) -> bool {
        self.progress.is_some()
    }

    pub(crate) fn report(&self, event: SendEvent) {
        if let Some(progress) = &self.progress {
            progress(event);
        }
    }
}

/// Turns the bytes of a body into text as they arrive, holding back a
/// character that a chunk ends in the middle of.
#[derive(Default)]
pub(crate) struct TextStream {
    pending: Vec<u8>,
}

impl TextStream {
    pub(crate) fn push(&mut self, chunk: &[u8]) -> String {
        self.pending.extend_from_slice(chunk);
        let mut out = String::new();
        loop {
            match std::str::from_utf8(&self.pending) {
                Ok(text) => {
                    out.push_str(text);
                    self.pending.clear();
                    return out;
                }
                Err(e) => {
                    let valid = e.valid_up_to();
                    out.push_str(std::str::from_utf8(&self.pending[..valid]).unwrap());
                    match e.error_len() {
                        // Bytes that are no character at all.
                        Some(bad) => {
                            out.push('\u{fffd}');
                            self.pending.drain(..valid + bad);
                        }
                        // The start of a character whose end is still to come.
                        None => {
                            self.pending.drain(..valid);
                            return out;
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_is_not_cut_in_the_middle_of_a_character() {
        let mut stream = TextStream::default();
        let bytes = "aé€😀".as_bytes();
        let mut out = String::new();
        for byte in bytes {
            let part = stream.push(&[*byte]);
            assert!(!part.contains('\u{fffd}'));
            out.push_str(&part);
        }
        assert_eq!(out, "aé€😀");
        assert_eq!(stream.push(&[b'x', 0xff, b'y']), "x\u{fffd}y");
    }
}
