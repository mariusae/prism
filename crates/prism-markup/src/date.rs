//! Calendar days, ISO weeks and timestamps, as notes name them.
//!
//! A graph names its daily notes `2026-10-31` and its weekly notes
//! `2026-W44`, and stamps pages with ISO 8601 times. These are the small
//! value types for those three spellings: parsed strictly, printed
//! canonically, ordered chronologically.

use std::fmt;

/// A calendar day in the proleptic Gregorian calendar, written `YYYY-MM-DD`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Day {
    year: i32,
    month: u8,
    day: u8,
}

/// A day of the week, Monday first, as ISO 8601 counts them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Weekday {
    Monday,
    Tuesday,
    Wednesday,
    Thursday,
    Friday,
    Saturday,
    Sunday,
}

impl Day {
    /// A day from its parts, or `None` when there is no such day.
    pub fn new(year: i32, month: u8, day: u8) -> Option<Day> {
        if !(1..=9999).contains(&year) || !(1..=12).contains(&month) {
            return None;
        }
        (day >= 1 && day <= days_in_month(year, month)).then_some(Day { year, month, day })
    }

    /// Parses exactly `YYYY-MM-DD`; anything else is not a day.
    pub fn parse(text: &str) -> Option<Day> {
        let bytes = text.as_bytes();
        if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
            return None;
        }
        Day::new(digits(&bytes[0..4])? as i32, digits(&bytes[5..7])? as u8, digits(&bytes[8..10])? as u8)
    }

    pub fn year(self) -> i32 {
        self.year
    }
    pub fn month(self) -> u8 {
        self.month
    }
    pub fn day(self) -> u8 {
        self.day
    }

    /// Days since 1970-01-01, negative before it.
    pub fn to_epoch_days(self) -> i64 {
        // Howard Hinnant's `days_from_civil`.
        let y = i64::from(self.year) - i64::from(self.month <= 2);
        let era = y.div_euclid(400);
        let yoe = y.rem_euclid(400);
        let m = i64::from(self.month);
        let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + i64::from(self.day) - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        era * 146_097 + doe - 719_468
    }

    /// The day so many days after 1970-01-01, if it is in years 1–9999.
    pub fn from_epoch_days(days: i64) -> Option<Day> {
        let z = days + 719_468;
        let era = z.div_euclid(146_097);
        let doe = z.rem_euclid(146_097);
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = (doy - (153 * mp + 2) / 5 + 1) as u8;
        let month = (if mp < 10 { mp + 3 } else { mp - 9 }) as u8;
        let year = yoe + era * 400 + i64::from(month <= 2);
        Day::new(i32::try_from(year).ok()?, month, day)
    }

    /// The day `days` later (earlier, when negative).
    pub fn plus_days(self, days: i64) -> Option<Day> {
        Day::from_epoch_days(self.to_epoch_days() + days)
    }

    pub fn weekday(self) -> Weekday {
        // 1970-01-01 was a Thursday.
        match (self.to_epoch_days() + 3).rem_euclid(7) {
            0 => Weekday::Monday,
            1 => Weekday::Tuesday,
            2 => Weekday::Wednesday,
            3 => Weekday::Thursday,
            4 => Weekday::Friday,
            5 => Weekday::Saturday,
            _ => Weekday::Sunday,
        }
    }

    /// The ISO week the day falls in.
    pub fn week(self) -> Week {
        // The week's Thursday decides its year.
        let thursday = self.to_epoch_days() - (self.weekday() as i64) + 3;
        let year = Day::from_epoch_days(thursday).map_or(self.year, |d| d.year);
        let january_first = Day { year, month: 1, day: 1 }.to_epoch_days();
        Week { year, week: ((thursday - january_first) / 7 + 1) as u8 }
    }
}

impl fmt::Display for Day {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }
}

/// An ISO 8601 week, written `YYYY-Www`: `2026-W44`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Week {
    year: i32,
    week: u8,
}

