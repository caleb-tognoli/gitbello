//! File watching (PLAN §3.6).
//!
//! The watcher only decides *which* refreshes a change needs; status and the
//! other reads do the real work. Changes are debounced per repository, object
//! database churn is ignored, and working-tree changes that git ignores (build
//! output and the like) are dropped with one batched `git check-ignore`.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use notify::event::{AccessKind, AccessMode};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher as _};
use thiserror::Error;

use crate::backend::GitBackend;
use crate::git::CancelToken;
use crate::jobs::{RefreshKind, RefreshSet};
use crate::repo::RepoPaths;

/// Quiet time before a burst of changes is reported.
pub const DEFAULT_DEBOUNCE: Duration = Duration::from_millis(250);

/// Worktree paths remembered per burst for the ignore check; beyond this the
/// burst simply counts as a status change.
const MAX_PATHS_PER_BURST: usize = 512;

#[derive(Debug, Error)]
pub enum WatchError {
    #[error("cannot watch {path}: {source}")]
    Notify {
        path: PathBuf,
        #[source]
        source: notify::Error,
    },
    #[error("cannot resolve {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

/// What to watch for one open worktree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatchTarget {
    /// Key reported back in change callbacks (usually the tab's path).
    pub repo: PathBuf,
    pub worktree: PathBuf,
    pub git_dir: PathBuf,
    pub common_dir: PathBuf,
}

impl WatchTarget {
    pub fn new(repo: impl Into<PathBuf>, worktree: impl Into<PathBuf>, paths: &RepoPaths) -> Self {
        Self {
            repo: repo.into(),
            worktree: worktree.into(),
            git_dir: paths.git_dir.clone(),
            common_dir: paths.common_dir.clone(),
        }
    }

    /// Canonical paths so they compare equal to what the OS reports.
    fn canonical(&self) -> Result<Self, WatchError> {
        let canon = |path: &Path| {
            fs::canonicalize(path).map_err(|source| WatchError::Io {
                path: path.to_path_buf(),
                source,
            })
        };
        Ok(Self {
            repo: self.repo.clone(),
            worktree: canon(&self.worktree)?,
            git_dir: canon(&self.git_dir)?,
            common_dir: canon(&self.common_dir)?,
        })
    }

    /// Directories to watch recursively, without nesting.
    fn roots(&self) -> Vec<PathBuf> {
        let mut roots = vec![self.worktree.clone()];
        for dir in [&self.common_dir, &self.git_dir] {
            if !roots.iter().any(|root| dir.starts_with(root)) {
                roots.push(dir.clone());
            }
        }
        roots
    }
}

/// How a changed path affects a repository.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    Ignore,
    Refresh(RefreshSet),
    /// A working-tree file, relative to the worktree; needs a status refresh
    /// unless git ignores it.
    WorktreeFile(PathBuf),
}

/// Classifies an absolute, canonical `path` for `target` (also canonical).
pub fn classify(target: &WatchTarget, path: &Path) -> Change {
    let set = |kinds: &[RefreshKind]| Change::Refresh(kinds.iter().copied().collect());
    if path.extension().is_some_and(|ext| ext == "lock") {
        return Change::Ignore;
    }
    // Per-worktree git dir first (it may live inside the common dir).
    for dir in [&target.git_dir, &target.common_dir] {
        let Ok(rel) = path.strip_prefix(dir) else {
            continue;
        };
        let rel = rel.to_string_lossy().replace('\\', "/");
        let first = rel.split('/').next().unwrap_or_default();
        use RefreshKind::*;
        return match first {
            "" => Change::Ignore,
            "objects" | "hooks" | "info" | "description" | "COMMIT_EDITMSG" | "gitk.cache" => {
                Change::Ignore
            }
            "index" => set(&[Status]),
            "HEAD" | "ORIG_HEAD" | "FETCH_HEAD" | "packed-refs" | "config" => set(&[Status, Refs]),
            "refs" if rel == "refs/stash" => set(&[Status, Refs, Stashes]),
            "refs" => set(&[Status, Refs]),
            "logs" if rel == "logs/refs/stash" => set(&[Stashes]),
            "logs" => Change::Ignore,
            "MERGE_HEAD" | "CHERRY_PICK_HEAD" | "REVERT_HEAD" | "REBASE_HEAD" | "BISECT_LOG"
            | "MERGE_MSG" | "rebase-merge" | "rebase-apply" | "sequencer" => {
                set(&[Status, Operation])
            }
            // Linked worktrees are registered here. A linked target's own git
            // dir lives below it too, but matched in the first iteration.
            "worktrees" => set(&[Worktrees, WorktreeBadges]),
            _ => Change::Ignore,
        };
    }
    match path.strip_prefix(&target.worktree) {
        Ok(rel) if !rel.as_os_str().is_empty() => Change::WorktreeFile(rel.to_path_buf()),
        _ => Change::Ignore,
    }
}

