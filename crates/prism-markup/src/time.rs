//! Time blocks: list items that start with a time.
//!
//! A row that starts with a time, or a span of them — `9:00–10:30 Deep
//! work`, `11am Standup`, `14:00 to 15:30 Review` — is a **time block**,
//! and a list whose every item starts so is a **timeline**: a day laid
//! out, each item lasting as long as it says, or until the next begins.
//! Nothing but the words says so: a time block is Markdown any reader
//! shows as the list item it is.
//!
//! [`TimeStamp`] reads the time a text starts with and writes one the
//! same way; [`find`] finds a document's timelines; [`new_block`] and
//! [`next_block`] write a new block among them. What an editor draws of a
//! timeline — a line down its blocks, each one's time and length over its
//! words — is worked out from these by [`crate::Session::time_marks`].
//!
//! Times are minutes from midnight. Offsets are bytes.

use crate::block::{Block, BlockKind, Document, Item, Marker, Task};
use crate::outline::{self, Path};

/// How a stamp was written, to write another so.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StampStyle {
    /// `9am`, `9:30pm`: twelve hours, and the suffix's case.
    pub twelve_hour: bool,
    pub upper_suffix: bool,
    /// `09:00` rather than `9:00`.
    pub padded: bool,
    /// What joins two times, spaces and all.
    pub separator: String,
}

impl Default for StampStyle {
    fn default() -> Self {
        StampStyle { twelve_hour: false, upper_suffix: false, padded: false, separator: "–".to_owned() }
    }
}

/// The time a row's text starts with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TimeStamp {
    /// How much of the text the stamp is: the times and what joins them,
    /// not the space after.
    pub len: usize,
    /// The stamp and what parts it from the words — a colon, spaces: what
    /// a row hides of itself where its time is drawn instead.
    pub full_len: usize,
    pub start: u32,
    /// Past the start: an end written before the start is the next day's.
    pub end: Option<u32>,
    pub style: StampStyle,
    /// Written as bare numbers — `11-1` — which say a time only among
    /// times written plainly: alone, they could be a count.
    pub is_bare: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Half {
    Am,
    Pm,
}

#[derive(Debug, Clone, Copy)]
struct Clock {
    hour: u32,
    minute: u32,
    colon: bool,
    padded: bool,
    half: Option<Half>,
    upper: bool,
}

impl Clock {
    fn is_valid(&self, twelve: bool) -> bool {
        self.minute < 60 && if twelve { (1..=12).contains(&self.hour) } else { self.hour < 24 }
    }

    fn minutes(&self, twelve: bool) -> u32 {
        match self.half {
            Some(half) if twelve => ((self.hour % 12) + if half == Half::Pm { 12 } else { 0 }) * 60 + self.minute,
            _ => self.hour * 60 + self.minute,
        }
    }
}

/// `9`, `09:30`, `9:30am`, `9 pm`: a time, read on from an index.
fn clock(chars: &[char], index: &mut usize) -> Option<Clock> {
    let mut i = *index;
    let digits = |i: &mut usize, max: usize| -> Option<(u32, usize)> {
        let (mut value, mut count) = (0, 0);
        while *i < chars.len() && count < max && chars[*i].is_ascii_digit() {
            value = value * 10 + chars[*i].to_digit(10)?;
            count += 1;
            *i += 1;
        }
        (count > 0).then_some((value, count))
    };
    let (hour, hour_digits) = digits(&mut i, 2)?;
    let mut clock = Clock { hour, minute: 0, colon: false, padded: hour_digits == 2 && hour < 10, half: None, upper: false };
    if i < chars.len() && (chars[i] == ':' || chars[i] == '.') {
        let mark = i;
        i += 1;
        match digits(&mut i, 2) {
            Some((minute, 2)) => {
                clock.minute = minute;
                clock.colon = true;
            }
            _ => i = mark,
        }
    }
    // am or pm, a space before it or not.
    let mut probe = i;
    if probe < chars.len() && chars[probe] == ' ' {
        probe += 1;
    }
    if let Some(letter) = chars.get(probe).map(char::to_ascii_lowercase).filter(|c| *c == 'a' || *c == 'p') {
        let mut end = probe + 1;
        if chars.get(end).is_some_and(|c| c.eq_ignore_ascii_case(&'m')) {
            end += 1;
        }
        // Only as a word: "9 apples" is not nine in the morning.
        let is_word = chars.get(end).is_none_or(|c| !c.is_ascii_alphabetic());
        if is_word && (end - probe == 2 || probe == i) {
            clock.half = Some(if letter == 'a' { Half::Am } else { Half::Pm });
            clock.upper = chars[probe].is_ascii_uppercase();
            i = end;
        }
    }
    *index = i;
    Some(clock)
}

