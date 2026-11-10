//! Three-way text merge, by lines.
//!
//! Two versions of a text are merged from the version both came from —
//! what `git merge-file` does, done here so it is the same on every
//! device and usable outside a sync: an editor saving over a note that
//! changed on disk merges the same way.
//!
//! Where both sides changed the same lines, both are kept between
//! conflict markers, ours first, for a person to settle (see
//! [`crate::conflict`]). A merge never fails and never drops a side.
//!
//! One thing is done that git does not do. Git calls two changes that
//! touch a conflict, even when they are to different lines; in an
//! outline, where two devices edit neighbouring bullets all the time,
//! that is most conflicts. Here, when both sides changed a run of lines
//! and neither added nor removed any, the lines are paired off and each
//! pair settled on its own — so only a line both actually rewrote is left
//! for a person.

use similar::{Algorithm, DiffOp};

/// The labels on a conflict's two sides.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Labels<'a> {
    pub ours: &'a str,
    pub theirs: &'a str,
}

impl Default for Labels<'_> {
    /// `this device` and `other device`: Reflect's labels, so graphs
    /// shared with it show one kind of conflict.
    fn default() -> Self {
        Labels { ours: crate::conflict::OUR_LABEL, theirs: crate::conflict::THEIR_LABEL }
    }
}

/// A merge's result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Merged {
    pub text: String,
    /// Whether some lines both sides changed are between markers.
    pub conflicted: bool,
}

/// Merges `ours` and `theirs`, both descended from `base`.
pub fn merge(base: &str, ours: &str, theirs: &str, labels: Labels<'_>) -> Merged {
    merge_by(base, ours, theirs, labels, |line| line)
}

/// Merges as [`merge`] does, but takes two lines that differ only in the
/// spaces and tabs at their ends (or in `\r\n` against `\n`) for the same
/// line. A space one device left at a line's end and the other took off is
/// no change, and must not pull the line into a conflict. Lines are
/// written as the side they come from has them; a line both kept, as ours.
pub fn merge_lenient(base: &str, ours: &str, theirs: &str, labels: Labels<'_>) -> Merged {
    merge_by(base, ours, theirs, labels, |line| line.trim_end_matches([' ', '\t', '\r']))
}

