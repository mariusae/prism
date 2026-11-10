//! Merging two devices' changes to one note.
//!
//! Lines are the wrong unit for frontmatter. Two devices that each touch a
//! note both rewrite its `modified:` line; two that each add a tag both
//! rewrite the `tags:` line — and a line merge calls every such pair a
//! conflict. So a note's frontmatter is merged **field by field**, and
//! only its body by lines:
//!
//! - a list (`tags`, `aliases`, `related`, any list) is merged as a set:
//!   what either added is kept, what either removed is gone;
//! - any other field changed on one side takes that side's value; changed
//!   on both, this device's — the one doing the merge — with the other's
//!   still in history.
//!
//! The merged frontmatter is written over this device's, so its comments,
//! order and spacing stay as they were.

use prism_markup::{Frontmatter, Value};
use prism_sync::textmerge::{self, Labels};
use prism_sync::{FileMerge, MergeDriver};

/// A [`MergeDriver`] for a graph: notes are merged as notes, everything
/// else by lines. Give it to
/// [`Syncer::with_merge_driver`](prism_sync::Syncer::with_merge_driver).
pub struct NoteMergeDriver;

impl MergeDriver for NoteMergeDriver {
    fn merge(&self, path: &str, base: Option<&[u8]>, ours: &[u8], theirs: &[u8]) -> Option<FileMerge> {
        if !path.ends_with(".md") {
            return None;
        }
        let text = |bytes: &[u8]| std::str::from_utf8(bytes).ok().map(str::to_owned);
        let merged = merge_notes(base.and_then(text).as_deref(), &text(ours)?, &text(theirs)?, Labels::default())?;
        Some(FileMerge { content: merged.text.into_bytes(), conflicted: merged.conflicted })
    }
}

/// Merges two versions of a note from the version both came from (`None`
/// when both made the note). `None` back when neither side has
/// frontmatter to merge — the note is then merged by lines like any text —
/// or when only one has: a block one side added or took away whole is
/// better left to lines.
///
/// Also what an editor calls when it saves a draft over a file that
/// changed underneath it: `ours` the draft, `theirs` the file, `base` the
/// file as the draft was opened.
pub fn merge_notes(base: Option<&str>, ours: &str, theirs: &str, labels: Labels<'_>) -> Option<textmerge::Merged> {
    let (Some(mut front), our_body) = Frontmatter::split(ours) else { return None };
    let (Some(their_front), their_body) = Frontmatter::split(theirs) else { return None };
    let (base_front, base_body) = match base.map(Frontmatter::split) {
        Some((front, body)) => (front, body),
        None => (None, ""),
    };
    let base_front = base_front.unwrap_or_default();
    let our_front = front.clone();

    let mut keys: Vec<String> = our_front.keys().map(str::to_owned).collect();
    for key in their_front.keys().chain(base_front.keys()) {
        if !keys.iter().any(|k| k == key) {
            keys.push(key.to_owned());
        }
    }
    for key in keys {
        let (b, o, t) = (base_front.get(&key), our_front.get(&key), their_front.get(&key));
        let merged: Option<Value> = if let (Some(Value::List(o)), Some(Value::List(t))) = (o, t) {
            let base_items = b.map(Value::to_list).unwrap_or_default();
            Some(Value::List(merge_list(&base_items, o, t)))
        } else {
            pick(b, o, t).cloned()
        };
        match merged {
            Some(value) => front.set(&key, value),
            None => {
                front.remove(&key);
            }
        }
    }
    let body = textmerge::merge_lenient(base_body, our_body, their_body, labels);
    Some(textmerge::Merged { text: format!("{front}{}", body.text), conflicted: body.conflicted })
}

/// The side that changed; when both did, ours.
fn pick<'a, T: PartialEq>(base: Option<&'a T>, ours: Option<&'a T>, theirs: Option<&'a T>) -> Option<&'a T> {
    if ours == base {
        theirs
    } else {
        ours
    }
}