const DAY: u32 = 24 * 60;

impl TimeStamp {
    /// The stamp a row's text starts with, if it starts with one.
    pub fn at_start(text: &str) -> Option<TimeStamp> {
        let chars: Vec<char> = text.chars().take(40).collect();
        let bytes = |count: usize| chars[..count].iter().map(|c| c.len_utf8()).sum::<usize>();
        let mut index = 0;
        let mut start = clock(&chars, &mut index)?;
        let mut style = StampStyle { padded: start.padded, ..StampStyle::default() };
        let mut end: Option<Clock> = None;
        let after_first = index;
        // A separator, then a second time; else the stamp is the first alone.
        let mut probe = index;
        while chars.get(probe) == Some(&' ') {
            probe += 1;
        }
        let mut joined = false;
        if matches!(chars.get(probe), Some('-' | '–' | '—')) {
            probe += 1;
            joined = true;
        } else if chars.get(probe) == Some(&'t') && chars.get(probe + 1) == Some(&'o') {
            // "to", a word of its own.
            probe += 2;
            joined = chars.get(probe) == Some(&' ');
        }
        if joined {
            let separator_start = index;
            while chars.get(probe) == Some(&' ') {
                probe += 1;
            }
            let mut second = probe;
            if let Some(found) = clock(&chars, &mut second) {
                end = Some(found);
                style.separator = chars[separator_start..probe].iter().collect();
                index = second;
            }
        }
        if end.is_none() {
            index = after_first;
        }
        // A bare number is a count, not a time; two joined — `11-1` — may be
        // times, if the list they are in says so.
        let is_bare = !(start.colon || start.half.is_some() || end.is_some_and(|end| end.colon || end.half.is_some()));
        if is_bare && end.is_none() {
            return None;
        }
        // What follows is the row's words, or nothing.
        if chars.get(index).is_some_and(|c| !matches!(c, ' ' | '\t' | ',' | ':')) {
            return None;
        }
        // `11–1pm`: the first takes the second's half of the day, or the other.
        if let (None, Some(end)) = (start.half, end) {
            if let Some(half) = end.half {
                start.half = Some(half);
                if start.minutes(true) > end.minutes(true) {
                    start.half = Some(if half == Half::Am { Half::Pm } else { Half::Am });
                }
            }
        }
        if let (Some(half), Some(end)) = (start.half, end.as_mut()) {
            end.half.get_or_insert(half);
        }
        let twelve = start.half.is_some();
        style.twelve_hour = twelve;
        style.upper_suffix = start.upper || end.is_some_and(|end| end.upper);
        if !start.is_valid(twelve) || !end.is_none_or(|end| end.is_valid(twelve)) {
            return None;
        }
        let start_minutes = start.minutes(twelve);
        // `11-1`: past noon, as it is said; else an end before the start is the next day's.
        let end_minutes = end.map(|end| end.minutes(twelve)).map(|end| {
            if end > start_minutes {
                end
            } else if !twelve && end + 12 * 60 > start_minutes && end < 12 * 60 {
                end + 12 * 60
            } else {
                end + DAY
            }
        });
        let mut full = index;
        // `10:00–11:00: hello`: the colon after the times goes with them.
        if matches!(chars.get(full), Some(':' | ',')) {
            full += 1;
        }
        while matches!(chars.get(full), Some(' ' | '\t')) {
            full += 1;
        }
        Some(TimeStamp { len: bytes(index), full_len: bytes(full), start: start_minutes, end: end_minutes, style, is_bare })
    }

    /// How long it lasts, if it says.
    pub fn duration(&self) -> Option<u32> {
        self.end.map(|end| end - self.start)
    }

