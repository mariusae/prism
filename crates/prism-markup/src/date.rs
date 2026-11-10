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
