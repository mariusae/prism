//! Outline editing: the commands an outliner gives, on a [`Document`].
//!
//! Every command names its block by **path** — an index at each level,
//! outermost first, as [`Document::rows`] gives them — and answers with
//! the path the block has afterwards, so an editor can keep its caret on
//! it. A command that cannot be done (indenting a first child, a path that
//! leads nowhere) changes nothing and answers `None`.
//!
//! One rule runs through all of them: **a block takes its children with
//! it** — when indented, outdented, moved, duplicated or removed.

use crate::block::{Block, BlockKind, Document, Item, Marker, Task};

/// A block's place in a document.
pub type Path = Vec<usize>;

/// Makes a block the last child of the block before it. Only a list item
/// can take children, since that is all Markdown can nest.
pub fn indent(document: &mut Document, path: &[usize]) -> Option<Path> {
    let (&index, parent) = path.split_last()?;
    if index == 0 {
        return None;
    }
    let siblings = document.siblings_mut(path)?;
    if index >= siblings.len() || !siblings[index - 1].can_have_children() {
        return None;
    }
    let block = siblings.remove(index);
    let host = &mut siblings[index - 1];
    host.children.push(block);
    let mut moved = parent.to_vec();
    moved.extend([index - 1, host.children.len() - 1]);
    Some(moved)
}

/// Moves a block out a level, children and all, to just after its
/// parent's whole branch. The siblings that followed it stay under the
/// parent — as Bike 2 does; [`demote_siblings`] is the other way.
pub fn outdent(document: &mut Document, path: &[usize]) -> Option<Path> {
    let (&index, parent_path) = path.split_last()?;
    let (&parent_index, _) = parent_path.split_last()?;
    let parent = document.get_mut(parent_path)?;
    if index >= parent.children.len() {
        return None;
    }
    let block = parent.children.remove(index);
    let mut moved = parent_path.to_vec();
    *moved.last_mut()? = parent_index + 1;
    document.siblings_mut(parent_path)?.insert(parent_index + 1, block);
    Some(moved)
}

/// Moves a block out a level, to just after its parent, the siblings that
/// followed it coming under it — the row alone pulled left, as the lines
/// of an outline read then. When it cannot hold them they stay where they
/// were.
pub fn outdent_taking_followers(document: &mut Document, path: &[usize]) -> Option<Path> {
    let (&index, parent_path) = path.split_last()?;
    let (&parent_index, _) = parent_path.split_last()?;
    let parent = document.get_mut(parent_path)?;
    if index >= parent.children.len() {
        return None;
    }
    let followers = if parent.children[index].can_have_children() { parent.children.split_off(index + 1) } else { Vec::new() };
    let mut block = parent.children.remove(index);
    block.children.extend(followers);
    let mut moved = parent_path.to_vec();
    *moved.last_mut()? = parent_index + 1;
    document.siblings_mut(parent_path)?.insert(parent_index + 1, block);
    Some(moved)
}

/// Swaps a block with the sibling before it.
pub fn move_up(document: &mut Document, path: &[usize]) -> Option<Path> {
    let (&index, parent) = path.split_last()?;
    let siblings = document.siblings_mut(path)?;
    if index == 0 || index >= siblings.len() {
        return None;
    }
    siblings.swap(index, index - 1);
    carry_gap(siblings, index - 1, index);
    Some([parent, &[index - 1]].concat())
}

/// Swaps a block with the sibling after it.
pub fn move_down(document: &mut Document, path: &[usize]) -> Option<Path> {
    let (&index, parent) = path.split_last()?;
    let siblings = document.siblings_mut(path)?;
    if index + 1 >= siblings.len() {
        return None;
    }
    siblings.swap(index, index + 1);
    carry_gap(siblings, index, index + 1);
    Some([parent, &[index + 1]].concat())
}

/// After a swap, the blank lines stay where they were on the page: they
/// belong to the place, not the block that was moved through it.
fn carry_gap(siblings: &mut [Block], first: usize, second: usize) {
    let gap = std::mem::take(&mut siblings[first].layout.gap);
    siblings[first].layout.gap = std::mem::replace(&mut siblings[second].layout.gap, gap);
}

/// Takes a block out, children and all, and gives it back.
pub fn remove(document: &mut Document, path: &[usize]) -> Option<Block> {
    let index = *path.last()?;
    let siblings = document.siblings_mut(path)?;
    (index < siblings.len()).then(|| siblings.remove(index))
}