    /// A time written as a stamp in a style.
    pub fn write(minutes: u32, style: &StampStyle) -> String {
        let minutes = minutes % DAY;
        let (hour, minute) = (minutes / 60, minutes % 60);
        if style.twelve_hour {
            let shown = if hour % 12 == 0 { 12 } else { hour % 12 };
            let suffix = if hour < 12 { "am" } else { "pm" };
            let suffix = if style.upper_suffix { suffix.to_uppercase() } else { suffix.to_owned() };
            return if minute == 0 { format!("{shown}{suffix}") } else { format!("{shown}:{minute:02}{suffix}") };
        }
        if style.padded {
            format!("{hour:02}:{minute:02}")
        } else {
            format!("{hour}:{minute:02}")
        }
    }

    /// A stamp's text for a start and an end, in this stamp's style.
    pub fn written(&self, start: u32, end: Option<u32>) -> String {
        written(&self.style, start, end)
    }
}

fn written(style: &StampStyle, start: u32, end: Option<u32>) -> String {
    match end {
        Some(end) => format!("{}{}{}", TimeStamp::write(start, style), style.separator, TimeStamp::write(end, style)),
        None => TimeStamp::write(start, style),
    }
}

/// Minutes as people say a length: `45m`, `1h`, `1h 30m`.
pub fn length(minutes: u32) -> String {
    match (minutes / 60, minutes % 60) {
        (0, rest) => format!("{rest}m"),
        (hours, 0) => format!("{hours}h"),
        (hours, rest) => format!("{hours}h {rest}m"),
    }
}

/// A time as a clock shows it: `9:30`, or `9:30 AM`.
pub fn shown(minutes: u32, twelve_hour: bool) -> String {
    let minutes = minutes % DAY;
    let (hour, minute) = (minutes / 60, minutes % 60);
    if !twelve_hour {
        return format!("{hour}:{minute:02}");
    }
    let shown = if hour % 12 == 0 { 12 } else { hour % 12 };
    let half = if hour < 12 { " AM" } else { " PM" };
    if minute == 0 {
        format!("{shown}{half}")
    } else {
        format!("{shown}:{minute:02}{half}")
    }
}

/// Two times, as a clock shows them: `9:30 – 10:15`, or, in twelve hours,
/// `9:30 – 10:15 AM`, the half of the day said once when they share it.
pub fn span(start: u32, end: u32, twelve_hour: bool) -> String {
    let (from, to) = (shown(start, twelve_hour), shown(end, twelve_hour));
    match from.strip_suffix(&to[to.len().saturating_sub(3)..]) {
        Some(bare) if twelve_hour => format!("{bare} – {to}"),
        _ => format!("{from} – {to}"),
    }
}

/// One block of a timeline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TimeBlock {
    /// The item that starts with the time.
    pub path: Path,
    pub stamp: TimeStamp,
    /// When it ends: as written; else when the next starts; else half an
    /// hour on.
    pub end: u32,
    /// When the next block starts, if after this one ends: the time
    /// between is free.
    pub next: Option<u32>,
}

impl TimeBlock {
    pub fn start(&self) -> u32 {
        self.stamp.start
    }

    pub fn duration(&self) -> u32 {
        self.end - self.stamp.start
    }

    /// The free time after it, before the next.
    pub fn free(&self) -> u32 {
        self.next.map_or(0, |next| next.saturating_sub(self.end))
    }
}

/// A list of time blocks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Timeline {
    /// The item whose children the blocks are; `None` for the blocks at
    /// the top of a note.
    pub parent: Option<Path>,
    pub blocks: Vec<TimeBlock>,
    /// How deep it is within other timelines: 0, or one more than the
    /// timeline whose block it is inside.
    pub level: usize,
}