/// This device's list, without what the other took out, with what the
/// other put in after it.
fn merge_list(base: &[String], ours: &[String], theirs: &[String]) -> Vec<String> {
    let mut merged: Vec<String> = ours.iter().filter(|item| !(base.contains(item) && !theirs.contains(item))).cloned().collect();
    for item in theirs {
        if !base.contains(item) && !merged.contains(item) {
            merged.push(item.clone());
        }
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;

    fn merge(base: &str, ours: &str, theirs: &str) -> (String, bool) {
        let merged = merge_notes(Some(base), ours, theirs, Labels::default()).expect("notes with frontmatter");
        (merged.text, merged.conflicted)
    }

    const BASE: &str = "---\ntags: [a, b]\nrating: 1\nstatus: draft\n---\n# Note\n\n- one\n- two\n";

    #[test]
    fn two_devices_touching_one_note_do_not_conflict() {
        // Each added a tag, one set a field, each edited another line: by
        // lines, the tags are a conflict.
        let ours = BASE.replace("[a, b]", "[a, b, mine]").replace("- one", "- ONE");
        let theirs = BASE.replace("[a, b]", "[a, b, yours]").replace("rating: 1", "rating: 5").replace("- two", "- TWO");
        assert!(textmerge::merge(BASE, &ours, &theirs, Labels::default()).conflicted);
        let (text, conflicted) = merge(BASE, &ours, &theirs);
        assert!(!conflicted);
        assert_eq!(text, "---\ntags: [a, b, mine, yours]\nrating: 5\nstatus: draft\n---\n# Note\n\n- ONE\n- TWO\n");
    }

    #[test]
    fn lists_merge_as_sets() {
        let ours = BASE.replace("[a, b]", "[b, c]"); // took `a` out, put `c` in
        let theirs = BASE.replace("[a, b]", "[a, d]"); // took `b` out, put `d` in
        assert!(merge(BASE, &ours, &theirs).0.starts_with("---\ntags: [c, d]\n"));
        let vec = |items: &[&str]| items.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(merge_list(&vec(&["a"]), &vec(&["a", "x"]), &vec(&["a", "x"])), vec(&["a", "x"]));
        assert_eq!(merge_list(&[], &vec(&["x"]), &vec(&["y"])), vec(&["x", "y"]));
    }

    #[test]
    fn a_field_both_changed_stays_as_this_device_has_it() {
        let ours = BASE.replace("draft", "mine");
        let theirs = BASE.replace("draft", "yours");
        assert!(merge(BASE, &ours, &theirs).0.contains("status: mine\n"));
        assert!(merge(BASE, &theirs, &ours).0.contains("status: yours\n"));
        // Only one changed it: that one.
        assert!(merge(BASE, BASE, &theirs).0.contains("status: yours\n"));
        assert!(merge(BASE, &ours, BASE).0.contains("status: mine\n"));
    }

    #[test]
    fn fields_are_added_and_removed() {
        let ours = BASE.replace("status: draft\n", "status: draft\npinned: true\n");
        let theirs = BASE.replace("status: draft\n", "wiki: true\n");
        let (text, _) = merge(BASE, &ours, &theirs);
        assert_eq!(text.lines().take(5).collect::<Vec<_>>(), ["---", "tags: [a, b]", "rating: 1", "pinned: true", "wiki: true"]);
    }

    #[test]
    fn our_formatting_is_kept() {
        let base = "---\n# keep this comment\ntags:   [a]\ntitle: 'Quoted'\n---\nbody\n";
        let ours = base.replace("body", "our body");
        let theirs = "---\ntags: [a, b]\ntitle: Quoted\n---\nbody\n";
        let (text, conflicted) = merge(base, &ours, theirs);
        assert!(!conflicted);
        assert_eq!(text, "---\n# keep this comment\ntags: [a, b]\ntitle: 'Quoted'\n---\nour body\n");
    }

    #[test]
    fn bodies_that_clash_still_conflict_with_one_frontmatter() {
        let ours = BASE.replace("- one", "- mine").replace("[a, b]", "[a, b, x]");
        let theirs = BASE.replace("- one", "- yours");
        let (text, conflicted) = merge(BASE, &ours, &theirs);
        assert!(conflicted);
        assert!(text.starts_with("---\ntags: [a, b, x]\n"));
        assert!(text.contains("<<<<<<< this device\n- mine\n=======\n- yours\n>>>>>>> other device\n"));
        assert_eq!(text.matches("---\n").count(), 2, "the frontmatter is there once");
    }

    #[test]
    fn both_making_the_same_note_merges_their_fields() {
        let ours = "---\ntags: [a]\n---\n- mine\n";
        let theirs = "---\ntags: [b]\nid: 01jbxk3t6y8q2zp4m9v7c5r0wd\n---\n- mine\n";
        let merged = merge_notes(None, ours, theirs, Labels::default()).unwrap();
        assert_eq!((merged.text.as_str(), merged.conflicted), ("---\ntags: [a, b]\nid: 01jbxk3t6y8q2zp4m9v7c5r0wd\n---\n- mine\n", false));
    }

    #[test]
    fn notes_without_frontmatter_are_left_to_lines() {
        assert!(merge_notes(Some("a\n"), "b\n", "c\n", Labels::default()).is_none());
        assert!(merge_notes(Some(BASE), BASE, "no frontmatter\n", Labels::default()).is_none());
        assert!(NoteMergeDriver.merge("assets/data.json", None, b"{}", b"[]").is_none());
        assert!(NoteMergeDriver.merge("notes/a.md", None, b"plain\n", b"text\n").is_none());
        let merged = NoteMergeDriver.merge("notes/a.md", Some(BASE.as_bytes()), BASE.replace("draft", "done").as_bytes(), BASE.as_bytes()).unwrap();
        assert!(!merged.conflicted && String::from_utf8(merged.content).unwrap().contains("status: done"));
    }
}
