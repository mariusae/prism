//! Merging two commits, without ever stopping.
//!
//! A sync's merge must always finish: there is nobody at a terminal to
//! resolve a conflict, and a repository left mid-merge stops every later
//! sync. So a merge here is computed entirely in memory, every conflict
//! is settled by rule, and the result is a finished tree:
//!
//! | Conflict | Settled as |
//! |---|---|
//! | both changed a text file | a [`MergeDriver`] that knows the file's form, else merged by lines; lines both changed are kept, both sides, between markers |
//! | one changed what the other deleted | the changed file is kept — a sync must never quietly delete what someone wrote |
//! | both changed a binary file | ours stays; theirs is put beside it as `name (conflict).ext` |
//! | both deleted it | it stays deleted |
//!
//! Files left needing a person are reported, and the tree is committed as
//! it is: the conflict travels in the file, not in the repository's state.

use crate::conflict;
use crate::error::Result;
use crate::repo::{index_entry, Oid, Repository};
use crate::textmerge::{self, Labels};
use std::path::Path;

/// A file merged by something that knows its form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileMerge {
    pub content: Vec<u8>,
    /// Whether the content still needs a person: has conflict markers.
    pub conflicted: bool,
}

/// Merges one file both sides changed, knowing more about it than its
/// lines. A note's driver merges frontmatter field by field — tags as
/// sets, `modified` the later — so that only the body is left to merge by
/// lines.
pub trait MergeDriver: Send + Sync {
    /// The merge of `ours` and `theirs` from `base` (`None` when both
    /// added the file), or `None` to have it merged by lines.
    fn merge(&self, path: &str, base: Option<&[u8]>, ours: &[u8], theirs: &[u8]) -> Option<FileMerge>;
}

/// A merge's result: a tree, and what in it needs a person.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeMerge {
    pub tree: Oid,
    /// Paths left with conflict markers, kept though the other side
    /// deleted them, or with a conflict copy beside them — copies included.
    pub conflicted: Vec<String>,
}

/// Merges two commits into a tree. Nothing in the repository moves.
pub fn merge_commits(repo: &Repository, ours: Oid, theirs: Oid, driver: Option<&dyn MergeDriver>, labels: Labels<'_>) -> Result<TreeMerge> {
    let git = repo.git();
    let mut options = git2::MergeOptions::new();
    // Paths are identities here: a rename is a delete and an add, so every
    // conflict is about one path.
    options.find_renames(false);
    let mut index = git.merge_commits(&git.find_commit(ours)?, &git.find_commit(theirs)?, Some(&options))?;

    let conflicts: Vec<git2::IndexConflict> = index.conflicts()?.collect::<std::result::Result<_, _>>()?;
    let mut conflicted = Vec::new();
    for conflict in conflicts {
        let Some(path) = [&conflict.our, &conflict.their, &conflict.ancestor]
            .into_iter()
            .flatten()
            .next()
            .and_then(|entry| std::str::from_utf8(&entry.path).ok().map(str::to_owned))
        else {
            continue;
        };
        index.conflict_remove(Path::new(&path))?;
        match (&conflict.our, &conflict.their) {
            (Some(our), Some(their)) => {
                let (mine, other) = (repo.blob(our.id)?, repo.blob(their.id)?);
                let base = conflict.ancestor.as_ref().map(|entry| repo.blob(entry.id)).transpose()?;
                let merged = driver.and_then(|driver| driver.merge(&path, base.as_deref(), &mine, &other)).or_else(|| {
                    textmerge::merge_bytes_lenient(base.as_deref().unwrap_or_default(), &mine, &other, labels)
                        .map(|merged| FileMerge { content: merged.text.into_bytes(), conflicted: merged.conflicted })
                });
                match merged {
                    Some(merged) => {
                        index.add(&index_entry(&path, git.blob(&merged.content)?, our.mode))?;
                        if merged.conflicted {
                            conflicted.push(path);
                        }
                    }
                    None => {
                        // Binary: ours stays, theirs goes beside it.
                        let copy = conflict::copy_path(&path);
                        index.add(&index_entry(&path, our.id, our.mode))?;
                        index.add(&index_entry(&copy, their.id, their.mode))?;
                        conflicted.extend([path, copy]);
                    }
                }
            }
            (Some(kept), None) | (None, Some(kept)) => {
                index.add(&index_entry(&path, kept.id, kept.mode))?;
                conflicted.push(path);
            }
            (None, None) => {}
        }
    }
    conflicted.sort();
    Ok(TreeMerge { tree: index.write_tree_to(git)?, conflicted })
}