/// The timeline a list is, if it is one: two items or more, each starting
/// with a time. An empty item is let be — it is one being written — and
/// goes with the block before it.
fn timeline(siblings: &[Block], parent: Option<&[usize]>) -> Option<Timeline> {
    let mut heads: Vec<(usize, TimeStamp)> = Vec::new();
    for (index, block) in siblings.iter().enumerate() {
        // Its first line: a stamp is read from where the words begin.
        match TimeStamp::at_start(&block.text).filter(|_| block.is_item()) {
            Some(stamp) => heads.push((index, stamp)),
            None if block.text.trim().is_empty() && block.is_item() && !heads.is_empty() => {}
            None => return None,
        }
    }
    // Bare numbers alone are a list of counts — `1-2 cups` — not times;
    // one block alone is one if it says when it ends.
    if !heads.iter().any(|(_, stamp)| !stamp.is_bare) || !(heads.len() >= 2 || heads.first().is_some_and(|(_, stamp)| stamp.end.is_some())) {
        return None;
    }
    let starts: Vec<u32> = heads.iter().map(|(_, stamp)| stamp.start).collect();
    let blocks = heads
        .into_iter()
        .enumerate()
        .map(|(n, (index, stamp))| {
            let next_start = starts.get(n + 1).copied();
            let end = stamp.end.unwrap_or_else(|| next_start.filter(|next| *next > stamp.start).unwrap_or(stamp.start + 30));
            let path = [parent.unwrap_or(&[]), &[index]].concat();
            TimeBlock { path, stamp, end, next: next_start.filter(|next| *next > end) }
        })
        .collect();
    Some(Timeline { parent: parent.map(<[usize]>::to_vec), blocks, level: 0 })
}

/// The timelines in a document, in reading order: one around another
/// comes before it.
pub fn find(document: &Document) -> Vec<Timeline> {
    fn visit(blocks: &[Block], path: &mut Path, found: &mut Vec<Timeline>) {
        for (index, block) in blocks.iter().enumerate().filter(|(_, block)| !block.children.is_empty()) {
            path.push(index);
            found.extend(timeline(&block.children, Some(path)));
            visit(&block.children, path, found);
            path.pop();
        }
    }
    let mut found: Vec<Timeline> = timeline(&document.blocks, None).into_iter().collect();
    visit(&document.blocks, &mut Vec::new(), &mut found);
    // One inside a block of another is a level deeper than it.
    for index in 0..found.len() {
        let Some(parent) = found[index].parent.clone() else { continue };
        let around = found[..index].iter().filter(|outer| outer.blocks.iter().any(|block| parent.starts_with(&block.path)));
        found[index].level = around.map(|outer| outer.level + 1).max().unwrap_or(0);
    }
    found
}

/// What Return at the end of a block with nothing under it makes: the
/// next block, starting as this one ends, half an hour long. Put in after
/// it; answers its path, and where the caret goes in it: after its time.
pub fn next_block(document: &mut Document, path: &[usize]) -> Option<(Path, usize)> {
    let block = find(document).into_iter().find_map(|timeline| timeline.blocks.into_iter().find(|block| block.path == path))?;
    let row = document.get(path)?;
    if !row.children.is_empty() && !row.folded {
        return None;
    }
    let item = row.item()?;
    let kind = BlockKind::Item(Item {
        marker: match item.marker {
            Marker::Ordered { number, delimiter } => Marker::Ordered { number: number + 1, delimiter },
            bullet => bullet,
        },
        task: item.task.map(|_| Task::Open),
    });
    let text = format!("{} ", block.stamp.written(block.end, Some(block.end + 30)));
    let caret = text.len();
    let (&index, parent) = path.split_last()?;
    let next = [parent, &[index + 1]].concat();
    outline::insert(document, &next, Block::new(kind, text))?;
    outline::renumber(document.siblings_mut(&next)?);
    Some((next, caret))
}

