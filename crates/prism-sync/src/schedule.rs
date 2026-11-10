//! When to sync.
//!
//! [`Scheduler`] decides, and does nothing else: it is a state machine fed
//! events and the time, with no clock, thread or timer of its own, so it
//! behaves the same under a test as under an app, and whoever drives it
//! chooses how to wait.
//!
//! The schedule:
//!
//! - Writing is pushed once it **pauses** for [`idle`](Schedule::idle)
//!   (thirty seconds), but never more than [`longest`](Schedule::longest)
//!   (five minutes) after it started — someone typing steadily is still
//!   backed up.
//! - A **full** sync runs when asked: at launch, on coming to the front,
//!   when the remote says it moved.
//! - **One cycle at a time.** Asking during a cycle queues one more after
//!   it — a full one, if any ask was for a full one.
//! - A cycle that **fails** for a passing reason is tried again, each
//!   wait twice the last, up to [`max_backoff`](Schedule::max_backoff).
//!
//! ```
//! use prism_sync::{Mode, Scheduler, Schedule};
//! use std::time::{Duration, Instant};
//!
//! let mut scheduler = Scheduler::new(Schedule::default());
//! let start = Instant::now();
//! scheduler.note_changed(start);
//! assert_eq!(scheduler.poll(start), None);                      // still typing
//! let later = start + Duration::from_secs(30);
//! assert_eq!(scheduler.next_wake(), Some(later));
//! assert_eq!(scheduler.poll(later), Some(Mode::Push));          // run this now
//! scheduler.finished(later, true);
//! ```

use crate::sync::Mode;
use std::time::{Duration, Instant};

/// The schedule's timings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Schedule {
    /// How long writing must pause before it is pushed.
    pub idle: Duration,
    /// The longest writing goes unpushed, however steady.
    pub longest: Duration,
    /// The first wait after a failed cycle; each later one is twice the last.
    pub min_backoff: Duration,
    pub max_backoff: Duration,
}

impl Default for Schedule {
    fn default() -> Self {
        Schedule {
            idle: Duration::from_secs(30),
            longest: Duration::from_secs(300),
            min_backoff: Duration::from_secs(5),
            max_backoff: Duration::from_secs(600),
        }
    }
}

/// Decides when a sync cycle should run. See the [module docs](self).
#[derive(Debug, Clone)]
pub struct Scheduler {
    schedule: Schedule,
    /// When the unpushed writing began.
    first_unsaved: Option<Instant>,
    /// When the pause after writing will have been long enough.
    due: Option<Instant>,
    /// A cycle asked for, to start as soon as none is running.
    pending: Option<Mode>,
    running: bool,
    /// After a failure: what to retry, when, and the wait after that.
    retry: Option<(Mode, Instant)>,
    backoff: Duration,
}

impl Scheduler {
    pub fn new(schedule: Schedule) -> Scheduler {
        Scheduler { schedule, first_unsaved: None, due: None, pending: None, running: false, retry: None, backoff: schedule.min_backoff }
    }

    /// Something was written: push it once writing pauses.
    pub fn note_changed(&mut self, now: Instant) {
        let first = *self.first_unsaved.get_or_insert(now);
        self.due = Some((now + self.schedule.idle).min(first + self.schedule.longest));
    }

    /// Asks for a cycle now — or, when one is running, straight after it.
    pub fn request(&mut self, mode: Mode) {
        self.pending = Some(match (self.pending, mode) {
            (Some(Mode::Full), _) | (_, Mode::Full) => Mode::Full,
            _ => Mode::Push,
        });
    }

    /// The cycle to start now, if one should. Answering `Some` marks it
    /// running; tell [`finished`](Self::finished) when it ends.
    pub fn poll(&mut self, now: Instant) -> Option<Mode> {
        if self.running {
            return None;
        }
        if self.due.is_some_and(|due| due <= now) {
            self.due = None;
            self.request(Mode::Push);
        }
        if let Some((mode, at)) = self.retry {
            if at <= now {
                self.retry = None;
                self.request(mode);
            }
        }
        let mode = self.pending.take()?;
        // The cycle commits everything written so far.
        self.first_unsaved = None;
        self.due = None;
        self.retry = None;
        self.running = true;
        Some(mode)
    }

    /// The running cycle ended. `ok` false means it failed for a reason
    /// that may pass (see `Error::is_transient`): it will be tried again.
    pub fn finished(&mut self, now: Instant, ok: bool) {
        self.finished_as(now, ok.then_some(()).ok_or(Mode::Full))
    }