impl Week {
    /// A week from its parts, or `None` when the year has no such week.
    pub fn new(year: i32, week: u8) -> Option<Week> {
        if !(1..=9999).contains(&year) || week == 0 || week > weeks_in_year(year) {
            return None;
        }
        Some(Week { year, week })
    }

    /// Parses exactly `YYYY-Www`.
    pub fn parse(text: &str) -> Option<Week> {
        let bytes = text.as_bytes();
        if bytes.len() != 8 || bytes[4] != b'-' || bytes[5] != b'W' {
            return None;
        }
        Week::new(digits(&bytes[0..4])? as i32, digits(&bytes[6..8])? as u8)
    }

    pub fn year(self) -> i32 {
        self.year
    }
    pub fn week(self) -> u8 {
        self.week
    }

    /// The week's Monday.
    pub fn first_day(self) -> Day {
        // January 4th is always in week 1.
        let january_fourth = Day { year: self.year, month: 1, day: 4 };
        let monday = january_fourth.to_epoch_days() - january_fourth.weekday() as i64;
        Day::from_epoch_days(monday + 7 * (i64::from(self.week) - 1)).unwrap_or(january_fourth)
    }
}

impl fmt::Display for Week {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:04}-W{:02}", self.year, self.week)
    }
}

/// An instant, to the second: what `created` and `modified` hold.
///
/// Parsed from ISO 8601 (`2026-10-31T10:34:00Z`, an offset in place of `Z`,
/// fractional seconds ignored, or a bare date meaning its midnight UTC).
/// Kept as seconds since the Unix epoch, so two stamps written in different
/// zones compare by when they were.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Timestamp(pub i64);

impl Timestamp {
    pub fn parse(text: &str) -> Option<Timestamp> {
        let text = text.trim();
        let day = Day::parse(text.get(0..10)?)?;
        let mut seconds = day.to_epoch_days() * 86_400;
        let rest = &text[10..];
        if rest.is_empty() {
            return Some(Timestamp(seconds));
        }
        let rest = rest.strip_prefix(['T', 't', ' '])?;
        let bytes = rest.as_bytes();
        if bytes.len() < 5 || bytes[2] != b':' {
            return None;
        }
        let (hour, minute) = (digits(&bytes[0..2])?, digits(&bytes[3..5])?);
        let mut at = 5;
        let mut second = 0;
        if bytes.get(at) == Some(&b':') {
            second = digits(bytes.get(at + 1..at + 3)?)?;
            at += 3;
        }
        if hour > 23 || minute > 59 || second > 60 {
            return None;
        }
        if bytes.get(at) == Some(&b'.') {
            at += 1;
            while bytes.get(at).is_some_and(u8::is_ascii_digit) {
                at += 1;
            }
        }
        seconds += i64::from(hour * 3600 + minute * 60 + second);
        match &rest[at..] {
            "" | "Z" | "z" => {}
            zone => {
                let sign = match zone.as_bytes()[0] {
                    b'+' => 1,
                    b'-' => -1,
                    _ => return None,
                };
                let zone = zone[1..].replace(':', "");
                if zone.len() != 4 {
                    return None;
                }
                let offset = digits(&zone.as_bytes()[0..2])? * 3600 + digits(&zone.as_bytes()[2..4])? * 60;
                seconds -= sign * i64::from(offset);
            }
        }
        Some(Timestamp(seconds))
    }

    /// The instant so many seconds after the Unix epoch.
    pub fn from_unix(seconds: i64) -> Timestamp {
        Timestamp(seconds)
    }
}

impl fmt::Display for Timestamp {
    /// Always UTC, to the second: `2026-10-31T10:34:00Z`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let days = self.0.div_euclid(86_400);
        let second = self.0.rem_euclid(86_400);
        match Day::from_epoch_days(days) {
            Some(day) => write!(f, "{day}T{:02}:{:02}:{:02}Z", second / 3600, second % 3600 / 60, second % 60),
            None => write!(f, "{}", self.0),
        }
    }
}

