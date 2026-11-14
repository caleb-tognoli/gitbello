//! The diff minimap (M7.6) over runtime state on temporary repositories: a
//! partly picked diff and a conflicted file in the resolver.

use crate::support;

use std::path::{Path, PathBuf};

use gitbello_core::diff::minimap::{
    overview, render_tile, ConflictMinimap, DiffMinimap, Mark, MinimapPalette, MinimapSource,
    MinimapStyle, OVERVIEW_ADDED, OVERVIEW_CONFLICT, OVERVIEW_LEFT_OUT, OVERVIEW_REMOVED,
    PALETTE_LEN,
};
use gitbello_core::diff::LineKind;
use gitbello_core::merge::BlockChoice;
use gitbello_core::runtime::Runtime;
use support::rt::{ok, open, poll_until};
use support::TestRepo;

#[test]
fn a_partly_picked_diff_marks_the_lines_left_out() {
    let repo = TestRepo::init();
    repo.commit("f ünï.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n", "base");
    repo.write("f ünï.txt", "1\ntwo\n3\n4\n5\n6\n7\n8\n9\nten\n");
    let (mut rt, key) = open(&repo);
    rt.select_change(&key, Path::new("f ünï.txt"), false);
    let wanted = PathBuf::from("f ünï.txt");
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| d.target().path == wanted && !d.is_loading() && d.diff().is_some())
    });
    let diff = rt
        .repo(&key)
        .unwrap()
        .diff()
        .unwrap()
        .diff()
        .unwrap()
        .clone();
    let ten: Vec<usize> = (0..diff.line_count())
        .filter(|&i| {
            let l = diff.line(i).unwrap();
            matches!(l.kind, LineKind::Added | LineKind::Removed)
                && (l.text == b"10" || l.text == b"ten")
        })
        .collect();
    assert_eq!(ten.len(), 2);
    assert!(rt.pick_lines(&key, &ten, false));

    let state = rt.repo(&key).unwrap();
    let shown = state.diff().unwrap();
    let source = DiffMinimap::new(
        shown.diff().unwrap(),
        shown.layout(),
        shown.old_file(),
        state.diff_picks(),
        false,
        shown.syntax(),
        shown.line_states(),
    );
    let rows: Vec<(Mark, bool)> = (0..source.row_count())
        .filter_map(|r| source.row(r).left.map(|l| (l.mark, l.left_out)))
        .filter(|(mark, _)| matches!(mark, Mark::Added | Mark::Removed))
        .collect();
    assert_eq!(
        rows,
        vec![
            (Mark::Removed, false),
            (Mark::Added, false),
            (Mark::Removed, true),
            (Mark::Added, true),
        ]
    );
    let flags = overview(&source, source.row_count(), false);
    assert!(flags.contains(&(OVERVIEW_REMOVED | OVERVIEW_LEFT_OUT)));
    assert!(flags.contains(&OVERVIEW_ADDED));

    let style = MinimapStyle {
        columns: 40,
        row_px: 2,
        char_px: 1,
        palette: MinimapPalette::from_colors(&[[255, 255, 255, 255]; PALETTE_LEN]).unwrap(),
    };
    let tile = render_tile(&source, 0, 256, &style);
    assert_eq!(tile.len(), 40 * 256 * 2 * 4);
}

#[test]
fn a_conflicted_file_marks_its_blocks() {
    let repo = TestRepo::init();
    repo.start_conflicting_merge("c.txt");
    let (mut rt, key) = open(&repo);
    rt.select_change(&key, Path::new("c.txt"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.conflict())
            .is_some_and(|c| !c.is_loading() && c.file().is_some())
    });
    let conflict = rt.repo(&key).unwrap().conflict().unwrap();
    for split in [false, true] {
        let source = ConflictMinimap::new(
            conflict.file().unwrap(),
            conflict.layout(),
            conflict.resolved(),
            split,
            conflict.syntax(),
            conflict.line_states(),
        );
        let marks: Vec<Mark> = (0..source.row_count())
            .flat_map(|r| {
                let row = source.row(r);
                [row.left, row.right].into_iter().flatten().map(|l| l.mark)
            })
            .collect();
        assert!(marks.contains(&Mark::Header), "split {split}: {marks:?}");
        assert!(marks.contains(&Mark::Ours) && marks.contains(&Mark::Theirs));
        assert!(overview(&source, 4, false)
            .iter()
            .any(|&f| f & OVERVIEW_CONFLICT != 0));
    }
}

