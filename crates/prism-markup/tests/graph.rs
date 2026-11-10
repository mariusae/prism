//! Round-trips a real graph: `PRISM_GRAPH=~/notes cargo test -p prism-markup --test graph -- --nocapture`.
//!
//! Every Markdown file under the graph is read and written back, and must
//! come back byte for byte. The test also reports how much of the graph
//! was understood rather than kept raw. Without `PRISM_GRAPH` it does
//! nothing. The graph is only read.

use prism_markup::{inline, BlockKind, Note};
use std::path::{Path, PathBuf};

fn markdown_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        if path.is_dir() {
            markdown_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "md") {
            out.push(path);
        }
    }
}

#[test]
fn a_real_graph_round_trips() {
    let Some(root) = std::env::var_os("PRISM_GRAPH") else { return };
    let mut files = Vec::new();
    markdown_files(Path::new(&root), &mut files);
    let (mut blocks, mut raw, mut raw_files, mut spans) = (0usize, 0usize, 0usize, 0usize);
    let mut failures = Vec::new();
    for file in &files {
        let Ok(source) = std::fs::read_to_string(file) else { continue };
        let note = Note::parse(&source);
        if note.to_markdown() != source {
            failures.push(file.display().to_string());
        }
        let before = raw;
        for block in note.body.walk() {
            blocks += 1;
            if block.kind == BlockKind::Raw {
                raw += 1;
            } else if block.has_inline_content() {
                spans += inline::walk(&inline::parse(&block.text)).count();
            }
        }
        raw_files += usize::from(raw > before);
        // Extraction must never panic on real text.
        let _ = note.meta("notes/x.md");
        let _ = note.plain_text();
    }
    println!("{} notes, {blocks} blocks, {spans} inline spans; {raw} blocks kept raw, in {raw_files} notes", files.len());
    assert!(failures.is_empty(), "did not round-trip: {failures:#?}");
}