fn digits(bytes: &[u8]) -> Option<u32> {
    if bytes.is_empty() {
        return None;
    }
    bytes.iter().try_fold(0u32, |n, b| b.is_ascii_digit().then(|| n * 10 + u32::from(b - b'0')))
}

fn is_leap(year: i32) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

fn days_in_month(year: i32, month: u8) -> u8 {
    match month {
        4 | 6 | 9 | 11 => 30,
        2 if is_leap(year) => 29,
        2 => 28,
        _ => 31,
    }
}

/// 53 when the year starts on a Thursday, or is a leap year starting on a
/// Wednesday; else 52.
fn weeks_in_year(year: i32) -> u8 {
    let first = Day { year, month: 1, day: 1 }.weekday();
    if first == Weekday::Thursday || (is_leap(year) && first == Weekday::Wednesday) {
        53
    } else {
        52
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn days_parse_strictly_and_print_back() {
        let day = Day::parse("2026-10-31").unwrap();
        assert_eq!((day.year(), day.month(), day.day()), (2026, 10, 31));
        assert_eq!(day.to_string(), "2026-10-31");
        for bad in ["2026-02-30", "2026-13-01", "2026-1-01", "26-10-31", "2026-10-31 ", "2026/10/31", "abcd-ef-gh"] {
            assert_eq!(Day::parse(bad), None, "{bad}");
        }
        assert!(Day::parse("2024-02-29").is_some());
        assert!(Day::parse("2100-02-29").is_none());
    }

    #[test]
    fn epoch_days_round_trip() {
        assert_eq!(Day::parse("1970-01-01").unwrap().to_epoch_days(), 0);
        assert_eq!(Day::parse("2000-03-01").unwrap().to_epoch_days(), 11_017);
        for days in (-800_000..2_900_000).step_by(997) {
            if let Some(day) = Day::from_epoch_days(days) {
                assert_eq!(day.to_epoch_days(), days);
            }
        }
        assert_eq!(Day::parse("2026-12-31").unwrap().plus_days(1), Day::parse("2027-01-01"));
    }

    #[test]
    fn weekdays_and_weeks_follow_iso() {
        let day = Day::parse("2026-10-31").unwrap();
        assert_eq!(day.weekday(), Weekday::Saturday);
        assert_eq!(day.week().to_string(), "2026-W44");
        // The days around New Year belong to the week their Thursday is in.
        assert_eq!(Day::parse("2021-01-03").unwrap().week().to_string(), "2020-W53");
        assert_eq!(Day::parse("2024-12-30").unwrap().week().to_string(), "2025-W01");
        assert_eq!(Week::parse("2026-W44").unwrap().first_day().to_string(), "2026-10-26");
        assert_eq!(Week::parse("2020-W53").unwrap().first_day().to_string(), "2020-12-28");
        assert!(Week::parse("2026-W53").is_some()); // 2026 starts on a Thursday
        assert_eq!(Week::parse("2025-W53"), None);
        assert_eq!(Week::parse("2026-W00"), None);
        assert_eq!(Week::parse("2026-w44"), None);
    }

    #[test]
    fn timestamps_compare_across_zones() {
        let utc = Timestamp::parse("2026-10-31T10:34:00Z").unwrap();
        assert_eq!(utc.to_string(), "2026-10-31T10:34:00Z");
        assert_eq!(Timestamp::parse("2026-10-31T12:34:00+02:00"), Some(utc));
        assert_eq!(Timestamp::parse("2026-10-31T03:34:00.123-0700"), Some(utc));
        assert_eq!(Timestamp::parse("2026-10-31 10:34"), Some(utc));
        assert_eq!(Timestamp::parse("2026-10-31").unwrap().to_string(), "2026-10-31T00:00:00Z");
        assert!(Timestamp::parse("2026-10-31T10:35:00Z").unwrap() > utc);
        assert_eq!(Timestamp::parse("yesterday"), None);
        assert_eq!(Timestamp::parse("2026-10-31T25:00:00Z"), None);
    }
}

/// What a few words say of when: a day, or a week.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Spoken {
    Day(Day),
    Week(Week),
}