/// Puts a block in at a path, moving what was there (and after) down.
/// A path one past a list's end appends.
pub fn insert(document: &mut Document, path: &[usize], block: Block) -> Option<Path> {
    let index = *path.last()?;
    let siblings = document.siblings_mut(path)?;
    if index > siblings.len() {
        return None;
    }
    siblings.insert(index, block);
    Some(path.to_vec())
}

/// Puts a copy of a block, children and all, straight after it.
pub fn duplicate(document: &mut Document, path: &[usize]) -> Option<Path> {
    let (&index, parent) = path.split_last()?;
    let siblings = document.siblings_mut(path)?;
    let mut copy = siblings.get(index)?.clone();
    copy.layout.gap.clear();
    // A copy is another block: it has no name until it is given one.
    fn unnamed(block: &mut Block) {
        block.anchor = None;
        block.children.iter_mut().for_each(unnamed);
    }
    unnamed(&mut copy);
    siblings.insert(index + 1, copy);
    Some([parent, &[index + 1]].concat())
}

/// Splits a block's text at a byte offset — what Return does. The text
/// after the offset becomes a new block of the same sort: a bullet after a
/// bullet, an open task after any task, the next number after a numbered
/// item, a paragraph after a heading. At the end of a block with children,
/// the new block is its first child; otherwise it follows the block, and
/// the children stay with the first half.
pub fn split(document: &mut Document, path: &[usize], offset: usize) -> Option<Path> {
    let block = document.get_mut(path)?;
    if !block.text.is_char_boundary(offset) || !matches!(block.kind, BlockKind::Paragraph | BlockKind::Heading(_) | BlockKind::Item(_) | BlockKind::Quote) {
        return None;
    }
    let tail = block.text.split_off(offset);
    let kind = match &block.kind {
        BlockKind::Item(item) => BlockKind::Item(Item {
            marker: match item.marker {
                Marker::Ordered { number, delimiter } => Marker::Ordered { number: number + 1, delimiter },
                bullet => bullet,
            },
            task: item.task.map(|_| Task::Open),
        }),
        BlockKind::Heading(_) => BlockKind::Paragraph,
        other => other.clone(),
    };
    let mut new = Block::new(kind, tail);
    new.layout.spacing = block.layout.spacing.max(1);
    // Under a parent whose children are shown, the new row is its first
    // child — what follows the parent's words on the page. Under a folded
    // one it comes after the whole branch, and the hidden rows stay.
    if !block.children.is_empty() && block.is_item() && !block.folded {
        block.children.insert(0, new);
        return Some([path, &[0]].concat());
    }
    let (&index, parent) = path.split_last()?;
    let siblings = document.siblings_mut(path)?;
    siblings.insert(index + 1, new);
    renumber(siblings);
    Some([parent, &[index + 1]].concat())
}

/// The sort of row that follows a row of this sort: a bullet after a
/// bullet, an open task after any task, the next number after a numbered
/// item, a plain line after a heading.
pub fn next_kind(kind: &BlockKind) -> BlockKind {
    match kind {
        BlockKind::Item(item) => BlockKind::Item(Item {
            marker: match item.marker {
                Marker::Ordered { number, delimiter } => Marker::Ordered { number: number + 1, delimiter },
                bullet => bullet,
            },
            task: item.task.map(|_| Task::Open),
        }),
        BlockKind::Heading(_) => BlockKind::Paragraph,
        other => other.clone(),
    }
}

/// Where a new, empty row goes, beside a row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Beside {
    /// After the row's whole branch.
    Below,
    /// Before it.
    Above,
    /// Its first child.
    Child,
}

/// Puts a new, empty row beside a row — ⌘↩, ⇧⌘↩, ⌥⌘↩ — of the sort that
/// follows it. A row that cannot hold children gets the new row below
/// it instead of under it. Answers the new row's path.
pub fn insert_row(document: &mut Document, path: &[usize], beside: Beside) -> Option<Path> {
    let block = document.get_mut(path)?;
    let kind = match &block.kind {
        BlockKind::Paragraph | BlockKind::Heading(_) | BlockKind::Item(_) | BlockKind::Quote => next_kind(&block.kind),
        _ => BlockKind::Item(Item { marker: Marker::Bullet('-'), task: None }),
    };
    let mut new = Block::new(kind, "");
    new.layout.spacing = block.layout.spacing.max(1);
    if beside == Beside::Child && block.can_have_children() {
        block.folded = false;
        block.children.insert(0, new);
        return Some([path, &[0]].concat());
    }
    let (&index, parent) = path.split_last()?;
    let at = if beside == Beside::Above { index } else { index + 1 };
    let siblings = document.siblings_mut(path)?;
    siblings.insert(at, new);
    renumber(siblings);
    Some([parent, &[at]].concat())
}