type OnChange = Box<dyn Fn(&Path, RefreshSet) + Send>;

struct Burst {
    refresh: RefreshSet,
    files: HashSet<PathBuf>,
    overflow: bool,
    first: Instant,
    last: Instant,
}

enum Message {
    Fs(notify::Result<notify::Event>),
    Stop,
}

/// Watches open worktrees and reports which refreshes they need.
pub struct RepoWatcher {
    watcher: Mutex<RecommendedWatcher>,
    targets: Arc<Mutex<Vec<WatchTarget>>>,
    tx: Sender<Message>,
    thread: Option<JoinHandle<()>>,
}

impl RepoWatcher {
    /// `on_change(repo, refreshes)` runs on the watcher thread; keep it cheap
    /// (for example, `JobScheduler::request_refresh`).
    pub fn new(
        backend: Arc<dyn GitBackend>,
        debounce: Duration,
        on_change: impl Fn(&Path, RefreshSet) + Send + 'static,
    ) -> Result<Self, WatchError> {
        let (tx, rx) = mpsc::channel::<Message>();
        let fs_tx = tx.clone();
        let watcher = notify::recommended_watcher(move |event| {
            let _ = fs_tx.send(Message::Fs(event));
        })
        .map_err(|source| WatchError::Notify {
            path: PathBuf::new(),
            source,
        })?;
        let targets = Arc::new(Mutex::new(Vec::new()));
        let thread_targets = Arc::clone(&targets);
        let on_change: OnChange = Box::new(on_change);
        let thread = thread::Builder::new()
            .name("gitbello-watch".into())
            .spawn(move || {
                debounce_loop(&rx, &thread_targets, backend.as_ref(), debounce, &on_change)
            })
            .ok();
        Ok(Self {
            watcher: Mutex::new(watcher),
            targets,
            tx,
            thread,
        })
    }

    pub fn watch(&self, target: &WatchTarget) -> Result<(), WatchError> {
        let target = target.canonical()?;
        let mut watcher = self.watcher.lock().unwrap_or_else(PoisonError::into_inner);
        let mut targets = self.targets.lock().unwrap_or_else(PoisonError::into_inner);
        if targets.iter().any(|t| t.repo == target.repo) {
            return Ok(());
        }
        let watched: HashSet<PathBuf> = targets.iter().flat_map(WatchTarget::roots).collect();
        for root in target.roots() {
            if watched.iter().any(|w| root.starts_with(w)) {
                continue;
            }
            watcher
                .watch(&root, RecursiveMode::Recursive)
                .map_err(|source| WatchError::Notify {
                    path: root.clone(),
                    source,
                })?;
        }
        targets.push(target);
        Ok(())
    }

    pub fn unwatch(&self, repo: &Path) {
        let mut watcher = self.watcher.lock().unwrap_or_else(PoisonError::into_inner);
        let mut targets = self.targets.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(pos) = targets.iter().position(|t| t.repo == repo) else {
            return;
        };
        let removed = targets.remove(pos);
        let still_needed: HashSet<PathBuf> = targets.iter().flat_map(WatchTarget::roots).collect();
        for root in removed.roots() {
            if !still_needed.iter().any(|w| root.starts_with(w)) {
                let _ = watcher.unwatch(&root);
            }
        }
    }
}