/// Makes a new time block at a row: from `now` — to the five minutes —
/// for a quarter of an hour. The row itself, if it is empty; else among
/// the blocks it is in, or beside the block it is, in order of time; else
/// a new last child of it, which makes it a timeline's parent. Answers the
/// new block's path, and where the caret goes in it: after its time.
pub fn new_block(document: &mut Document, path: &[usize], now: u32) -> Option<(Path, usize)> {
    let current = document.get(path)?.clone();
    let mut start = now - now % 5;
    let timelines = find(document);
    let timeline = timelines.iter().find(|timeline| timeline.blocks.iter().any(|block| path.starts_with(&block.path)));
    // Not on top of a block: from the end of the one under way, and on.
    while let Some(taken) = timeline.and_then(|timeline| timeline.blocks.iter().find(|block| block.start() <= start && start < block.end)) {
        start = taken.end;
    }
    // Written as the blocks around it are.
    let own = TimeStamp::at_start(&current.text).filter(|_| current.is_item());
    let reference = timeline.and_then(|timeline| timeline.blocks.iter().map(|block| &block.stamp).find(|stamp| !stamp.is_bare)).or(own.as_ref());
    let style = reference.filter(|stamp| !stamp.is_bare).map(|stamp| stamp.style.clone()).unwrap_or_default();
    let text = format!("{} ", written(&style, start, Some(start + 15)));
    let caret = text.len();
    let like = |row: Option<&Block>| {
        let kind = match row.and_then(Block::item) {
            Some(item) => BlockKind::Item(Item { marker: item.marker, task: item.task.map(|_| Task::Open) }),
            None => BlockKind::Item(Item { marker: Marker::Bullet('-'), task: None }),
        };
        Block::new(kind, text.clone())
    };
    // An empty row: it becomes the block.
    if current.text.trim().is_empty() && (current.is_item() || current.kind == BlockKind::Paragraph) {
        if !current.is_item() {
            outline::set_kind(document, path, BlockKind::Item(Item { marker: Marker::Bullet('-'), task: None }));
        }
        document.get_mut(path)?.text = text;
        return Some((path.to_vec(), caret));
    }
    // Among blocks, or beside one: before the first that starts later.
    let mut siblings: Vec<(Path, u32)> =
        timeline.map(|timeline| timeline.blocks.iter().map(|block| (block.path.clone(), block.start())).collect()).unwrap_or_default();
    if siblings.is_empty() {
        siblings.extend(own.map(|stamp| (path.to_vec(), stamp.start)));
    }
    if let Some((last, _)) = siblings.last().cloned() {
        let model = siblings.iter().map(|(sibling, _)| sibling).find(|sibling| path.starts_with(sibling)).unwrap_or(&last).clone();
        let at = siblings.iter().find(|(_, begins)| *begins > start).map(|(sibling, _)| sibling.clone()).unwrap_or_else(|| {
            let mut after = last.clone();
            *after.last_mut().expect("a path is never empty") += 1;
            after
        });
        let new = like(document.get(&model));
        outline::insert(document, &at, new)?;
        outline::renumber(document.siblings_mut(&at)?);
        return Some((at, caret));
    }
    // Else under the row: its last child — or, a row that cannot hold
    // children, after it.
    let at = if current.can_have_children() {
        [path, &[current.children.len()]].concat()
    } else {
        let (&index, parent) = path.split_last()?;
        [parent, &[index + 1]].concat()
    };
    outline::insert(document, &at, like(None))?;
    Some((at, caret))
}

/// Room for a length, in rows: none up to half an hour, then a little
/// more each time it doubles — so a long day stays short.
pub fn length_room(minutes: u32) -> f64 {
    (f64::from(minutes.max(1)) / 30.0).log2().max(0.0) * 0.25
}

/// Room for free time, in rows: a line to say it, and a little more for a
/// long one.
pub fn free_room(minutes: u32) -> f64 {
    if minutes == 0 {
        0.0
    } else {
        0.8 + (f64::from(minutes) / 30.0).log2().max(0.0) * 0.3
    }
}

/// What an outline draws of a timeline at one of its rows: a block
/// starting there — its time and length over its words, its bullet a node
/// on the line — and the blocks ending there, with the room after them.
/// Rows are those an outline shows, counted from the first.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct TimeMark {
    pub row: usize,
    pub head: Option<TimeHead>,
    /// Innermost first: a nested timeline's last block ends where its
    /// block in the timeline around it does.
    pub feet: Vec<TimeFoot>,
}