/// Joins the row after a row into it — ⌃⌘⌫ — a space between their words
/// (none if either is empty or already has one there). Its children come
/// under the joined row. Answers the row and where the two meet.
pub fn join_next(document: &mut Document, path: &[usize], next: &[usize]) -> Option<(Path, usize)> {
    let space = {
        let (this, that) = (&document.get(path)?.text, &document.get(next)?.text);
        !this.is_empty() && !that.is_empty() && !this.ends_with(char::is_whitespace) && !that.starts_with(char::is_whitespace)
    };
    let (onto, offset) = join_onto(document, next, path)?;
    let block = document.get_mut(&onto)?;
    if space {
        block.text.insert(offset, ' ');
    }
    Some((onto, offset))
}

/// A row's children made the siblings that follow it.
pub fn promote_children(document: &mut Document, path: &[usize]) -> Option<Path> {
    let index = *path.last()?;
    let block = document.get_mut(path)?;
    if block.children.is_empty() {
        return None;
    }
    block.folded = false;
    let children = std::mem::take(&mut block.children);
    let siblings = document.siblings_mut(path)?;
    siblings.splice(index + 1..index + 1, children);
    renumber(siblings);
    Some(path.to_vec())
}

/// The siblings that follow a row made its last children.
pub fn demote_siblings(document: &mut Document, path: &[usize]) -> Option<Path> {
    let index = *path.last()?;
    if !document.get(path)?.can_have_children() {
        return None;
    }
    let siblings = document.siblings_mut(path)?;
    if index + 1 >= siblings.len() {
        return None;
    }
    let followers: Vec<Block> = siblings.drain(index + 1..).collect();
    let block = document.get_mut(path)?;
    block.folded = false;
    block.children.extend(followers);
    Some(path.to_vec())
}

/// A row taken out, its children taking its place.
pub fn remove_row_only(document: &mut Document, path: &[usize]) -> Option<Block> {
    let index = *path.last()?;
    let siblings = document.siblings_mut(path)?;
    if index >= siblings.len() {
        return None;
    }
    let mut block = siblings.remove(index);
    let children = std::mem::take(&mut block.children);
    siblings.splice(index..index, children);
    renumber(siblings);
    Some(block)
}

/// Rows — siblings, in order — put under a new, empty row put where the
/// first was. Answers the new row's path.
pub fn group(document: &mut Document, paths: &[Path]) -> Option<Path> {
    let first = paths.first()?.clone();
    let parent = &first[..first.len() - 1];
    if paths.iter().any(|path| &path[..path.len() - 1] != parent) {
        return None;
    }
    let mut indexes: Vec<usize> = paths.iter().map(|path| path[path.len() - 1]).collect();
    indexes.sort_unstable();
    let siblings = document.siblings_mut(&first)?;
    let mut taken = Vec::new();
    for index in indexes.iter().rev() {
        taken.push(siblings.remove(*index));
    }
    taken.reverse();
    let mut new = Block::new(BlockKind::Item(Item { marker: Marker::Bullet('-'), task: None }), "");
    new.layout.spacing = 1;
    new.children = taken;
    siblings.insert(indexes[0], new);
    renumber(siblings);
    Some([parent, &[indexes[0]]].concat())
}

/// Moves a row, with its branch, past the row shown before it — ⌃⌘↑ —
/// taking that row's level: it goes just before it, as its sibling. A
/// first child so leaves its parent, above it. `shown` is every row
/// shown, in order.
pub fn move_up_shown(document: &mut Document, path: &[usize], shown: &[Path]) -> Option<Path> {
    let at = shown.iter().position(|row| row == path)?;
    let before = shown.get(at.checked_sub(1)?)?.clone();
    let block = remove(document, path)?;
    // Taking the row out moved nothing before it: `before` still leads there.
    insert(document, &before, block)?;
    renumber(document.siblings_mut(&before)?);
    Some(before)
}