fn merge_by(base: &str, ours: &str, theirs: &str, labels: Labels<'_>, key: fn(&str) -> &str) -> Merged {
    if ours == theirs || theirs == base {
        return Merged { text: ours.to_owned(), conflicted: false };
    }
    if ours == base {
        return Merged { text: theirs.to_owned(), conflicted: false };
    }
    // A last line with no break is the same line as one with: lines are
    // compared each ended, and the end put back as the side that changed
    // it has it.
    let ended = |text: &str| text.is_empty() || text.ends_with('\n');
    let ends_with_break = if ended(ours) != ended(base) { ended(ours) } else { ended(theirs) };
    let (o, a, b) = (lines(base), lines(ours), lines(theirs));
    fn keys<'a>(lines: &[&'a str], key: fn(&str) -> &str) -> Vec<&'a str> {
        lines.iter().map(|l| key(l)).collect()
    }
    let (ko, ka, kb) = (keys(&o, key), keys(&a, key), keys(&b, key));
    let (to_a, to_b) = (matches(&ko, &ka), matches(&ko, &kb));

    let mut out = String::with_capacity(ours.len().max(theirs.len()));
    let mut conflicted = false;
    let mut last_was_marker = false;
    // Walk from one base line both sides kept to the next; between them,
    // each side's run of lines.
    let (mut i, mut ia, mut ib) = (0, 0, 0);
    loop {
        let mut j = i;
        while j < o.len() && (to_a[j].is_none() || to_b[j].is_none()) {
            j += 1;
        }
        let end_a = if j < o.len() { to_a[j].unwrap_or(a.len()) } else { a.len() };
        let end_b = if j < o.len() { to_b[j].unwrap_or(b.len()) } else { b.len() };
        if j > i || end_a > ia || end_b > ib {
            let (a_run, b_run) = (&a[ia..end_a], &b[ib..end_b]);
            let (base_keys, a_keys, b_keys) = (&ko[i..j], &ka[ia..end_a], &kb[ib..end_b]);
            if a_keys == base_keys {
                b_run.iter().for_each(|l| push_line(&mut out, l));
                last_was_marker = false;
            } else if b_keys == base_keys || a_keys == b_keys {
                a_run.iter().for_each(|l| push_line(&mut out, l));
                last_was_marker = false;
            } else {
                // Both changed the run. When neither added nor removed
                // lines, the lines pair off, and each pair is settled on
                // its own: two devices editing neighbouring lines — two
                // bullets of one list — do not conflict. Otherwise the
                // whole run is the conflict.
                let paired = a_run.len() == base_keys.len() && b_run.len() == base_keys.len();
                let clashes = |k: usize| !paired || (a_keys[k] != base_keys[k] && b_keys[k] != base_keys[k] && a_keys[k] != b_keys[k]);
                let mut k = 0;
                while k < a_run.len().max(b_run.len()) {
                    if !clashes(k) {
                        push_line(&mut out, if a_keys[k] == base_keys[k] { b_run[k] } else { a_run[k] });
                        last_was_marker = false;
                        k += 1;
                        continue;
                    }
                    // A conflict takes in every clashing line that follows.
                    let end = if paired { (k..a_run.len()).find(|&n| !clashes(n)).unwrap_or(a_run.len()) } else { a_run.len().max(b_run.len()) };
                    conflicted = true;
                    out.push_str(&format!("<<<<<<< {}\n", labels.ours));
                    a_run[k.min(a_run.len())..end.min(a_run.len())].iter().for_each(|l| push_line(&mut out, l));
                    out.push_str("=======\n");
                    b_run[k.min(b_run.len())..end.min(b_run.len())].iter().for_each(|l| push_line(&mut out, l));
                    out.push_str(&format!(">>>>>>> {}\n", labels.theirs));
                    last_was_marker = true;
                    k = end;
                }
            }
        }
        if j >= o.len() {
            break;
        }
        // A line both kept: as ours has it.
        push_line(&mut out, a.get(end_a).copied().unwrap_or(o[j]));
        last_was_marker = false;
        (i, ia, ib) = (j + 1, end_a + 1, end_b + 1);
    }
    // Every line was written ended; the last gives its break back unless
    // the text should end with one, or ends in a marker, which must.
    if !ends_with_break && !last_was_marker && out.ends_with('\n') {
        out.pop();
    }
    Merged { text: out, conflicted }
}

/// Merges bytes as text. `None` when any side is binary — has a NUL in
/// its first 8000 bytes, git's own test — or is not UTF-8.
pub fn merge_bytes(base: &[u8], ours: &[u8], theirs: &[u8], labels: Labels<'_>) -> Option<Merged> {
    if is_binary(base) || is_binary(ours) || is_binary(theirs) {
        return None;
    }
    Some(merge(std::str::from_utf8(base).ok()?, std::str::from_utf8(ours).ok()?, std::str::from_utf8(theirs).ok()?, labels))
}

/// Git's test for a binary file: a NUL in the first 8000 bytes.
pub fn is_binary(data: &[u8]) -> bool {
    data.iter().take(8000).any(|b| *b == 0)
}

/// [`merge_bytes`], by [`merge_lenient`]'s rules.
pub fn merge_bytes_lenient(base: &[u8], ours: &[u8], theirs: &[u8], labels: Labels<'_>) -> Option<Merged> {
    if is_binary(base) || is_binary(ours) || is_binary(theirs) {
        return None;
    }
    Some(merge_lenient(std::str::from_utf8(base).ok()?, std::str::from_utf8(ours).ok()?, std::str::from_utf8(theirs).ok()?, labels))
}

/// A text's lines, without their breaks.
fn lines(text: &str) -> Vec<&str> {
    let mut lines: Vec<&str> = text.split('\n').collect();
    if lines.last() == Some(&"") {
        lines.pop();
    }
    lines
}

fn push_line(out: &mut String, line: &str) {
    out.push_str(line);
    out.push('\n');
}