/// A block starting at a row.
#[derive(Debug, Clone, PartialEq)]
pub struct TimeHead {
    /// Which timeline, and which of its blocks.
    pub timeline: usize,
    pub index: usize,
    /// How deep its timeline is within others.
    pub level: usize,
    /// Its end as written, or as the next begins.
    pub start: u32,
    pub end: u32,
    /// `9:00 – 10:30 · 1h 30m`.
    pub label: String,
    /// `overlaps Offsite 30m`, when it starts before an earlier one
    /// ends; and, where that is too long, `30m overlap`.
    pub overlap: Option<String>,
    pub overlap_short: Option<String>,
    /// Where its time is written in what the outline shows, with what
    /// parts it from the words: hidden where the label is drawn instead.
    pub stamp: std::ops::Range<usize>,
    /// The block's last row, and the next block's first.
    pub last_row: usize,
    pub next_row: Option<usize>,
    /// Whether it is a task checked off.
    pub done: bool,
}

/// A block ending at a row: the room after it.
#[derive(Debug, Clone, PartialEq)]
pub struct TimeFoot {
    pub timeline: usize,
    pub index: usize,
    pub level: usize,
    /// Room for its length, in rows: see [`length_room`].
    pub length: f64,
    /// Free time after it, before the next: its minutes, its room in
    /// rows ([`free_room`]), and what it says — `2h free`.
    pub free: u32,
    pub free_length: f64,
    pub free_label: Option<String>,
    /// Whether it is its timeline's last: there the line ends.
    pub is_last: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stamp(text: &str) -> Option<(u32, Option<u32>, usize, usize)> {
        TimeStamp::at_start(text).map(|stamp| (stamp.start, stamp.end, stamp.len, stamp.full_len))
    }

    #[test]
    fn a_time_is_read_from_the_start_of_a_row() {
        assert_eq!(stamp("9:00–10:30 Deep work"), Some((540, Some(630), 12, 13)));
        assert_eq!(stamp("11am Standup"), Some((660, None, 4, 5)));
        assert_eq!(stamp("14:00 to 15:30 Review"), Some((840, Some(930), 14, 15)));
        assert_eq!(stamp("10:00-11:00: hello"), Some((600, Some(660), 11, 13)));
        assert_eq!(stamp("9 pm"), Some((21 * 60, None, 4, 4)));
        // `11–1pm`: the first takes the other half of the day; `11-1` is past noon.
        assert_eq!(stamp("11–1pm lunch").map(|s| (s.0, s.1)), Some((660, Some(780))));
        assert_eq!(stamp("11-1 lunch").map(|s| (s.0, s.1)), Some((660, Some(780))));
        assert!(TimeStamp::at_start("11-1 lunch").unwrap().is_bare);
        // An end before the start is the next day's.
        assert_eq!(stamp("23:00-1:00 night").map(|s| (s.0, s.1)), Some((1380, Some(1500))));
        // A count is no time; nor are words.
        assert_eq!(stamp("9 apples"), None);
        assert_eq!(stamp("3 things"), None);
        assert_eq!(stamp("25:00 x"), None);
        assert_eq!(stamp("9:00x"), None);
        assert_eq!(stamp("plain"), None);
    }

    #[test]
    fn a_time_is_written_as_those_around_it_are() {
        let style = |text: &str| TimeStamp::at_start(text).unwrap();
        assert_eq!(style("9:00–10:30 x").written(600, Some(645)), "10:00–10:45");
        assert_eq!(style("09:00 - 10:30 x").written(600, Some(645)), "10:00 - 10:45");
        assert_eq!(style("9am to 10am x").written(13 * 60, Some(13 * 60 + 30)), "1pm to 1:30pm");
        assert_eq!(style("9AM x").written(0, None), "12AM");
        assert_eq!((length(45), length(60), length(90)), ("45m".into(), "1h".into(), "1h 30m".into()));
        assert_eq!(span(570, 615, false), "9:30 – 10:15");
        assert_eq!(span(570, 615, true), "9:30 – 10:15 AM");
        assert_eq!(span(690, 780, true), "11:30 AM – 1 PM");
    }

