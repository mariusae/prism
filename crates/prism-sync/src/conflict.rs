//! Conflict markers: how a note carries a conflict until someone settles it.
//!
//! A merge that conflicts writes git's markers into the file — labelled
//! `this device` and `other device` rather than with branch names — and
//! commits it. The note carries the conflict; nothing waits on it.
//!
//! A text has a conflict only when a whole block is there, in order:
//! `<<<<<<< ` then `=======` then `>>>>>>> `. Prose that mentions one
//! marker line is not one. These are the rules of Reflect's
//! `conflict_markers.rs`, so graphs shared with it resolve the same way.

/// The label on this device's side of a conflict.
pub const OUR_LABEL: &str = "this device";
/// The label on the other device's side.
pub const THEIR_LABEL: &str = "other device";

/// Which side of each block to keep.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Keep {
    /// The first side: this device's.
    Ours,
    /// The second side.
    Theirs,
    /// Both, first then second.
    Both,
}

/// One side of a conflict.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Side {
    /// The label on its marker line.
    pub label: String,
    /// The side's lines, joined with line breaks; may be empty.
    pub text: String,
}

/// A run of plain text, or one whole conflict block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Segment {
    Text(String),
    Conflict { ours: Side, theirs: Side },
}

/// A text's lines as written, and each without the carriage return a
/// Windows line break leaves on it.
fn lines(source: &str) -> impl Iterator<Item = (&str, &str)> {
    source.split('\n').map(|raw| (raw, raw.strip_suffix('\r').unwrap_or(raw)))
}

/// How many whole conflict blocks a text holds.
pub fn count(source: &str) -> usize {
    let (mut count, mut stage) = (0, 0);
    for (_, line) in lines(source) {
        match stage {
            0 if line.starts_with("<<<<<<< ") => stage = 1,
            1 if line == "=======" => stage = 2,
            2 if line.starts_with(">>>>>>> ") => {
                count += 1;
                stage = 0;
            }
            _ => {}
        }
    }
    count
}

/// Whether a text holds a whole conflict block.
pub fn detect(source: &str) -> bool {
    count(source) > 0
}

/// Resolves every block by keeping the chosen side, or both. Everything
/// outside the blocks stays byte for byte; a block cut off before its end
/// keeps what was chosen of it.
pub fn resolve(source: &str, keep: Keep) -> String {
    #[derive(PartialEq)]
    enum Section {
        Text,
        Ours,
        Theirs,
    }
    let mut out: Vec<&str> = Vec::new();
    let mut section = Section::Text;
    for (raw, line) in lines(source) {
        match section {
            Section::Text if line.starts_with("<<<<<<< ") => section = Section::Ours,
            Section::Text => out.push(raw),
            Section::Ours if line == "=======" => section = Section::Theirs,
            Section::Ours => {
                if keep != Keep::Theirs {
                    out.push(raw);
                }
            }
            Section::Theirs if line.starts_with(">>>>>>> ") => section = Section::Text,
            Section::Theirs => {
                if keep != Keep::Ours {
                    out.push(raw);
                }
            }
        }
    }
    out.join("\n")
}

/// The text as runs of plain text and whole blocks, in order: what a
/// review screen shows. A block cut off before its end goes back into the
/// text, marker lines and all.
pub fn segments(source: &str) -> Vec<Segment> {
    let mut segments = Vec::new();
    let mut text: Vec<&str> = Vec::new();
    // The lines of a block being read, in case it is never closed.
    let mut pending: Vec<&str> = Vec::new();
    let (mut ours, mut theirs): (Vec<&str>, Vec<&str>) = (Vec::new(), Vec::new());
    let mut our_label = "";
    let mut stage = 0;
    for (raw, line) in lines(source) {
        match stage {
            0 if line.starts_with("<<<<<<< ") => {
                stage = 1;
                our_label = line[8..].trim();
                pending = vec![raw];
                ours.clear();
                theirs.clear();
            }
            0 => text.push(raw),
            1 => {
                pending.push(raw);
                if line == "=======" {
                    stage = 2;
                } else {
                    ours.push(raw);
                }
            }
            _ if line.starts_with(">>>>>>> ") => {
                if !text.is_empty() {
                    segments.push(Segment::Text(std::mem::take(&mut text).join("\n")));
                }
                segments.push(Segment::Conflict {
                    ours: Side { label: our_label.to_owned(), text: ours.join("\n") },
                    theirs: Side { label: line[8..].trim().to_owned(), text: theirs.join("\n") },
                });
                stage = 0;
                pending.clear();
            }
            _ => {
                pending.push(raw);
                theirs.push(raw);
            }
        }
    }
    if stage != 0 {
        text.append(&mut pending);
    }
    if !text.is_empty() {
        segments.push(Segment::Text(text.join("\n")));
    }
    segments
}

/// `assets/img.png` → `assets/img (conflict).png`: where the other side's
/// copy of a binary file both changed is put. Only the file's own name is
/// split, so a dot in a directory's name stays put.
pub fn copy_path(path: &str) -> String {
    let (directory, file) = match path.rfind('/') {
        Some(slash) => path.split_at(slash + 1),
        None => ("", path),
    };
    match file.rfind('.').filter(|dot| *dot > 0) {
        Some(dot) => format!("{directory}{} (conflict){}", &file[..dot], &file[dot..]),
        None => format!("{directory}{file} (conflict)"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOTE: &str = "before\n<<<<<<< this device\nmine\nmore mine\n=======\ntheirs\n>>>>>>> other device\nafter\n";

    #[test]
    fn only_whole_blocks_count() {
        assert_eq!(count(NOTE), 1);
        assert!(detect(NOTE));
        for prose in ["<<<<<<< this device\nno more\n", "=======\n>>>>>>> x\n", "a\n=======\nb\n", "<<<<<<<no space\n=======\n>>>>>>> x\n", ""] {
            assert!(!detect(prose), "{prose:?}");
        }
        assert_eq!(count(&NOTE.repeat(3)), 3);
        assert!(detect(&NOTE.replace('\n', "\r\n")));
    }

    #[test]
    fn resolving_keeps_one_side_or_both() {
        assert_eq!(resolve(NOTE, Keep::Ours), "before\nmine\nmore mine\nafter\n");
        assert_eq!(resolve(NOTE, Keep::Theirs), "before\ntheirs\nafter\n");
        assert_eq!(resolve(NOTE, Keep::Both), "before\nmine\nmore mine\ntheirs\nafter\n");
        assert_eq!(resolve("no conflict\n", Keep::Theirs), "no conflict\n");
    }

    #[test]
    fn segments_are_text_and_blocks_in_order() {
        assert_eq!(
            segments(NOTE),
            [
                Segment::Text("before".into()),
                Segment::Conflict {
                    ours: Side { label: "this device".into(), text: "mine\nmore mine".into() },
                    theirs: Side { label: "other device".into(), text: "theirs".into() },
                },
                Segment::Text("after\n".into()),
            ]
        );
        // A block never closed is text, markers and all.
        let cut = "a\n<<<<<<< this device\nmine\n=======\ntheirs";
        assert_eq!(segments(cut), [Segment::Text(cut.into())]);
    }

    #[test]
    fn conflict_copies_are_named_beside_the_file() {
        assert_eq!(copy_path("assets/img.png"), "assets/img (conflict).png");
        assert_eq!(copy_path("assets/v1.2/archive.tar.gz"), "assets/v1.2/archive.tar (conflict).gz");
        assert_eq!(copy_path("LICENSE"), "LICENSE (conflict)");
        assert_eq!(copy_path("dir/.hidden"), "dir/.hidden (conflict)");
    }
}