/// For each base line, where it is in the other version, if it was kept.
fn matches(base: &[&str], other: &[&str]) -> Vec<Option<usize>> {
    let mut kept = vec![None; base.len()];
    for op in similar::capture_diff_slices(Algorithm::Myers, base, other) {
        if let DiffOp::Equal { old_index, new_index, len } = op {
            for offset in 0..len {
                kept[old_index + offset] = Some(new_index + offset);
            }
        }
    }
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(base: &str, ours: &str, theirs: &str) -> (String, bool) {
        let merged = merge(base, ours, theirs, Labels::default());
        (merged.text, merged.conflicted)
    }

    #[test]
    fn one_side_changed_takes_that_side() {
        assert_eq!(m("a\nb\n", "a\nb\n", "a\nB\n"), ("a\nB\n".into(), false));
        assert_eq!(m("a\nb\n", "A\nb\n", "a\nb\n"), ("A\nb\n".into(), false));
        assert_eq!(m("a\n", "same\n", "same\n"), ("same\n".into(), false));
    }

    #[test]
    fn changes_to_different_lines_merge() {
        assert_eq!(m("a\nb\nc\n", "A\nb\nc\n", "a\nb\nC\n"), ("A\nb\nC\n".into(), false));
        // Each side adds lines in a different place.
        assert_eq!(m("a\nb\nc\n", "a\nx\nb\nc\n", "a\nb\nc\ny\n"), ("a\nx\nb\nc\ny\n".into(), false));
        // One deletes, the other adds elsewhere.
        assert_eq!(m("a\nb\nc\nd\n", "a\nc\nd\n", "a\nb\nc\nd\ne\n"), ("a\nc\nd\ne\n".into(), false));
    }

    #[test]
    fn changes_to_the_same_lines_keep_both_between_markers() {
        let (text, conflicted) = m("a\nb\nc\n", "a\nours\nc\n", "a\ntheirs\nc\n");
        assert!(conflicted);
        assert_eq!(text, "a\n<<<<<<< this device\nours\n=======\ntheirs\n>>>>>>> other device\nc\n");
        // Both added at the end: both kept.
        let (text, conflicted) = m("a\n", "a\nmine\n", "a\nyours\n");
        assert!(conflicted);
        assert_eq!(text, "a\n<<<<<<< this device\nmine\n=======\nyours\n>>>>>>> other device\n");
        // Changed here, deleted there.
        let (text, conflicted) = m("a\nb\n", "a\nb changed\n", "a\n");
        assert!(conflicted);
        assert_eq!(text, "a\n<<<<<<< this device\nb changed\n=======\n>>>>>>> other device\n");
    }

    #[test]
    fn neighbouring_lines_changed_one_each_do_not_conflict() {
        // git calls this a conflict: the two changes touch.
        assert_eq!(m("- one\n- two\n- three\n", "- ONE\n- two\n- three\n", "- one\n- TWO\n- three\n"), ("- ONE\n- TWO\n- three\n".into(), false));
        // Only the line both rewrote is left to settle.
        let (text, conflicted) = m("a\nb\nc\n", "A\nmine\nc\n", "a\nyours\nC\n");
        assert!(conflicted);
        assert_eq!(text, "A\n<<<<<<< this device\nmine\n=======\nyours\n>>>>>>> other device\nC\n");
        // A run where a side added or removed lines cannot be paired off.
        let (text, conflicted) = m("a\nb\n", "A\nb\n", "a\nx\nB\n");
        assert!(conflicted);
        assert_eq!(text, "<<<<<<< this device\nA\nb\n=======\na\nx\nB\n>>>>>>> other device\n");
    }

    #[test]
    fn the_same_change_on_both_sides_is_no_conflict() {
        assert_eq!(m("a\nb\nc\n", "a\nX\nc\nmine\n", "a\nX\nc\n"), ("a\nX\nc\nmine\n".into(), false));
    }

    #[test]
    fn the_last_lines_break_follows_whoever_changed_it() {
        assert_eq!(m("a\nb", "A\nb", "a\nb"), ("A\nb".into(), false));
        assert_eq!(m("a\nb", "a\nb\n", "A\nb"), ("A\nb\n".into(), false));
        assert_eq!(m("a\nb\n", "a\nb\n", "A\nb"), ("A\nb".into(), false));
        // A conflict at the end always ends its marker line.
        let (text, _) = m("a", "ours", "theirs");
        assert_eq!(text, "<<<<<<< this device\nours\n=======\ntheirs\n>>>>>>> other device\n");
    }

    #[test]
    fn empty_sides() {
        assert_eq!(m("", "new\n", ""), ("new\n".into(), false));
        assert_eq!(m("", "", "new\n"), ("new\n".into(), false));
        let (text, conflicted) = m("", "mine\n", "yours\n");
        assert!(conflicted);
        assert!(text.contains("mine\n=======\nyours\n"));
        assert_eq!(m("gone\n", "", ""), ("".into(), false));
    }

    #[test]
    fn custom_labels() {
        let merged = merge("a\n", "b\n", "c\n", Labels { ours: "draft", theirs: "disk" });
        assert_eq!(merged.text, "<<<<<<< draft\nb\n=======\nc\n>>>>>>> disk\n");
    }

    #[test]
    fn binary_is_not_merged_as_text() {
        assert!(is_binary(b"PNG\0\0"));
        assert!(!is_binary(b"plain"));
        assert_eq!(merge_bytes(b"a\n", b"b\0", b"c\n", Labels::default()), None);
        assert_eq!(merge_bytes(b"a\n", b"\xff\xfe", b"c\n", Labels::default()), None);
        assert_eq!(merge_bytes(b"a\n", b"a\n", b"c\n", Labels::default()).unwrap().text, "c\n");
    }

    #[test]
    fn lenient_merges_look_past_line_ends() {
        // Ours left a space at a line's end; theirs changed another line.
        let merged = merge_lenient("a\nb\nc\n", "a  \nb\nc\n", "a\nb\nC\n", Labels::default());
        assert_eq!((merged.text.as_str(), merged.conflicted), ("a  \nb\nC\n", false));
        // Both "changed" the same line, one only in its trailing space:
        // the real change wins, with no conflict.
        let merged = merge_lenient("a\n", "a \n", "A\n", Labels::default());
        assert_eq!((merged.text.as_str(), merged.conflicted), ("A\n", false));
        // Exact merging calls that a conflict.
        assert!(merge("a\n", "a \n", "A\n", Labels::default()).conflicted);
        // Windows line ends against Unix ones.
        let merged = merge_lenient("a\nb\n", "a\r\nb\r\n", "a\nb\nc\n", Labels::default());
        assert_eq!((merged.text.as_str(), merged.conflicted), ("a\r\nb\r\nc\n", false));
    }

    /// Whatever the three sides: a merge never panics, takes the side
    /// that changed when only one did, marks exactly the conflicts, loses
    /// no line both sides have, and does not care which side is "ours".
    #[test]
    fn merges_of_small_texts_are_sound() {
        let alphabet = ["a\n", "b\n", "c\n"];
        let texts: Vec<String> = (0..27)
            .map(|n| [n % 3, n / 3 % 3, n / 9].iter().map(|i| alphabet[*i]).collect::<String>())
            .chain(["".to_owned(), "a\n".to_owned(), "a\nb".to_owned(), "c\nb\na\nb\n".to_owned()])
            .collect();
        for base in &texts {
            for ours in &texts {
                for theirs in &texts {
                    let merged = merge(base, ours, theirs, Labels::default());
                    let case = format!("{base:?} {ours:?} {theirs:?}");
                    if ours == theirs || theirs == base {
                        assert_eq!(&merged.text, ours, "{case}");
                    } else if ours == base {
                        assert_eq!(&merged.text, theirs, "{case}");
                    }
                    assert_eq!(merged.conflicted, crate::conflict::detect(&merged.text), "{case}");
                    let flipped = merge(base, theirs, ours, Labels::default());
                    assert_eq!(merged.conflicted, flipped.conflicted, "{case}");
                    if !merged.conflicted {
                        assert_eq!(merged.text, flipped.text, "{case}");
                    }
                    // Every line written came from one of the sides.
                    for line in crate::conflict::resolve(&merged.text, crate::conflict::Keep::Both).lines() {
                        assert!(ours.lines().any(|l| l == line) || theirs.lines().any(|l| l == line), "{case}: {line:?}");
                    }
                }
            }
        }
    }
}