impl fmt::Display for Spoken {
    /// As its page is named: `2026-11-10`, `2026-W46`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Spoken::Day(day) => day.fmt(f),
            Spoken::Week(week) => week.fmt(f),
        }
    }
}

const WEEKDAYS: [&str; 7] = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
const MONTHS: [&str; 12] = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];

/// A day or a week as it is asked for in a few words, counted from
/// `today`: `today`, `yesterday`, `tomorrow`; `friday` — the coming one,
/// today if it is one — `last friday`, `next friday`; `this week`, `next
/// week`, `last week`; `3 days ago`, `in two weeks`, `a month from now`;
/// `Jan 3`, `3 January`, `March 5 2024`; or a date as a page is named,
/// `2026-10-05`, `2026-W41`. Case and spacing aside. `None` for words
/// that say no day: what is typed is, most of the time, something else.
///
/// A word cut short is still its word once it could be no other: `tom`
/// is tomorrow, `wed` Wednesday, `sept` September.
pub fn spoken(text: &str, today: Day) -> Option<Spoken> {
    let text = text.trim().to_lowercase().replace(',', " ");
    let words: Vec<&str> = text.split_whitespace().collect();
    let day = |days: i64| today.plus_days(days).map(Spoken::Day);
    let cut = |word: &str, whole: &str| word.len() >= 3 && whole.starts_with(word);
    match words.as_slice() {
        [] => None,
        [one] => {
            if let Some(day) = Day::parse(one) {
                return Some(Spoken::Day(day));
            }
            if let Some(week) = Week::parse(&one.to_uppercase()) {
                return Some(Spoken::Week(week));
            }
            match *one {
                "now" | "tmrw" | "tmr" => day(i64::from(*one != "now")),
                word if cut(word, "today") => day(0),
                word if cut(word, "tomorrow") => day(1),
                word if cut(word, "yesterday") => day(-1),
                word => weekday(word).and_then(|wanted| day((wanted - today.weekday() as i64).rem_euclid(7))),
            }
        }
        [which, "week"] => {
            let weeks = match *which {
                "this" => 0,
                "next" | "coming" => 1,
                "last" | "past" | "previous" => -1,
                _ => return None,
            };
            today.plus_days(weeks * 7).map(|day| Spoken::Week(day.week()))
        }
        [which, word] if weekday(word).is_some() && matches!(*which, "this" | "coming" | "next" | "last" | "past" | "previous") => {
            let ahead = (weekday(word)? - today.weekday() as i64).rem_euclid(7);
            match *which {
                "this" | "coming" => day(ahead),
                "next" => day(if ahead == 0 { 7 } else { ahead }),
                _ => day(if ahead == 0 { -7 } else { ahead - 7 }),
            }
        }
        _ => relative(&words, today).or_else(|| written(&words, today)).map(Spoken::Day),
    }
}

/// A weekday by its name, or the start of it: Monday is 0.
fn weekday(word: &str) -> Option<i64> {
    (word.len() >= 3).then(|| WEEKDAYS.iter().position(|day| day.starts_with(word))).flatten().map(|at| at as i64)
}

