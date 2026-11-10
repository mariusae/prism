//! Commit messages that say what was written.
//!
//! `Update daily note for 2026-09-25`, `Add Project Atlas`, `Rename Old to
//! New`, `Update 2 notes and 1 attachment` — Reflect's words, by the rules
//! of its `commit_message.rs`, so a history written by both reads as one.
//! A private note is never named.

use prism_markup::{Note, NoteKind};
use prism_sync::{Change, ChangeKind, Describe, Pending};

/// Words commits as a graph of notes should read. Give it to
/// [`Syncer::with_describer`](prism_sync::Syncer::with_describer).
pub struct NoteDescriber;

impl Describe for NoteDescriber {
    fn describe(&self, pending: &Pending<'_>) -> String {
        let changes: Vec<Described> = pending
            .changes
            .iter()
            .filter(|change| change.path != ".gitignore" && change.path != ".gitattributes")
            .map(|change| {
                // A deleted note is named by what it said; any other, by
                // what it says now.
                let text = if change.new.is_some() { pending.new_text(change) } else { pending.old_text(change) };
                Described {
                    action: Action::of(change),
                    label: note_label(&change.path, text.as_deref()),
                    old_label: change.renamed_from.as_deref().and_then(|old| note_label(old, pending.old_text(change).as_deref())),
                    attachment: is_attachment(&change.path),
                }
            })
            .collect();
        describe(&changes)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Action {
    Add,
    Update,
    Delete,
    Rename,
}

impl Action {
    fn of(change: &Change) -> Action {
        match change.kind() {
            ChangeKind::Added => Action::Add,
            ChangeKind::Modified => Action::Update,
            ChangeKind::Deleted => Action::Delete,
            ChangeKind::Renamed => Action::Rename,
        }
    }

    fn verb(self) -> &'static str {
        match self {
            Action::Add => "Add",
            Action::Update => "Update",
            Action::Delete => "Delete",
            Action::Rename => "Rename",
        }
    }
}

/// One changed path, as a message sees it.
struct Described {
    action: Action,
    /// What a note is called; `None` for a file that is no note.
    label: Option<String>,
    old_label: Option<String>,
    attachment: bool,
}

const FALLBACK: &str = "Update notes";

fn describe(changes: &[Described]) -> String {
    if changes.is_empty() {
        return FALLBACK.into();
    }
    let notes: Vec<&Described> = changes.iter().filter(|c| c.label.is_some()).collect();
    let attachments = changes.iter().filter(|c| c.label.is_none() && c.attachment).count();
    let others = changes.len() - notes.len() - attachments;
    let count = |n: usize, one: &str, many: &str| if n == 1 { format!("1 {one}") } else { format!("{n} {many}") };
    // All the same action is that action; a mixture is an update.
    fn group(mut actions: impl Iterator<Item = Action>) -> Action {
        let first = actions.next().unwrap_or(Action::Update);
        if actions.all(|a| a == first) {
            first
        } else {
            Action::Update
        }
    }
    if notes.len() == changes.len() {
        if let [note] = notes[..] {
            let label = note.label.as_deref().unwrap_or_default();
            return limit(match (&note.action, &note.old_label) {
                (Action::Rename, Some(old)) => format!("Rename {old} to {label}"),
                (action, _) => format!("{} {label}", action.verb()),
            });
        }
        return limit(format!("{} {}", group(notes.iter().map(|n| n.action)).verb(), count(notes.len(), "note", "notes")));
    }
    if attachments == changes.len() {
        return limit(format!("{} {}", group(changes.iter().map(|c| c.action)).verb(), count(attachments, "attachment", "attachments")));
    }
    if notes.is_empty() {
        return FALLBACK.into();
    }
    let verb = group(changes.iter().map(|c| c.action)).verb();
    if others == 0 {
        return limit(format!("{verb} {} and {}", count(notes.len(), "note", "notes"), count(attachments, "attachment", "attachments")));
    }
    limit(format!("{verb} {} and {}", count(notes.len(), "note", "notes"), count(changes.len() - notes.len(), "file", "files")))
}

/// What a note is called in a commit message: `daily note for …`, its
/// title, `private note`, or its file's name made readable. `None` for a
/// path that is no note.
fn note_label(path: &str, source: Option<&str>) -> Option<String> {
    let kind = NoteKind::of(path)?;
    let note = source.map(Note::parse);
    if note.as_ref().is_some_and(|n| n.flag("private")) {
        return Some("private note".into());
    }
    match kind {
        NoteKind::Day(day) => Some(format!("daily note for {day}")),
        NoteKind::Week(week) => Some(format!("weekly note for {week}")),
        NoteKind::Note => {
            let stem = path.rsplit('/').next()?.strip_suffix(".md")?;
            let fallback = humanize(stem);
            let titled =
                note.filter(|n| n.field("title").is_some_and(|t| !t.trim().is_empty()) || n.title_heading().is_some()).map(|n| collapse(&n.title(path)));
            titled.filter(|t| !t.is_empty()).or(Some(fallback)).filter(|label| !label.is_empty())
        }
    }
}

fn is_attachment(path: &str) -> bool {
    path.starts_with("assets/") || path.starts_with("audio-memos/")
}

fn limit(subject: String) -> String {
    if subject.chars().count() <= 72 {
        subject
    } else {
        format!("{}...", subject.chars().take(69).collect::<String>())
    }
}

fn collapse(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `my-project_notes` → `My Project Notes`; left alone if it has capitals.
fn humanize(stem: &str) -> String {
    let spaced: String = stem.chars().map(|c| if c == '-' || c == '_' || c.is_control() { ' ' } else { c }).collect();
    let normalized = collapse(&spaced);
    if normalized.chars().any(char::is_uppercase) {
        return normalized;
    }
    normalized
        .split(' ')
        .map(|word| {
            let mut chars = word.chars();
            chars.next().map(|first| first.to_uppercase().chain(chars).collect::<String>()).unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn note(action: Action, path: &str, source: &str) -> Described {
        Described { action, label: note_label(path, Some(source)), old_label: None, attachment: is_attachment(path) }
    }

    fn file(action: Action, path: &str) -> Described {
        Described { action, label: note_label(path, None), old_label: None, attachment: is_attachment(path) }
    }

    #[test]
    fn one_note_is_named() {
        assert_eq!(describe(&[note(Action::Update, "daily/2026-09-25.md", "- x\n")]), "Update daily note for 2026-09-25");
        assert_eq!(describe(&[note(Action::Add, "notes/atlas.md", "# Project   Atlas\n")]), "Add Project Atlas");
        assert_eq!(describe(&[note(Action::Delete, "notes/atlas.md", "---\ntitle: a field\n---\n# Heading\n")]), "Delete Heading");
        assert_eq!(describe(&[note(Action::Update, "notes/my-project_notes.md", "no heading\n")]), "Update My Project Notes");
        assert_eq!(describe(&[note(Action::Update, "notes/McKinsey-notes.md", "")]), "Update McKinsey notes");
        assert_eq!(describe(&[note(Action::Add, "weekly/2026-W44.md", "- plan\n")]), "Add weekly note for 2026-W44");
    }

    #[test]
    fn a_private_note_is_never_named() {
        assert_eq!(describe(&[note(Action::Add, "notes/secret.md", "---\nprivate: true\n---\n# The Secret Plan\n")]), "Add private note");
        assert_eq!(describe(&[note(Action::Update, "daily/2026-09-25.md", "---\nprivate: yes\n---\n")]), "Update private note");
    }

    #[test]
    fn a_rename_names_both() {
        let mut renamed = note(Action::Rename, "notes/new.md", "# New\n");
        renamed.old_label = note_label("notes/old.md", Some("# Old\n"));
        assert_eq!(describe(&[renamed]), "Rename Old to New");
    }

    #[test]
    fn several_changes_are_counted() {
        let a = || note(Action::Update, "notes/a.md", "# A\n");
        let added = || note(Action::Add, "notes/b.md", "# B\n");
        let picture = || file(Action::Add, "assets/pic.png");
        assert_eq!(describe(&[a(), a()]), "Update 2 notes");
        assert_eq!(describe(&[added(), added(), added()]), "Add 3 notes");
        assert_eq!(describe(&[a(), added()]), "Update 2 notes");
        assert_eq!(describe(&[picture()]), "Add 1 attachment");
        assert_eq!(describe(&[picture(), file(Action::Delete, "audio-memos/m.m4a")]), "Update 2 attachments");
        assert_eq!(describe(&[a(), a(), picture()]), "Update 2 notes and 1 attachment");
        assert_eq!(describe(&[added(), picture()]), "Add 1 note and 1 attachment");
        assert_eq!(describe(&[a(), picture(), file(Action::Update, "README.md")]), "Update 1 note and 2 files");
        assert_eq!(describe(&[file(Action::Update, "README.md")]), "Update notes");
        assert_eq!(describe(&[]), "Update notes");
    }

    #[test]
    fn long_subjects_are_cut() {
        let subject = describe(&[note(Action::Add, "notes/long.md", &format!("# {}\n", "word ".repeat(30)))]);
        assert_eq!(subject.chars().count(), 72);
        assert!(subject.ends_with("..."));
    }
}