/// Moves a row, with its branch, past the row shown after its branch —
/// ⌃⌘↓ — so that that row is shown just before it: after it as its
/// sibling, or, when its children are shown, as its first child.
pub fn move_down_shown(document: &mut Document, path: &[usize], shown: &[Path]) -> Option<Path> {
    let at = shown.iter().position(|row| row == path)?;
    let next = shown[at + 1..].iter().find(|row| !row.starts_with(path))?.clone();
    let block = remove(document, path)?;
    // The row after shifts up a place if it shared the moved row's list, after it.
    let mut next = next;
    if next.len() >= path.len() && next[..path.len() - 1] == path[..path.len() - 1] && next[path.len() - 1] > path[path.len() - 1] {
        next[path.len() - 1] -= 1;
    }
    let target = document.get(&next)?;
    let to = if !target.children.is_empty() && !target.folded && target.can_have_children() {
        [&next[..], &[0]].concat()
    } else {
        let mut after = next.clone();
        *after.last_mut()? += 1;
        after
    };
    insert(document, &to, block)?;
    renumber(document.siblings_mut(&to)?);
    Some(to)
}

/// Moves a row down at its level — ⌃⌥⌘↓: past the sibling after it; a
/// last child, into the row shown after its parent's branch, as its first
/// child — so it keeps its level, as Bike's does.
pub fn move_down_keeping_level(document: &mut Document, path: &[usize], shown: &[Path]) -> Option<Path> {
    if let Some(moved) = move_down(document, path) {
        return Some(moved);
    }
    let at = shown.iter().position(|row| row == path)?;
    let next = shown[at + 1..].iter().find(|row| !row.starts_with(path))?.clone();
    if next.len() + 1 != path.len() || !document.get(&next)?.can_have_children() {
        return None;
    }
    let block = remove(document, path)?;
    // Taking it out moved nothing the next row's path counts through: it was a last child.
    let host = document.get_mut(&next)?;
    host.folded = false;
    host.children.insert(0, block);
    Some([&next[..], &[0]].concat())
}

/// Moves a row alone a line up or down — ⌃⌥↑ ⌃⌥↓ — as a line of
/// indented text moves: it keeps its level, and the rows around it are
/// put under whichever row then stands above them. A folded row's hidden
/// rows go with it. A row can be no deeper than one past the row above.
pub fn move_row_alone(document: &mut Document, path: &[usize], up: bool) -> Option<Path> {
    // The rows as lines: each with its level, without its shown children.
    fn flatten(blocks: &[Block], level: usize, at: &mut Path, lines: &mut Vec<(usize, Block, Path)>) {
        for (index, block) in blocks.iter().enumerate() {
            at.push(index);
            let mut alone = block.clone();
            if !block.folded {
                alone.children.clear();
            }
            lines.push((level, alone, at.clone()));
            if !block.folded {
                flatten(&block.children, level + 1, at, lines);
            }
            at.pop();
        }
    }
    let mut lines = Vec::new();
    flatten(&document.blocks, 0, &mut Vec::new(), &mut lines);
    let index = lines.iter().position(|(_, _, at)| at == path)?;
    let other = if up { index.checked_sub(1)? } else { index + 1 };
    if other >= lines.len() {
        return None;
    }
    lines.swap(index, other);
    // Rebuilt: each line under the last line before it one level up.
    let mut blocks: Vec<Block> = Vec::new();
    let mut previous: Option<usize> = None;
    let mut moved = Vec::new();
    for (position, (level, block, _)) in lines.into_iter().enumerate() {
        let level = level.min(previous.map_or(0, |previous| previous + 1));
        let mut siblings = &mut blocks;
        let mut at = Vec::new();
        for _ in 0..level {
            let Some(last) = siblings.len().checked_sub(1) else { break };
            if !siblings[last].can_have_children() {
                break;
            }
            at.push(last);
            siblings = &mut siblings[last].children;
        }
        at.push(siblings.len());
        siblings.push(block);
        previous = Some(at.len() - 1);
        if position == other {
            moved = at;
        }
    }
    document.blocks = blocks;
    renumber(&mut document.blocks);
    Some(moved)
}

/// Opens an empty block above a block — what Return does at the start of
/// a block's words, which stay where the caret is. The new block is of
/// the block's own sort: a bullet above a bullet, an open task above any
/// task, a paragraph above a heading; a numbered item takes the number,
/// and those after it the next. The blank lines before stay above both.
/// Answers the path the block itself then has.
pub fn open_above(document: &mut Document, path: &[usize]) -> Option<Path> {
    let block = document.get_mut(path)?;
    let kind = match &block.kind {
        BlockKind::Item(item) => BlockKind::Item(Item { marker: item.marker, task: item.task.map(|_| Task::Open) }),
        BlockKind::Heading(_) => BlockKind::Paragraph,
        other @ (BlockKind::Paragraph | BlockKind::Quote) => other.clone(),
        _ => return None,
    };
    let mut new = Block::new(kind, "");
    new.layout.spacing = block.layout.spacing.max(1);
    new.layout.gap = std::mem::take(&mut block.layout.gap);
    let (&index, parent) = path.split_last()?;
    let siblings = document.siblings_mut(path)?;
    siblings.insert(index, new);
    renumber(siblings);
    Some([parent, &[index + 1]].concat())
}