/// `3 days ago`, `in two weeks`, `a month from now`, `a year later`.
fn relative(words: &[&str], today: Day) -> Option<Day> {
    let (sign, words) = match words {
        ["in", rest @ ..] => (1, rest),
        [rest @ .., "ago"] => (-1, rest),
        [rest @ .., "from", "now"] => (1, rest),
        [rest @ .., "later" | "hence"] => (1, rest),
        _ => return None,
    };
    let [count, unit] = words else { return None };
    let named = ["a", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve"];
    let count: i64 = match *count {
        "an" => 1,
        count => count.parse().ok().or_else(|| named.iter().position(|word| *word == count).map(|at| at.max(1) as i64))?,
    } * sign;
    match unit.trim_end_matches('s') {
        "day" => today.plus_days(count),
        "week" => today.plus_days(count * 7),
        "month" => months_on(today, count),
        "year" => months_on(today, count * 12),
        _ => None,
    }
}

/// The same day so many months on — or the month's last, where it has no such day.
fn months_on(day: Day, months: i64) -> Option<Day> {
    let index = i64::from(day.year()) * 12 + i64::from(day.month()) - 1 + months;
    let (year, month) = (i32::try_from(index.div_euclid(12)).ok()?, (index.rem_euclid(12) + 1) as u8);
    (1..=day.day()).rev().find_map(|d| Day::new(year, month, d))
}

/// A date as it is written out: `Jan 3`, `January 3rd`, `3 Jan`, `March 5 2024`. This year, with none said.
fn written(words: &[&str], today: Day) -> Option<Day> {
    let month = |word: &str| (word.len() >= 3).then(|| MONTHS.iter().position(|month| month.starts_with(word))).flatten().map(|at| at as u8 + 1);
    let number = |word: &str| word.trim_end_matches(|c: char| c.is_ascii_alphabetic()).parse::<u32>().ok();
    let (month, day, year) = match words {
        [m, d] if month(m).is_some() => (month(m)?, number(d)?, None),
        [d, m] if month(m).is_some() => (month(m)?, number(d)?, None),
        [m, d, y] if month(m).is_some() => (month(m)?, number(d)?, Some(y)),
        [d, m, y] if month(m).is_some() => (month(m)?, number(d)?, Some(y)),
        _ => return None,
    };
    let year = match year {
        Some(year) => year.parse::<i32>().ok().filter(|year| (1000..=9999).contains(year))?,
        None => today.year(),
    };
    Day::new(year, month, u8::try_from(day).ok()?)
}

#[cfg(test)]
mod spoken_tests {
    use super::*;

    #[test]
    fn days_and_weeks_are_asked_for_in_a_few_words() {
        // A Tuesday.
        let today = Day::new(2026, 11, 10).unwrap();
        let said = |text: &str| spoken(text, today).map(|when| when.to_string());
        let is = |text: &str, when: &str| assert_eq!(said(text).as_deref(), Some(when), "{text}");
        is("today", "2026-11-10");
        is("  Tomorrow ", "2026-11-11");
        is("tom", "2026-11-11");
        is("yesterday", "2026-11-09");
        is("tuesday", "2026-11-10");
        is("wed", "2026-11-11");
        is("monday", "2026-11-16");
        is("last tuesday", "2026-11-03");
        is("last monday", "2026-11-09");
        is("next tuesday", "2026-11-17");
        is("next friday", "2026-11-13");
        is("this week", "2026-W46");
        is("next week", "2026-W47");
        is("last week", "2026-W45");
        is("3 days ago", "2026-11-07");
        is("in two weeks", "2026-11-24");
        is("a month from now", "2026-12-10");
        is("a year ago", "2025-11-10");
        is("Jan 3", "2026-01-03");
        is("3 january", "2026-01-03");
        is("March 5, 2024", "2024-03-05");
        is("sept 1st", "2026-09-01");
        is("2026-10-05", "2026-10-05");
        is("2026-w41", "2026-W41");
        // A month has no 31st: its last day.
        assert_eq!(spoken("in a month", Day::new(2026, 1, 31).unwrap()).map(|when| when.to_string()).as_deref(), Some("2026-02-28"));
        for nothing in ["", "to", "mo", "ads paper", "next", "week", "mayhem 3", "feb 30", "in a while", "march"] {
            assert_eq!(said(nothing), None, "{nothing}");
        }
    }
}