    #[test]
    fn a_list_of_times_is_a_timeline() {
        let document = Document::parse("- Plan\n  - 9:00 Standup\n  - 9:30–11:00 Deep work\n    - notes\n  - \n  - 13:00 Lunch\n- other\n");
        let found = find(&document);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].parent.as_deref(), Some(&[0][..]));
        let blocks: Vec<_> = found[0].blocks.iter().map(|block| (block.path.clone(), block.start(), block.end, block.next)).collect();
        // The first lasts until the next begins; the last, half an hour; between the second and the third, free time.
        assert_eq!(blocks, [(vec![0, 0], 540, 570, None), (vec![0, 1], 570, 660, Some(780)), (vec![0, 3], 780, 810, None)]);
        assert_eq!(found[0].blocks[1].free(), 120);
        // A list with an item that starts with no time is no timeline; nor are counts; nor one block that does not say when it ends.
        assert!(find(&Document::parse("- 9:00 a\n- b\n")).is_empty());
        assert!(find(&Document::parse("- 1-2 cups\n- 3-4 spoons\n")).is_empty());
        assert!(find(&Document::parse("- 9:00 a\n")).is_empty());
        assert_eq!(find(&Document::parse("- 9:00–10:00 a\n")).len(), 1);
        assert!(find(&Document::parse("9:00 a\n\n10:00 b\n")).is_empty());
        // One inside a block of another is a level deeper.
        let nested = find(&Document::parse("- 9:00 a\n  - 9:00 a1\n  - 9:10 a2\n- 10:00 b\n"));
        assert_eq!(nested.iter().map(|timeline| (timeline.parent.clone(), timeline.level)).collect::<Vec<_>>(), [(None, 0), (Some(vec![0]), 1)]);
    }

    #[test]
    fn a_new_block_goes_where_its_time_does() {
        // An empty row becomes the block: from now, to the five minutes, a quarter of an hour.
        let mut document = Document::parse("- one\n- \n");
        assert_eq!(new_block(&mut document, &[1], 9 * 60 + 33), Some((vec![1], 12)));
        assert_eq!(document.to_markdown(), "- one\n- 9:30–9:45 \n");
        // Under a row that is no block: its last child.
        let mut document = Document::parse("- Today\n  - first\n");
        assert_eq!(new_block(&mut document, &[0], 14 * 60), Some((vec![0, 1], 14)));
        assert_eq!(document.to_markdown(), "- Today\n  - first\n  - 14:00–14:15 \n");
        // Among blocks: in order of time, written as they are, and not on top of one under way.
        let mut document = Document::parse("+ [x] 9am–9:30am Standup\n+ [ ] 1pm Lunch\n");
        assert_eq!(new_block(&mut document, &[1], 9 * 60 + 2).map(|made| made.0), Some(vec![1]));
        assert_eq!(document.to_markdown(), "+ [x] 9am–9:30am Standup\n+ [ ] 9:30am–9:45am \n+ [ ] 1pm Lunch\n");
        let mut document = Document::parse("- 9:00 a\n- 10:00 b\n");
        assert_eq!(new_block(&mut document, &[0], 18 * 60).map(|made| made.0), Some(vec![2]));
        assert_eq!(document.to_markdown(), "- 9:00 a\n- 10:00 b\n- 18:00–18:15 \n");
        // Beside a block that is alone.
        let mut document = Document::parse("- 9:00 a\n");
        new_block(&mut document, &[0], 8 * 60);
        assert_eq!(document.to_markdown(), "- 8:00–8:15 \n- 9:00 a\n");
    }

    #[test]
    fn return_at_a_blocks_end_makes_the_next() {
        let mut document = Document::parse("- 9:00–9:45 a\n- 13:00 b\n  - under\n");
        assert_eq!(next_block(&mut document, &[0]), Some((vec![1], 13)));
        assert_eq!(document.to_markdown(), "- 9:00–9:45 a\n- 9:45–10:15 \n- 13:00 b\n  - under\n");
        // A block with rows under it makes none; nor does a row that is no block.
        assert_eq!(next_block(&mut document, &[2]), None);
        assert_eq!(next_block(&mut Document::parse("- a\n- b\n"), &[0]), None);
    }

    #[test]
    fn longer_blocks_take_a_little_more_room() {
        assert_eq!((length_room(15), length_room(30), length_room(60), length_room(120)), (0.0, 0.0, 0.25, 0.5));
        assert_eq!(free_room(0), 0.0);
        assert!((free_room(30) - 0.8).abs() < 1e-9 && (free_room(60) - 1.1).abs() < 1e-9);
    }
}
