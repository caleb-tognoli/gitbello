//! Repository read commands: status, refs, worktrees, stashes, diff,
//! op-state, watch and config.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use gitbello_core::backend::{CliBackend, GitBackend};
use gitbello_core::config::Config;
use gitbello_core::diff::{
    display_text, DiffContent, DiffKind, DiffTarget, LineKind, LARGE_DIFF_BYTES,
};
use gitbello_core::git::{CancelToken, CommandOutcome, GitRunner};
use gitbello_core::paths;
use gitbello_core::repo::{Change, FileChange, FileState, Head, RefKind};
use gitbello_core::watch::{RepoWatcher, WatchTarget, DEFAULT_DEBOUNCE};

/// A titled group of items selected by a predicate.
type Section<T> = (&'static str, fn(&T) -> bool);

/// The configured git (settings override) or the one on `PATH`.
pub fn runner() -> Result<GitRunner> {
    let config = match paths::config_file() {
        Some(file) => Config::load(&file).with_context(|| format!("loading {}", file.display()))?,
        None => Config::default(),
    };
    Ok(GitRunner::from_override(config.git_path.as_deref())?)
}

fn repo_arg(args: &[String], command: &str) -> Result<PathBuf> {
    match args {
        [path] => Ok(PathBuf::from(path)),
        _ => bail!("{command} needs exactly one repository path"),
    }
}

fn backend() -> Result<CliBackend> {
    Ok(CliBackend::new(runner()?))
}

/// Prints the git commands a CLI command ran, when `GITBELLO_LOG` is set.
pub fn print_command_log(backend: &CliBackend) {
    if std::env::var_os("GITBELLO_LOG").is_none() {
        return;
    }
    for record in backend.runner().log().records_since(0) {
        let outcome = match record.outcome {
            CommandOutcome::Succeeded => "ok".to_owned(),
            CommandOutcome::Failed(kind) => format!("failed: {kind}"),
            CommandOutcome::Cancelled => "cancelled".to_owned(),
        };
        eprintln!(
            "git {}  ({:.1} ms, {outcome})",
            record.command,
            record.duration.as_secs_f64() * 1e3
        );
    }
}

pub fn status(args: &[String]) -> Result<()> {
    let repo = repo_arg(args, "status")?;
    let backend = backend()?;
    let status = backend.status(&repo, &CancelToken::new())?;
    let head = match &status.head {
        Head::Branch(name) => format!("On branch {name}"),
        Head::Detached => "HEAD detached".to_owned(),
        Head::Unknown => "HEAD unknown".to_owned(),
    };
    let commit = status
        .oid
        .as_deref()
        .map_or("no commits yet".to_owned(), |oid| {
            oid.chars().take(7).collect()
        });
    let upstream = status.upstream.as_ref().map_or(String::new(), |up| {
        format!(" · {up} ↑{} ↓{}", status.ahead, status.behind)
    });
    println!(
        "{head} ({commit}){upstream} · {} stash(es)",
        status.stash_count
    );

    let groups: [Section<FileChange>; 4] = [
        ("Conflicts", |c| matches!(c.state, FileState::Unmerged(_))),
        ("Staged", FileChange::is_staged),
        (
            "Unstaged",
            |c| matches!(c.state, FileState::Tracked { worktree, .. } if worktree != Change::Unmodified),
        ),
        ("Untracked", |c| c.state == FileState::Untracked),
    ];
    for (title, filter) in groups {
        let items: Vec<&FileChange> = status.changes.iter().filter(|c| filter(c)).collect();
        if items.is_empty() {
            continue;
        }
        println!("{title}:");
        for change in items {
            let from = change
                .original_path
                .as_ref()
                .map_or(String::new(), |p| format!(" <- {}", p.display()));
            let sub = if change.submodule { " (submodule)" } else { "" };
            println!(
                "  {:<14} {}{from}{sub}",
                describe(change.state),
                change.path.display()
            );
        }
    }
    if status.is_clean() {
        println!("Nothing to commit, working tree clean");
    }
    print_command_log(&backend);
    Ok(())
}

fn describe(state: FileState) -> String {
    match state {
        FileState::Tracked { index, worktree } => {
            let side = |c: Change| match c {
                Change::Unmodified => "",
                Change::Modified => "modified",
                Change::TypeChanged => "typechange",
                Change::Added => "added",
                Change::Deleted => "deleted",
                Change::Renamed => "renamed",
                Change::Copied => "copied",
            };
            match (side(index), side(worktree)) {
                (i, "") => i.to_owned(),
                ("", w) => w.to_owned(),
                (i, w) => format!("{i}+{w}"),
            }
        }
        FileState::Unmerged(conflict) => format!("{conflict:?}"),
        FileState::Untracked => "untracked".to_owned(),
        FileState::Ignored => "ignored".to_owned(),
    }
}

pub fn refs(args: &[String]) -> Result<()> {
    let repo = repo_arg(args, "refs")?;
    let backend = backend()?;
    let refs = backend.refs(&repo, &CancelToken::new())?;
    let sections: [Section<RefKind>; 4] = [
        ("Branches", |k| *k == RefKind::Branch),
        ("Remote branches", |k| {
            matches!(k, RefKind::RemoteBranch { .. })
        }),
        ("Tags", |k| *k == RefKind::Tag),
        ("Other", |k| matches!(k, RefKind::Stash | RefKind::Other)),
    ];
    for (title, filter) in sections {
        let items: Vec<_> = refs.iter().filter(|r| filter(&r.kind)).collect();
        if items.is_empty() {
            continue;
        }
        println!("{title}:");
        for r in items {
            let mut notes = Vec::new();
            if let Some(up) = &r.upstream {
                let up = up.strip_prefix("refs/remotes/").unwrap_or(up);
                if r.tracking.gone {
                    notes.push(format!("{up}: gone"));
                } else {
                    notes.push(format!("{up} ↑{} ↓{}", r.tracking.ahead, r.tracking.behind));
                }
            }
            if let Some(target) = &r.symref_target {
                notes.push(format!("-> {target}"));
            }
            if let Some(wt) = &r.worktree {
                notes.push(format!("worktree {}", wt.display()));
            }
            if r.peeled.is_some() {
                notes.push("annotated".to_owned());
            }
            let head = if r.is_head { "*" } else { " " };
            let notes = if notes.is_empty() {
                String::new()
            } else {
                format!("  [{}]", notes.join(", "))
            };
            println!(
                "{head} {:<40} {}{notes}",
                r.short_name,
                &r.commit()[..7.min(r.commit().len())]
            );
        }
    }
    print_command_log(&backend);
    Ok(())
}

pub fn worktrees(args: &[String]) -> Result<()> {
    let repo = repo_arg(args, "worktrees")?;
    let backend = backend()?;
    for wt in backend.worktrees(&repo, &CancelToken::new())? {
        let what = if wt.bare {
            "(bare)".to_owned()
        } else if wt.detached {
            format!(
                "(detached at {})",
                wt.head
                    .as_deref()
                    .unwrap_or("?")
                    .chars()
                    .take(7)
                    .collect::<String>()
            )
        } else {
            wt.branch_name().unwrap_or("(no branch)").to_owned()
        };
        let mut flags = Vec::new();
        if wt.is_main {
            flags.push("main".to_owned());
        }
        if let Some(reason) = &wt.locked {
            flags.push(if reason.is_empty() {
                "locked".into()
            } else {
                format!("locked: {reason}")
            });
        }
        if let Some(reason) = &wt.prunable {
            flags.push(format!("prunable: {reason}"));
        }
        let flags = if flags.is_empty() {
            String::new()
        } else {
            format!("  [{}]", flags.join(", "))
        };
        println!("{}  {what}{flags}", wt.path.display());
    }
    print_command_log(&backend);
    Ok(())
}

pub fn diff(args: &[String]) -> Result<()> {
    let mut positional = Vec::new();
    let mut kind = DiffKind::Unstaged;
    let mut full = false;
    for arg in args {
        match arg.as_str() {
            "--staged" => kind = DiffKind::Staged,
            "--untracked" => kind = DiffKind::Untracked,
            "--full" => full = true,
            other => positional.push(other),
        }
    }
    let [root, file] = positional[..] else {
        bail!("diff needs a worktree root and a file path");
    };
    let backend = backend()?;
    let target = DiffTarget {
        kind,
        path: PathBuf::from(file),
        original_path: None,
        commit: None,
    };
    let limit = (!full).then_some(LARGE_DIFF_BYTES);
    let started = std::time::Instant::now();
    let diff = backend.diff(Path::new(root), &target, limit, &CancelToken::new())?;
    let elapsed = started.elapsed();
    for note in diff.header.notes() {
        println!("# {note}");
    }
    match diff.content {
        DiffContent::Binary { old_size, new_size } => {
            println!("# binary: {old_size:?} -> {new_size:?} bytes");
        }
        DiffContent::TooLarge { bytes } => println!("# too large: over {bytes} bytes (--full)"),
        DiffContent::Text | DiffContent::Combined => {}
    }
    let number = |n: Option<u32>| n.map_or_else(String::new, |n| n.to_string());
    for line in diff.lines(0, usize::MAX) {
        let mark = match line.kind {
            LineKind::Hunk => "",
            LineKind::Context => " ",
            LineKind::Added => "+",
            LineKind::Removed => "-",
        };
        println!(
            "{:>6} {:>6} {mark}{}{}",
            number(line.old_line),
            number(line.new_line),
            display_text(line.text),
            if line.no_newline {
                "  (no newline)"
            } else {
                ""
            }
        );
    }
    eprintln!(
        "{} lines, +{} -{}, loaded and parsed in {:.1} ms",
        diff.line_count(),
        diff.additions,
        diff.deletions,
        elapsed.as_secs_f64() * 1e3
    );
    print_command_log(&backend);
    Ok(())
}

pub fn stashes(args: &[String]) -> Result<()> {
    let repo = repo_arg(args, "stashes")?;
    let backend = backend()?;
    let stashes = backend.stashes(&repo, &CancelToken::new())?;
    if stashes.is_empty() {
        println!("No stashes");
    }
    for s in stashes {
        let branch = s
            .branch
            .as_deref()
            .map_or(String::new(), |b| format!("{b}: "));
        println!("stash@{{{}}}  {branch}{}", s.index, s.message);
    }
    print_command_log(&backend);
    Ok(())
}

pub fn op_state(args: &[String]) -> Result<()> {
    let repo = repo_arg(args, "op-state")?;
    let backend = backend()?;
    let paths = backend.repo_paths(&repo, &CancelToken::new())?;
    println!("git dir     {}", paths.git_dir.display());
    println!("common dir  {}", paths.common_dir.display());
    println!("bare        {}", paths.bare);
    match backend.operation(&repo, &CancelToken::new())? {
        Some(op) => println!("operation   {op:?} in progress"),
        None => println!("operation   none"),
    }
    print_command_log(&backend);
    Ok(())
}

/// Watches `path` and prints the refreshes changes would trigger, until killed.
pub fn watch(args: &[String]) -> Result<()> {
    let repo = repo_arg(args, "watch")?;
    let backend = Arc::new(backend()?);
    let paths = backend.repo_paths(&repo, &CancelToken::new())?;
    let watcher = RepoWatcher::new(backend, DEFAULT_DEBOUNCE, |repo: &Path, set| {
        println!("{}  {set:?}", repo.display());
    })?;
    watcher.watch(&WatchTarget::new(&repo, &repo, &paths))?;
    eprintln!("watching {} (Ctrl+C to stop)", repo.display());
    loop {
        std::thread::park();
    }
}

pub fn config(args: &[String]) -> Result<()> {
    if !args.is_empty() {
        bail!("config takes no arguments");
    }
    let file = paths::config_file().context("no config directory on this system")?;
    println!("# {}", file.display());
    print!("{}", Config::load(&file)?.to_toml());
    Ok(())
}