/// Joins a block's text onto the block before it in reading order — what
/// Delete does at a block's start. Its children are kept, under whichever
/// block now stands where it stood. Answers the path of the block joined
/// onto, and the byte offset in its text where the two meet.
pub fn join_with_previous(document: &mut Document, path: &[usize]) -> Option<(Path, usize)> {
    let rows = document.rows();
    let position = rows.iter().position(|r| r.path == path)?;
    let target: Path = rows.get(position.checked_sub(1)?)?.path.clone();
    drop(rows);
    join_onto(document, path, &target)
}

/// Joins a block's text onto a block before it: the one before it in
/// reading order ([`join_with_previous`]), or — in an outline with rows
/// folded away — the one shown before it. Its children are kept, under
/// whichever block now stands where it stood; a folded block they come
/// under is unfolded, so that nothing shown is hidden by a join.
pub fn join_onto(document: &mut Document, path: &[usize], target: &[usize]) -> Option<(Path, usize)> {
    let joinable = |kind: &BlockKind| matches!(kind, BlockKind::Paragraph | BlockKind::Heading(_) | BlockKind::Item(_) | BlockKind::Quote);
    if target >= path || !joinable(&document.get(path)?.kind) || !joinable(&document.get(target)?.kind) {
        return None;
    }
    let block = remove(document, path)?;
    let (&index, parent) = path.split_last()?;
    // Where the children go: in the block's place when it was a first
    // child; else under the sibling that came before it.
    if index == 0 {
        let siblings = document.siblings_mut(path)?;
        siblings.splice(0..0, block.children);
    } else {
        let previous = document.get_mut(&[parent, &[index - 1]].concat())?;
        if previous.can_have_children() {
            previous.folded &= block.children.is_empty();
            previous.children.extend(block.children);
        } else {
            let siblings = document.siblings_mut(path)?;
            siblings.splice(index..index, block.children);
        }
    }
    let onto = document.get_mut(target)?;
    let offset = onto.text.len();
    onto.text.push_str(&block.text);
    Some((target.to_vec(), offset))
}

/// Checks a task off, or opens it again; a list item with no checkbox
/// gets an open one. Answers the new state.
pub fn toggle_task(document: &mut Document, path: &[usize]) -> Option<Task> {
    let item = document.get_mut(path)?.item_mut()?;
    let next = match item.task {
        Some(Task::Open) => Task::Done('x'),
        Some(Task::Done(_)) | None => Task::Open,
    };
    item.task = Some(next);
    Some(next)
}

/// Makes a block another kind, keeping its text. A list item made
/// something that cannot hold children hands them to the list it is in,
/// straight after it.
pub fn set_kind(document: &mut Document, path: &[usize], kind: BlockKind) -> Option<()> {
    let (&index, _) = path.split_last()?;
    let block = document.get_mut(path)?;
    block.kind = kind;
    block.layout.spacing = block.layout.spacing.max(1);
    if !block.can_have_children() && !block.children.is_empty() {
        block.folded = false;
        let children = std::mem::take(&mut block.children);
        document.siblings_mut(path)?.splice(index + 1..index + 1, children);
    }
    Some(())
}

/// Numbers each run of ordered items in a list from its first item's
/// number on, as they should read after one was added, moved or removed.
pub fn renumber(siblings: &mut [Block]) {
    let mut next: Option<u32> = None;
    for block in siblings {
        match block.item_mut().map(|item| &mut item.marker) {
            Some(Marker::Ordered { number, .. }) => {
                if let Some(expected) = next {
                    *number = expected;
                }
                next = Some(*number + 1);
            }
            _ => next = None,
        }
    }
}

