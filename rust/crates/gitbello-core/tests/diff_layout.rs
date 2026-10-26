//! Opening the gaps between hunks (PLAN §3.10): the old file is read once a
//! gap opens, through the runtime on real temporary repositories.

mod support;

use std::path::Path;

use gitbello_core::diff::{Expand, Expanders, LayoutRow};
use gitbello_core::runtime::{DiffSlot, Runtime, RuntimeEvent};
use support::rt::{open, poll_until};
use support::TestRepo;

/// `l1`..`l{count}`, one per line, with `changed` lines upper-cased.
fn lines(count: u32, changed: &[u32]) -> String {
    (1..=count)
        .map(|n| match changed.contains(&n) {
            true => format!("L{n}\n"),
            false => format!("l{n}\n"),
        })
        .collect()
}

/// Rows of the Changes diff: diff lines as their text, the rest as markers.
fn rows(rt: &Runtime, key: &Path) -> Vec<String> {
    let state = rt.repo(key).and_then(|s| s.diff()).expect("diff state");
    let diff = state.diff().expect("diff");
    let old = state.old_file();
    state
        .layout()
        .rows(false, 0, usize::MAX)
        .map(|row| match row {
            LayoutRow::Diff(n) => {
                String::from_utf8_lossy(diff.line(n).expect("line").text).into_owned()
            }
            LayoutRow::Header(header) => header.text(diff),
            LayoutRow::Hidden { old: n, new } => {
                let text = old.and_then(|o| o.line(n)).unwrap_or_default();
                format!("~{new} {}", String::from_utf8_lossy(text))
            }
            LayoutRow::End => "end".to_owned(),
        })
        .collect()
}

fn wait_for_diff(rt: &mut Runtime) {
    poll_until(rt, |_, events| {
        events.iter().any(|e| {
            matches!(
                e,
                RuntimeEvent::DiffChanged {
                    slot: DiffSlot::Changes,
                    ..
                }
            )
        })
    });
}

#[test]
fn gaps_open_from_the_old_file_and_survive_reloads() {
    let repo = TestRepo::init();
    repo.commit("f.txt", &lines(100, &[]), "base");
    repo.write("f.txt", &lines(100, &[10, 60]));
    let (mut rt, key) = open(&repo);
    rt.select_change(&key, Path::new("f.txt"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| !d.is_loading() && d.diff().is_some())
    });

    let closed = rows(&rt, &key);
    // git names the line before a hunk as its section.
    assert_eq!(closed[0], "@@ -7,7 +7,7 @@ l6");
    // The old file is read at once, to know what follows the last hunk.
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| d.old_file().is_some())
    });
    let closed = rows(&rt, &key);
    assert_eq!(closed.last().expect("rows"), "end");
    let layout = rt
        .repo(&key)
        .and_then(|s| s.diff())
        .expect("diff")
        .layout()
        .clone();
    assert_eq!(layout.expanders(0), Expanders::Up);
    assert_eq!(layout.expanders(1), Expanders::Both);

    // Up from the second hunk: 20 lines show.
    rt.expand_diff(&key, DiffSlot::Changes, 1, Expand::Up);
    wait_for_diff(&mut rt);
    let open_rows = rows(&rt, &key);
    let header = open_rows
        .iter()
        .position(|r| r.starts_with("@@ -37"))
        .expect("second header");
    assert_eq!(open_rows[header], "@@ -37,27 +37,27 @@");
    assert_eq!(open_rows[header + 1], "~37 l37");
    assert_eq!(open_rows[header + 20], "~56 l56");

    // A reload (any status refresh) keeps the open gap.
    repo.write("f.txt", &lines(100, &[10, 60, 61]));
    rt.select_change(&key, Path::new("f.txt"), true);
    wait_for_diff(&mut rt);
    assert!(rows(&rt, &key).contains(&"~56 l56".to_owned()));

    // The whole file: every line once, no headers or end row.
    rt.show_whole_diff(&key, DiffSlot::Changes, true);
    wait_for_diff(&mut rt);
    let whole = rows(&rt, &key);
    assert_eq!(whole[0], "~1 l1");
    assert_eq!(whole.last().expect("rows"), "~100 l100");
    assert!(!whole.iter().any(|r| r.starts_with("@@") || r == "end"));
    assert_eq!(whole.len(), 100 + 3);

    rt.show_whole_diff(&key, DiffSlot::Changes, false);
    wait_for_diff(&mut rt);
    assert_eq!(rows(&rt, &key)[0], closed[0]);

    // Another file starts closed.
    repo.write("g.txt", "new\n");
    rt.select_change(&key, Path::new("g.txt"), false);
    poll_until(&mut rt, |rt, _| {
        rt.repo(&key)
            .and_then(|s| s.diff())
            .is_some_and(|d| d.target().path == Path::new("g.txt") && d.diff().is_some())
    });
    let state = rt.repo(&key).and_then(|s| s.diff()).expect("diff");
    assert!(!state.layout().has_hidden());
    assert!(!state.expansion().is_whole());
}
