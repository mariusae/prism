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

/// Moves a block out a level, to just after its parent. The siblings that
/// followed it stay in their order under it — as the lines of an outline
/// read when one is pulled left — when it can hold them; else they stay
/// where they were.
pub fn outdent(document: &mut Document, path: &[usize]) -> Option<Path> {
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
    if new.text.is_empty() && !block.children.is_empty() && block.is_item() {
        block.children.insert(0, new);
        return Some([path, &[0]].concat());
    }
    let (&index, parent) = path.split_last()?;
    let siblings = document.siblings_mut(path)?;
    siblings.insert(index + 1, new);
    renumber(siblings);
    Some([parent, &[index + 1]].concat())
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
    fn outdent_takes_children_and_followers_along() {
        let mut d = doc("- a\n  - b\n    - c\n  - d\n  - e\n- f\n");
        assert_eq!(outdent(&mut d, &[0, 0]), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- a\n- b\n  - c\n  - d\n  - e\n- f\n");
        assert_eq!(outdent(&mut d, &[0]), None);
        // A paragraph cannot hold what followed it: they stay.
        let mut d = doc("- a\n\n  para\n  - b\n");
        assert_eq!(outdent(&mut d, &[0, 0]), Some(vec![1]));
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
        // In the middle, the children stay with the first half.
        let mut d = doc("- parent\n  - child\n");
        assert_eq!(split(&mut d, &[0], 3), Some(vec![1]));
        assert_eq!(d.to_markdown(), "- par\n  - child\n- ent\n");
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