/// How many top-level blocks a heading's section takes, the heading
/// included: up to the next heading of its level or higher. One for a
/// block that is no heading.
pub fn section_len(document: &Document, index: usize) -> usize {
    let Some(BlockKind::Heading(level)) = document.blocks.get(index).map(|b| &b.kind) else { return 1 };
    1 + document.blocks[index + 1..].iter().take_while(|b| !matches!(&b.kind, BlockKind::Heading(other) if other <= level)).count()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(source: &str) -> Document {
        Document::parse(source)
    }

    #[test]
    fn indent_makes_a_child_of_the_block_before() {
        let mut d = doc("- a\n- b\n  - c\n- d\n");
        assert_eq!(indent(&mut d, &[1]), Some(vec![0, 0]));
        assert_eq!(d.to_markdown(), "- a\n  - b\n    - c\n- d\n");
        assert_eq!(indent(&mut d, &[1]), Some(vec![0, 1]));
        assert_eq!(d.to_markdown(), "- a\n  - b\n    - c\n  - d\n");
        // A first child has nothing before it to go under.
        assert_eq!(indent(&mut d, &[0]), None);
        assert_eq!(indent(&mut d, &[0, 0]), None);
        // Only a list item takes children.
        let mut d = doc("para\n- item\n");
        assert_eq!(indent(&mut d, &[1]), None);
        assert_eq!(indent(&mut d, &[7]), None);
    }

    #[test]
    fn outdent_goes_after_the_parents_branch() {
        let mut d = doc("- a\n  - b\n    - c\n  - d\n  - e\n- f\n");
        assert_eq!(outdent(&mut d, &[0, 0]), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- a\n  - d\n  - e\n- b\n  - c\n- f\n");
        assert_eq!(outdent(&mut d, &[0]), None);
    }

    #[test]
    fn outdent_taking_followers_takes_children_and_followers_along() {
        let mut d = doc("- a\n  - b\n    - c\n  - d\n  - e\n- f\n");
        assert_eq!(outdent_taking_followers(&mut d, &[0, 0]), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- a\n- b\n  - c\n  - d\n  - e\n- f\n");
        assert_eq!(outdent_taking_followers(&mut d, &[0]), None);
        // A paragraph cannot hold what followed it: they stay.
        let mut d = doc("- a\n\n  para\n  - b\n");
        assert_eq!(outdent_taking_followers(&mut d, &[0, 0]), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- a\n  - b\n\npara\n");
    }

    #[test]
    fn indent_then_outdent_is_where_it_started() {
        let source = "- a\n- b\n  - c\n";
        let mut d = doc(source);
        let moved = indent(&mut d, &[1]).unwrap();
        assert_eq!(outdent(&mut d, &moved), Some(vec![1]));
        assert_eq!(d.to_markdown(), source);
    }

    #[test]
    fn moving_swaps_siblings_and_leaves_blank_lines_in_place() {
        let mut d = doc("- a\n  - a1\n\n- b\n- c\n");
        assert_eq!(move_down(&mut d, &[0]), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- b\n\n- a\n  - a1\n- c\n");
        assert_eq!(move_up(&mut d, &[1]), Some(vec![0]));
        assert_eq!(d.to_markdown(), "- a\n  - a1\n\n- b\n- c\n");
        assert_eq!(move_up(&mut d, &[0]), None);
        assert_eq!(move_down(&mut d, &[2]), None);
    }

    #[test]
    fn remove_insert_and_duplicate() {
        let mut d = doc("- a\n  - a1\n- b\n");
        let taken = remove(&mut d, &[0]).unwrap();
        assert_eq!(taken.children.len(), 1);
        assert_eq!(d.to_markdown(), "- b\n");
        assert_eq!(insert(&mut d, &[1], taken), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- b\n- a\n  - a1\n");
        assert_eq!(duplicate(&mut d, &[1]), Some(vec![2]));
        assert_eq!(d.to_markdown(), "- b\n- a\n  - a1\n- a\n  - a1\n");
        assert!(insert(&mut d, &[9], Block::bullet("x")).is_none());
        assert!(remove(&mut d, &[9]).is_none());
    }

    #[test]
    fn split_makes_the_next_block_of_the_same_sort() {
        let mut d = doc("- hello world\n");
        assert_eq!(split(&mut d, &[0], 5), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- hello\n-  world\n");

        let mut d = doc("+ [x] done\n1. one\n2. two\n# Title\n");
        assert_eq!(split(&mut d, &[0], 4), Some(vec![1]));
        split(&mut d, &[2], 3);
        split(&mut d, &[5], 5);
        assert_eq!(d.to_markdown(), "+ [x] done\n+ [ ]\n1. one\n2. \n3. two\n# Title\n\n");
        assert_eq!(d.blocks[6].kind, BlockKind::Paragraph);
    }

    #[test]
    fn split_at_the_end_of_a_parent_makes_its_first_child() {
        let mut d = doc("- parent\n  - child\n");
        assert_eq!(split(&mut d, &[0], 6), Some(vec![0, 0]));
        // An empty item cannot break into the text before it, so a blank
        // line holds it apart until something is typed in it.
        assert_eq!(d.to_markdown(), "- parent\n\n  - \n  - child\n");
        d.get_mut(&[0, 0]).unwrap().text = "typed".into();
        assert_eq!(d.to_markdown(), "- parent\n  - typed\n  - child\n");
        // In the middle, the second half is the first child; the children stay with the first half.
        let mut d = doc("- parent\n  - child\n");
        assert_eq!(split(&mut d, &[0], 3), Some(vec![0, 0]));
        assert_eq!(d.to_markdown(), "- par\n  - ent\n  - child\n");
        // Folded, the second half follows the branch, and the hidden rows stay with the first.
        let mut d = doc("- parent\n  - child\n");
        d.blocks[0].folded = true;
        assert_eq!(split(&mut d, &[0], 3), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- par\n  - child\n- ent\n");
    }

    #[test]
    fn rows_put_in_beside_a_row() {
        let mut d = doc("- a\n  - a1\n- b\n");
        assert_eq!(insert_row(&mut d, &[0], Beside::Below), Some(vec![1]));
        d.get_mut(&[1]).unwrap().text = "below".into();
        assert_eq!(insert_row(&mut d, &[0], Beside::Above), Some(vec![0]));
        d.get_mut(&[0]).unwrap().text = "above".into();
        assert_eq!(insert_row(&mut d, &[1], Beside::Child), Some(vec![1, 0]));
        d.get_mut(&[1, 0]).unwrap().text = "child".into();
        assert_eq!(d.to_markdown(), "- above\n- a\n  - child\n  - a1\n- below\n- b\n");
        let mut d = doc("+ [x] done\n");
        insert_row(&mut d, &[0], Beside::Below);
        assert_eq!(d.blocks[1].kind, BlockKind::Item(Item { marker: Marker::Bullet('+'), task: Some(Task::Open) }));
    }

    #[test]
    fn rows_joined_promoted_demoted_grouped() {
        let mut d = doc("- one\n- two\n  - kid\n- three\n");
        assert_eq!(join_next(&mut d, &[0], &[1]), Some((vec![0], 3)));
        assert_eq!(d.to_markdown(), "- one two\n  - kid\n- three\n");
        assert_eq!(promote_children(&mut d, &[0]), Some(vec![0]));
        assert_eq!(d.to_markdown(), "- one two\n- kid\n- three\n");
        assert_eq!(demote_siblings(&mut d, &[0]), Some(vec![0]));
        assert_eq!(d.to_markdown(), "- one two\n  - kid\n  - three\n");
        assert!(remove_row_only(&mut d, &[0]).is_some());
        assert_eq!(d.to_markdown(), "- kid\n- three\n");
        assert_eq!(group(&mut d, &[vec![0], vec![1]]), Some(vec![0]));
        d.get_mut(&[0]).unwrap().text = "g".into();
        assert_eq!(d.to_markdown(), "- g\n  - kid\n  - three\n");
    }

    #[test]
    fn a_row_alone_moves_as_a_line_of_indented_text() {
        // Up past a deeper row: it keeps its level, and the row it passed comes under it.
        let mut d = doc("- alpha\n  - beta\n  - gamma\n- delta\n- epsilon\n");
        assert_eq!(move_row_alone(&mut d, &[1], true), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- alpha\n  - beta\n- delta\n  - gamma\n- epsilon\n");
        // A parent alone, down past its child: it keeps its level; the child goes under the row before.
        let mut d = doc("- a\n- b\n  - b1\n- c\n");
        assert_eq!(move_row_alone(&mut d, &[1], false), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- a\n  - b1\n- b\n- c\n");
        assert_eq!(move_row_alone(&mut d, &[0], true), None);
    }

    #[test]
    fn moving_down_at_the_same_level() {
        let shown = |d: &Document| d.rows().into_iter().map(|row| row.path).collect::<Vec<_>>();
        let mut d = doc("- one\n  - two\n  - three\n- four\n");
        let rows = shown(&d);
        assert_eq!(move_down_keeping_level(&mut d, &[0, 1], &rows), Some(vec![1, 0]));
        assert_eq!(d.to_markdown(), "- one\n  - two\n- four\n  - three\n");
        let mut d = doc("- one\n  - two\n- four\n");
        let rows = shown(&d);
        assert_eq!(move_down_keeping_level(&mut d, &[1], &rows), None);
    }

    #[test]
    fn moving_past_the_row_shown() {
        let shown = |d: &Document| d.rows().into_iter().map(|row| row.path).collect::<Vec<_>>();
        // A first child goes above its parent, at its level.
        let mut d = doc("- one\n  - two\n  - three\n- four\n");
        let rows = shown(&d);
        assert_eq!(move_up_shown(&mut d, &[0, 0], &rows), Some(vec![0]));
        assert_eq!(d.to_markdown(), "- two\n- one\n  - three\n- four\n");
        // A last child goes past the next row, at its level.
        let mut d = doc("- one\n  - two\n  - three\n- four\n");
        let rows = shown(&d);
        assert_eq!(move_down_shown(&mut d, &[0, 1], &rows), Some(vec![2]));
        assert_eq!(d.to_markdown(), "- one\n  - two\n- four\n- three\n");
        // Up past the deep last row of the sibling before: into its branch.
        let mut d = doc("- alpha\n  - beta\n  - gamma\n- delta\n");
        let rows = shown(&d);
        assert_eq!(move_up_shown(&mut d, &[1], &rows), Some(vec![0, 1]));
        assert_eq!(d.to_markdown(), "- alpha\n  - beta\n  - delta\n  - gamma\n");
        // Down past a sibling: after it, with the branch.
        let mut d = doc("- alpha\n  - beta\n- delta\n- epsilon\n");
        let rows = shown(&d);
        assert_eq!(move_down_shown(&mut d, &[0], &rows), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- delta\n- alpha\n  - beta\n- epsilon\n");
        // Down past a parent whose children are shown: its first child.
        let mut d = doc("- a\n- b\n  - b1\n");
        let rows = shown(&d);
        assert_eq!(move_down_shown(&mut d, &[0], &rows), Some(vec![0, 0]));
        assert_eq!(d.to_markdown(), "- b\n  - a\n  - b1\n");
    }

    #[test]
    fn join_puts_text_on_the_row_before_and_keeps_children() {
        let mut d = doc("- a\n- b\n  - b1\n");
        assert_eq!(join_with_previous(&mut d, &[1]), Some((vec![0], 1)));
        assert_eq!(d.to_markdown(), "- ab\n  - b1\n");

        // A first child joins its parent; its own children take its place.
        let mut d = doc("- a\n  - b\n    - c\n  - d\n");
        assert_eq!(join_with_previous(&mut d, &[0, 0]), Some((vec![0], 1)));
        assert_eq!(d.to_markdown(), "- ab\n  - c\n  - d\n");

        // The row before may be deep inside the sibling before.
        let mut d = doc("- a\n  - a1\n- b\n");
        assert_eq!(join_with_previous(&mut d, &[1]), Some((vec![0, 0], 2)));
        assert_eq!(d.to_markdown(), "- a\n  - a1b\n");

        assert_eq!(join_with_previous(&mut d, &[0]), None);
        let mut d = doc("```\ncode\n```\n- a\n");
        assert_eq!(join_with_previous(&mut d, &[1]), None);
    }

    #[test]
    fn tasks_toggle() {
        let mut d = doc("- plain\n+ [ ] open\n- [X] done\ntext\n");
        assert_eq!(toggle_task(&mut d, &[0]), Some(Task::Open));
        assert_eq!(toggle_task(&mut d, &[1]), Some(Task::Done('x')));
        assert_eq!(toggle_task(&mut d, &[2]), Some(Task::Open));
        assert_eq!(toggle_task(&mut d, &[3]), None);
        assert_eq!(d.to_markdown(), "- [ ] plain\n+ [x] open\n- [ ] done\ntext\n");
    }

    #[test]
    fn changing_kind_keeps_text_and_rehomes_children() {
        let mut d = doc("- title\n  - child\n- next\n");
        set_kind(&mut d, &[0], BlockKind::Heading(2)).unwrap();
        assert_eq!(d.to_markdown(), "## title\n- child\n- next\n");
        set_kind(&mut d, &[0], BlockKind::Item(Item { marker: Marker::Bullet('-'), task: Some(Task::Open) })).unwrap();
        assert_eq!(d.to_markdown(), "- [ ] title\n- child\n- next\n");
    }

    #[test]
    fn ordered_runs_renumber() {
        let mut d = doc("3. a\n7. b\n- break\n1. c\n1. d\n");
        renumber(&mut d.blocks);
        assert_eq!(d.to_markdown(), "3. a\n4. b\n- break\n1. c\n2. d\n");
    }

    #[test]
    fn a_heading_holds_its_section() {
        let d = doc("# A\ntext\n## A1\n- item\n# B\n## B1\n");
        assert_eq!(section_len(&d, 0), 4);
        assert_eq!(section_len(&d, 2), 2);
        assert_eq!(section_len(&d, 1), 1);
        assert_eq!(section_len(&d, 4), 2);
        assert_eq!(section_len(&d, 99), 1);
    }
}