    /// As [`finished`](Self::finished), saying which mode to retry.
    pub fn finished_as(&mut self, now: Instant, outcome: Result<(), Mode>) {
        self.running = false;
        match outcome {
            Ok(()) => self.backoff = self.schedule.min_backoff,
            Err(mode) => {
                self.retry = Some((mode, now + self.backoff));
                self.backoff = (self.backoff * 2).min(self.schedule.max_backoff);
            }
        }
    }

    /// When [`poll`](Self::poll) will next have something to start, if it
    /// is only a matter of time. `None`: nothing until the next event.
    /// A time already past means "now".
    pub fn next_wake(&self) -> Option<Instant> {
        if self.running {
            return None;
        }
        if self.pending.is_some() {
            return Some(Instant::now());
        }
        [self.due, self.retry.map(|(_, at)| at)].into_iter().flatten().min()
    }

    pub fn is_running(&self) -> bool {
        self.running
    }

    /// Whether anything is written and not yet handed to a cycle.
    pub fn has_unsaved(&self) -> bool {
        self.first_unsaved.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secs(n: u64) -> Duration {
        Duration::from_secs(n)
    }

    #[test]
    fn writing_is_pushed_once_it_pauses() {
        let mut s = Scheduler::new(Schedule::default());
        let t = Instant::now();
        assert_eq!(s.poll(t), None);
        assert_eq!(s.next_wake(), None);
        s.note_changed(t);
        s.note_changed(t + secs(10)); // still typing: the pause starts over
        assert_eq!(s.poll(t + secs(30)), None);
        assert_eq!(s.next_wake(), Some(t + secs(40)));
        assert!(s.has_unsaved());
        assert_eq!(s.poll(t + secs(40)), Some(Mode::Push));
        assert!(s.is_running() && !s.has_unsaved());
        s.finished(t + secs(41), true);
        assert_eq!(s.poll(t + secs(100)), None);
    }

    #[test]
    fn steady_writing_is_pushed_after_the_longest_wait() {
        let mut s = Scheduler::new(Schedule::default());
        let t = Instant::now();
        for second in (0..=295).step_by(5) {
            s.note_changed(t + secs(second));
            assert_eq!(s.poll(t + secs(second)), None, "at {second}s");
        }
        assert_eq!(s.next_wake(), Some(t + secs(300)));
        assert_eq!(s.poll(t + secs(300)), Some(Mode::Push));
    }

    #[test]
    fn one_cycle_at_a_time_and_asks_coalesce() {
        let mut s = Scheduler::new(Schedule::default());
        let t = Instant::now();
        s.request(Mode::Full);
        assert_eq!(s.poll(t), Some(Mode::Full));
        // Asked three times while running: one more cycle, the fullest.
        s.request(Mode::Push);
        s.request(Mode::Full);
        s.request(Mode::Push);
        s.note_changed(t);
        assert_eq!(s.poll(t + secs(60)), None);
        assert_eq!(s.next_wake(), None);
        s.finished(t + secs(61), true);
        assert_eq!(s.poll(t + secs(61)), Some(Mode::Full));
        s.finished(t + secs(62), true);
        // The writing noted meanwhile was taken by that cycle.
        assert_eq!(s.poll(t + secs(500)), None);
    }

    #[test]
    fn failures_are_retried_with_growing_waits() {
        let mut s = Scheduler::new(Schedule { min_backoff: secs(5), max_backoff: secs(15), ..Schedule::default() });
        let mut t = Instant::now();
        s.request(Mode::Push);
        let mut waits = Vec::new();
        for _ in 0..4 {
            let mode = s.poll(t).expect("a cycle to run");
            s.finished_as(t, Err(mode));
            let wake = s.next_wake().expect("a retry");
            assert_eq!(s.poll(wake - Duration::from_millis(1)), None);
            waits.push(wake - t);
            t = wake;
        }
        assert_eq!(waits, [secs(5), secs(10), secs(15), secs(15)]);
        // A success puts the wait back.
        assert_eq!(s.poll(t), Some(Mode::Push));
        s.finished(t, true);
        s.request(Mode::Push);
        s.poll(t);
        s.finished(t, false);
        assert_eq!(s.next_wake(), Some(t + secs(5)));
        // A retry after a failure is a full cycle unless said otherwise.
        assert_eq!(s.poll(t + secs(5)), Some(Mode::Full));
    }

    #[test]
    fn a_request_supersedes_a_pending_retry() {
        let mut s = Scheduler::new(Schedule::default());
        let t = Instant::now();
        s.request(Mode::Push);
        s.poll(t);
        s.finished(t, false);
        s.request(Mode::Full);
        assert_eq!(s.poll(t), Some(Mode::Full));
        s.finished(t, true);
        assert_eq!(s.next_wake(), None);
    }
}