impl Drop for RepoWatcher {
    fn drop(&mut self) {
        let _ = self.tx.send(Message::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn debounce_loop(
    rx: &Receiver<Message>,
    targets: &Mutex<Vec<WatchTarget>>,
    backend: &dyn GitBackend,
    debounce: Duration,
    on_change: &OnChange,
) {
    let max_delay = debounce * 4;
    let mut bursts: HashMap<PathBuf, Burst> = HashMap::new();
    loop {
        match rx.recv_timeout(debounce / 4) {
            Ok(Message::Stop) | Err(RecvTimeoutError::Disconnected) => return,
            Ok(Message::Fs(Ok(event))) if !changes_content(&event.kind) => {}
            Ok(Message::Fs(Ok(event))) => {
                let targets = targets.lock().unwrap_or_else(PoisonError::into_inner);
                for path in &event.paths {
                    for target in targets.iter() {
                        record(&mut bursts, target, classify(target, path));
                    }
                }
            }
            Ok(Message::Fs(Err(_))) | Err(RecvTimeoutError::Timeout) => {}
        }
        let now = Instant::now();
        let due: Vec<PathBuf> = bursts
            .iter()
            .filter(|(_, b)| now - b.last >= debounce || now - b.first >= max_delay)
            .map(|(repo, _)| repo.clone())
            .collect();
        for repo in due {
            let Some(burst) = bursts.remove(&repo) else {
                continue;
            };
            let mut refresh = burst.refresh;
            if !refresh.contains(RefreshKind::Status)
                && (burst.overflow || has_unignored(backend, &repo, &burst.files))
            {
                refresh = refresh.with(RefreshKind::Status);
            }
            if !refresh.is_empty() {
                on_change(&repo, refresh);
            }
        }
    }
}

/// Whether an event can mean changed content. inotify also reports reads
/// (open, close without writing); counting those would make our own git reads
/// trigger more refreshes, forever.
fn changes_content(kind: &EventKind) -> bool {
    match kind {
        EventKind::Access(AccessKind::Close(AccessMode::Write)) => true,
        EventKind::Access(_) => false,
        _ => true,
    }
}

fn record(bursts: &mut HashMap<PathBuf, Burst>, target: &WatchTarget, change: Change) {
    if change == Change::Ignore {
        return;
    }
    let now = Instant::now();
    let burst = bursts.entry(target.repo.clone()).or_insert_with(|| Burst {
        refresh: RefreshSet::EMPTY,
        files: HashSet::new(),
        overflow: false,
        first: now,
        last: now,
    });
    burst.last = now;
    match change {
        Change::Refresh(set) => burst.refresh = burst.refresh.union(set),
        Change::WorktreeFile(path) => {
            if burst.files.len() < MAX_PATHS_PER_BURST {
                burst.files.insert(path);
            } else {
                burst.overflow = true;
            }
        }
        Change::Ignore => {}
    }
}

/// Whether any of `files` is not ignored by git. Errors count as changes.
fn has_unignored(backend: &dyn GitBackend, repo: &Path, files: &HashSet<PathBuf>) -> bool {
    if files.is_empty() {
        return false;
    }
    let paths: Vec<PathBuf> = files.iter().cloned().collect();
    match backend.ignored(repo, &paths, &CancelToken::new()) {
        Ok(ignored) => {
            let ignored: HashSet<String> = ignored.iter().map(|p| slash(p)).collect();
            paths.iter().any(|p| !ignored.contains(&slash(p)))
        }
        Err(_) => true,
    }
}

fn slash(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target() -> WatchTarget {
        WatchTarget {
            repo: PathBuf::from("/r"),
            worktree: PathBuf::from("/r"),
            git_dir: PathBuf::from("/r/.git"),
            common_dir: PathBuf::from("/r/.git"),
        }
    }

    fn linked() -> WatchTarget {
        WatchTarget {
            repo: PathBuf::from("/wt"),
            worktree: PathBuf::from("/wt"),
            git_dir: PathBuf::from("/r/.git/worktrees/wt"),
            common_dir: PathBuf::from("/r/.git"),
        }
    }

    fn kinds(change: Change) -> Vec<RefreshKind> {
        match change {
            Change::Refresh(set) => set.iter().collect(),
            other => panic!("expected refresh, got {other:?}"),
        }
    }

    #[test]
    fn classifies_git_dir_files() {
        use RefreshKind::*;
        let t = target();
        let c = |p: &str| classify(&t, Path::new(p));
        assert_eq!(kinds(c("/r/.git/index")), [Status]);
        assert_eq!(kinds(c("/r/.git/HEAD")), [Status, Refs]);
        assert_eq!(kinds(c("/r/.git/refs/heads/feature/x")), [Status, Refs]);
        assert_eq!(kinds(c("/r/.git/refs/stash")), [Status, Refs, Stashes]);
        assert_eq!(kinds(c("/r/.git/logs/refs/stash")), [Stashes]);
        assert_eq!(kinds(c("/r/.git/MERGE_HEAD")), [Status, Operation]);
        assert_eq!(kinds(c("/r/.git/rebase-merge/done")), [Status, Operation]);
        assert_eq!(
            kinds(c("/r/.git/worktrees/wt/HEAD")),
            [Worktrees, WorktreeBadges]
        );
        for ignored in [
            "/r/.git/objects/ab/cdef",
            "/r/.git/index.lock",
            "/r/.git/refs/heads/main.lock",
            "/r/.git/logs/HEAD",
            "/r/.git/hooks/pre-commit",
            "/r/.git",
            "/elsewhere/file",
        ] {
            assert_eq!(c(ignored), Change::Ignore, "{ignored}");
        }
        assert_eq!(
            c("/r/src/main.rs"),
            Change::WorktreeFile(PathBuf::from("src/main.rs"))
        );
    }

    #[test]
    fn classifies_linked_worktree_paths() {
        use RefreshKind::*;
        let t = linked();
        let c = |p: &str| classify(&t, Path::new(p));
        // Its own index and HEAD live under the common dir's worktrees/.
        assert_eq!(kinds(c("/r/.git/worktrees/wt/index")), [Status]);
        assert_eq!(kinds(c("/r/.git/worktrees/wt/HEAD")), [Status, Refs]);
        // Shared refs still matter.
        assert_eq!(kinds(c("/r/.git/refs/heads/main")), [Status, Refs]);
        // Other worktrees' registrations are worktree-list changes.
        assert_eq!(
            kinds(c("/r/.git/worktrees/other/HEAD")),
            [Worktrees, WorktreeBadges]
        );
        assert_eq!(c("/wt/a.txt"), Change::WorktreeFile(PathBuf::from("a.txt")));
        // The main worktree's files are not this target's business.
        assert_eq!(c("/r/a.txt"), Change::Ignore);
    }

    #[test]
    fn reads_are_not_changes() {
        use notify::event::{CreateKind, ModifyKind};
        assert!(!changes_content(&EventKind::Access(AccessKind::Open(
            AccessMode::Any
        ))));
        assert!(!changes_content(&EventKind::Access(AccessKind::Close(
            AccessMode::Read
        ))));
        assert!(changes_content(&EventKind::Access(AccessKind::Close(
            AccessMode::Write
        ))));
        assert!(changes_content(&EventKind::Modify(ModifyKind::Any)));
        assert!(changes_content(&EventKind::Create(CreateKind::File)));
    }

    #[test]
    fn roots_do_not_nest() {
        assert_eq!(target().roots(), [PathBuf::from("/r")]);
        assert_eq!(
            linked().roots(),
            [PathBuf::from("/wt"), PathBuf::from("/r/.git")]
        );
    }
}