/// Selects conflicted `c.txt` and waits until it shows `blocks` blocks.
fn show_blocks(rt: &mut Runtime, key: &Path, blocks: usize) {
    rt.select_change(key, Path::new("c.txt"), false);
    poll_until(rt, |rt, _| {
        rt.repo(key)
            .and_then(|s| s.conflict())
            .and_then(|c| c.file().filter(|_| !c.is_loading()))
            .is_some_and(|f| f.blocks.len() == blocks)
    });
}

fn resolved(rt: &Runtime, key: &Path) -> Vec<std::ops::Range<usize>> {
    rt.repo(key)
        .and_then(|s| s.conflict())
        .map(|c| c.resolved().to_vec())
        .unwrap_or_default()
}

#[test]
fn chosen_blocks_stay_marked_until_undone_or_edited_elsewhere() {
    let repo = TestRepo::init();
    let lines = |tag: &str| -> String {
        (1..=30)
            .map(|n| {
                if [3, 15, 27].contains(&n) {
                    format!("{n} {tag}\n")
                } else {
                    format!("{n}\n")
                }
            })
            .collect()
    };
    repo.commit("c.txt", &lines("base"), "base");
    repo.branch("topic");
    repo.commit("c.txt", &lines("ours"), "ours");
    repo.checkout("topic");
    repo.commit("c.txt", &lines("theirs"), "theirs");
    repo.checkout("main");
    assert!(repo.try_git(&["merge", "--no-edit", "topic"]).is_err());
    let (mut rt, key) = open(&repo);
    show_blocks(&mut rt, &key, 3);
    assert!(resolved(&rt, &key).is_empty());

    // The middle block: its one line of ours replaces its markers.
    let middle = rt
        .repo(&key)
        .unwrap()
        .conflict()
        .unwrap()
        .file()
        .unwrap()
        .blocks[1]
        .start;
    ok(&mut rt, &key, |rt| {
        rt.resolve_block(&key, Path::new("c.txt"), 1, BlockChoice::Ours)
    });
    show_blocks(&mut rt, &key, 2);
    assert_eq!(resolved(&rt, &key), vec![middle..middle + 1]);
    let conflict = rt.repo(&key).unwrap().conflict().unwrap();
    let source = ConflictMinimap::new(
        conflict.file().unwrap(),
        conflict.layout(),
        conflict.resolved(),
        false,
        conflict.syntax(),
        conflict.line_states(),
    );
    let marks: Vec<Mark> = (0..source.row_count())
        .filter_map(|r| source.row(r).left.map(|l| l.mark))
        .collect();
    assert_eq!(marks.iter().filter(|m| **m == Mark::Resolved).count(), 1);

    // The first block, both sides: the middle's line moves up.
    let first = rt
        .repo(&key)
        .unwrap()
        .conflict()
        .unwrap()
        .file()
        .unwrap()
        .blocks[0]
        .clone();
    ok(&mut rt, &key, |rt| {
        rt.resolve_block(&key, Path::new("c.txt"), 0, BlockChoice::OursThenTheirs)
    });
    show_blocks(&mut rt, &key, 1);
    let moved = middle + 2 - (first.end + 1 - first.start);
    assert_eq!(
        resolved(&rt, &key),
        vec![moved..moved + 1, first.start..first.start + 2]
    );

    // Undo takes back the last choice only.
    ok(&mut rt, &key, |rt| rt.undo_block_choice(&key));
    show_blocks(&mut rt, &key, 2);
    assert_eq!(resolved(&rt, &key), vec![middle..middle + 1]);

    // An edit made elsewhere drops the marks.
    let text = std::fs::read_to_string(repo.path().join("c.txt")).unwrap();
    repo.write("c.txt", &format!("edited\n{text}"));
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.conflict())
            .and_then(|c| c.file())
            .is_some_and(|f| f.line(0) == Some(b"edited".as_slice()))
    });
    assert!(resolved(&rt, &key).is_empty());
}
