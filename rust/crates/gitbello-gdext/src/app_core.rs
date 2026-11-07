use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use gitbello_core::changes::split_message;
use gitbello_core::config::{parse_accent, LanguageChoice, ThemeChoice};
use gitbello_core::diff::rename_parts;
use gitbello_core::diff::version;
use gitbello_core::diff::viewer::{DiffMode, Viewer};
use gitbello_core::git::{CommandOutcome, GitErrorKind};
use gitbello_core::jobs::RefreshKind;
use gitbello_core::launch;
use gitbello_core::library::{self, RepoSummary};
use gitbello_core::new_repo::{
    init_folder_error, CloneOptions, CreateOptions, GITIGNORE_TEMPLATES,
};
use gitbello_core::ops::{branch_prefix_error, ref_name_error, PullMode};
use gitbello_core::paths;
use gitbello_core::runtime::{DiffSlot, JobState, Runtime, RuntimeEvent, REPOSITORY_JOB_LABELS};
use gitbello_core::ui_state::{self, UiState};
use gitbello_core::worktrees::new_worktree_path_error;
use godot::prelude::*;

use crate::convert::{self, gstr, path_str, to_i64};
use crate::repo_session::RepoSession;
use crate::runtime_cell;

/// Root of the native runtime, instanced once by the `Core` autoload
/// (`res://app/core/core.tscn`). Owns the core `Runtime`, drains its events
/// each frame and routes them to `RepoSession`s (PLAN §3.5).
#[derive(GodotClass)]
#[class(base = Node)]
pub struct AppCore {
    base: Base<Node>,
    sessions: HashMap<PathBuf, Gd<RepoSession>>,
    start_error: String,
    config_warning: String,
    library_warning: String,
    ui_state: UiState,
}

#[godot_api]
impl INode for AppCore {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            sessions: HashMap::new(),
            start_error: String::new(),
            config_warning: String::new(),
            library_warning: String::new(),
            ui_state: UiState::default(),
        }
    }

    fn ready(&mut self) {
        // GITBELLO_CONFIG points tests and dev runs at a scratch config file.
        let config_path = std::env::var_os("GITBELLO_CONFIG")
            .map(PathBuf::from)
            .or_else(paths::config_file);
        // Per-repo UI state goes next to a scratch config, else in the data dir.
        let ui_dir = match std::env::var_os("GITBELLO_CONFIG") {
            Some(config) => PathBuf::from(config).parent().map(Path::to_path_buf),
            None => paths::data_dir(),
        };
        self.ui_state = UiState::load(ui_dir.as_ref().map(|dir| dir.join(ui_state::FILE_NAME)));
        let (config, warning) = Runtime::load_config(config_path.as_deref());
        if let Some(warning) = warning {
            self.config_warning = warning.to_string();
        }
        // Versions written for Open by an earlier run.
        if let Some(dir) = paths::versions_dir() {
            version::clear_versions(&dir);
        }
        match Runtime::new(config, config_path) {
            Ok(mut runtime) => {
                let library = ui_dir.map(|dir| dir.join(library::FILE_NAME));
                if let Some(warning) = runtime.load_library(library) {
                    self.library_warning = warning.to_string();
                }
                runtime_cell::install(runtime);
            }
            Err(err) => self.start_error = err.to_string(),
        }
    }

    fn exit_tree(&mut self) {
        runtime_cell::uninstall();
    }

    /// Drains runtime events: one channel read when idle.
    fn process(&mut self, _delta: f64) {
        let events = runtime_cell::with(Runtime::poll).unwrap_or_default();
        self.sessions
            .retain(|_, session| session.is_instance_valid());
        let sessions: Vec<(PathBuf, Gd<RepoSession>)> = self
            .sessions
            .iter()
            .map(|(key, session)| (key.clone(), session.clone()))
            .collect();
        // Emitting re-enters GDScript, which may call back into Core: hold
        // `base_mut()` so those calls can bind this object again (pumping the
        // graph emits too).
        let mut guard = self.base_mut();
        for event in events {
            dispatch(&mut guard, &sessions, event);
        }
        for (_, mut session) in sessions {
            if session.is_instance_valid() {
                session.bind_mut().pump_graph();
            }
        }
        drop(guard);
    }
}

fn find(sessions: &[(PathBuf, Gd<RepoSession>)], repo: &Path) -> Option<Gd<RepoSession>> {
    sessions
        .iter()
        .find(|(key, s)| key == repo && s.is_instance_valid())
        .map(|(_, s)| s.clone())
}

fn dispatch(core: &mut Gd<Node>, sessions: &[(PathBuf, Gd<RepoSession>)], event: RuntimeEvent) {
    match event {
        RuntimeEvent::CommandsLogged => {
            core.emit_signal("commands_logged", &[]);
        }
        RuntimeEvent::LibraryChanged { error } => {
            core.emit_signal(
                "library_changed",
                &[gstr(error.as_deref().unwrap_or_default()).to_variant()],
            );
        }
        RuntimeEvent::SummaryLoaded { repo } => {
            core.emit_signal("repo_summary_ready", &[path_str(&repo).to_variant()]);
        }
        RuntimeEvent::Opened { repo } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal("opened", &[]);
            }
        }
        RuntimeEvent::OpenFailed { repo, error } => {
            let error = convert::error_dict(&error);
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal("open_failed", &[error.to_variant()]);
            }
            core.emit_signal(
                "git_error",
                &[path_str(&repo).to_variant(), error.to_variant()],
            );
        }
        RuntimeEvent::Updated { repo, kind } => {
            let Some(mut session) = find(sessions, &repo) else {
                return;
            };
            let signal = match kind {
                RefreshKind::Status => "status_changed",
                RefreshKind::Refs => "refs_changed",
                RefreshKind::Worktrees => "worktrees_changed",
                RefreshKind::Operation => "operation_changed",
                RefreshKind::Stashes => "stashes_changed",
                RefreshKind::WorktreeBadges => "worktrees_changed",
            };
            session.emit_signal(signal, &[]);
            if matches!(kind, RefreshKind::Status | RefreshKind::Operation) {
                session.emit_signal("badge_changed", &[]);
            }
        }
        RuntimeEvent::RefreshFailed { repo, error, .. } => {
            core.emit_signal(
                "git_error",
                &[
                    path_str(&repo).to_variant(),
                    convert::error_dict(&error).to_variant(),
                ],
            );
        }
        RuntimeEvent::SearchChanged { repo } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal("search_changed", &[]);
            }
        }
        RuntimeEvent::GraphReset { repo } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.bind_mut().reset_graph();
            }
        }
        RuntimeEvent::SelectionChanged { repo } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal("selection_changed", &[]);
            }
        }
        RuntimeEvent::DiffChanged { repo, slot } => {
            if let Some(mut session) = find(sessions, &repo) {
                let signal = match slot {
                    DiffSlot::Changes => "diff_changed",
                    DiffSlot::Commit => "commit_diff_changed",
                };
                session.emit_signal(signal, &[]);
            }
        }
        RuntimeEvent::Missing { repo } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal("missing", &[]);
            }
        }
        RuntimeEvent::ShelfLoaded { repo, oid } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal("shelf_files_loaded", &[gstr(&oid).to_variant()]);
            }
        }
        RuntimeEvent::ShelfReplaced {
            repo,
            old_oid,
            new_oid,
        } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal(
                    "shelf_replaced",
                    &[
                        gstr(&old_oid).to_variant(),
                        gstr(new_oid.as_deref().unwrap_or_default()).to_variant(),
                    ],
                );
            }
        }
        RuntimeEvent::CleanupLoaded { repo } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal("cleanup_loaded", &[]);
            }
        }
        RuntimeEvent::MergePreviewLoaded { repo, target } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal("merge_preview_ready", &[gstr(&target).to_variant()]);
            }
        }
        RuntimeEvent::BranchDeleteInfoLoaded { repo, job } => {
            if let Some(mut session) = find(sessions, &repo) {
                let job = i64::try_from(job).unwrap_or(i64::MAX);
                session.emit_signal("branch_delete_info_ready", &[job.to_variant()]);
            }
        }
        RuntimeEvent::IgnorePreviewLoaded { repo, job } => {
            if let Some(mut session) = find(sessions, &repo) {
                let job = i64::try_from(job).unwrap_or(i64::MAX);
                session.emit_signal("ignore_preview_ready", &[job.to_variant()]);
            }
        }
        RuntimeEvent::IgnoreRulesLoaded { repo, job } => {
            if let Some(mut session) = find(sessions, &repo) {
                let job = i64::try_from(job).unwrap_or(i64::MAX);
                session.emit_signal("ignore_rules_ready", &[job.to_variant()]);
            }
        }
        RuntimeEvent::HeadInfoChanged { repo } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal("head_changed", &[]);
            }
        }
        RuntimeEvent::CommitUndone { repo, message } => {
            if let Some(mut session) = find(sessions, &repo) {
                let (summary, body) = split_message(&message);
                session.emit_signal(
                    "commit_undone",
                    &[gstr(&summary).to_variant(), gstr(&body).to_variant()],
                );
            }
        }
        RuntimeEvent::VersionReady { repo, result } => {
            if let Some(mut session) = find(sessions, &repo) {
                let (path, error) = match &result {
                    Ok(path) => (path_str(path), VarDictionary::new()),
                    Err(error) => (GString::new(), convert::error_dict(error)),
                };
                session.emit_signal("version_ready", &[path.to_variant(), error.to_variant()]);
            }
        }
        RuntimeEvent::CommitLoaded { repo } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal("commit_loaded", &[]);
            }
        }
        RuntimeEvent::HeadMessage { repo, message } => {
            if let Some(mut session) = find(sessions, &repo) {
                let (summary, body) = split_message(&message);
                session.emit_signal(
                    "head_message_loaded",
                    &[gstr(&summary).to_variant(), gstr(&body).to_variant()],
                );
            }
        }
        RuntimeEvent::Job {
            repo,
            job,
            label,
            state,
        } => {
            let job = i64::try_from(job).unwrap_or(i64::MAX).to_variant();
            if REPOSITORY_JOB_LABELS.contains(&label.as_str()) {
                let path = path_str(&repo).to_variant();
                let label = gstr(&label).to_variant();
                match state {
                    JobState::Started => {
                        core.emit_signal("repository_job_started", &[job, path, label]);
                    }
                    JobState::Progress(p) => {
                        let percent = p.percent.map_or(-1, i64::from);
                        core.emit_signal(
                            "repository_job_progress",
                            &[
                                job,
                                path,
                                label,
                                percent.to_variant(),
                                gstr(&p.text).to_variant(),
                            ],
                        );
                    }
                    JobState::Finished(error) => {
                        let ok = error.is_none();
                        let error = error.as_ref().map(convert::error_dict).unwrap_or_default();
                        core.emit_signal(
                            "repository_job_finished",
                            &[job, path, label, ok.to_variant(), error.to_variant()],
                        );
                    }
                    JobState::Cancelled => {
                        core.emit_signal("repository_job_cancelled", &[job, path, label]);
                    }
                }
                return;
            }
            let Some(mut session) = find(sessions, &repo) else {
                return;
            };
            let label = gstr(&label).to_variant();
            match state {
                JobState::Started => {
                    session.emit_signal("job_started", &[job, label]);
                }
                JobState::Progress(p) => {
                    let percent = p.percent.map_or(-1, i64::from);
                    session.emit_signal(
                        "job_progress",
                        &[job, label, percent.to_variant(), gstr(&p.text).to_variant()],
                    );
                }
                JobState::Finished(error) => {
                    let ok = error.is_none();
                    // A refusal the UI answers with a dialog, not an error.
                    let decision = error
                        .as_ref()
                        .is_some_and(|e| e.kind == GitErrorKind::TrackedMatches);
                    let error = error.as_ref().map(convert::error_dict).unwrap_or_default();
                    session.emit_signal(
                        "job_finished",
                        &[job, label, ok.to_variant(), error.to_variant()],
                    );
                    if !ok && !decision {
                        core.emit_signal(
                            "git_error",
                            &[path_str(&repo).to_variant(), error.to_variant()],
                        );
                    }
                }
                JobState::Cancelled => {
                    session.emit_signal("job_cancelled", &[job, label]);
                }
            }
        }
    }
}

#[godot_api]
impl AppCore {
    /// A git command failed in a way the user should see (toast).
    /// `error`: `{kind, title, message, command, stderr, exit_code}`.
    #[signal]
    fn git_error(repo_path: GString, error: VarDictionary);

    /// Lifecycle of a job about a folder rather than an open repository:
    /// create, initialize, clone, scan and location checks.
    #[signal]
    fn repository_job_started(job: i64, path: GString, label: GString);
    #[signal]
    fn repository_job_progress(
        job: i64,
        path: GString,
        label: GString,
        percent: i64,
        text: GString,
    );
    #[signal]
    fn repository_job_finished(
        job: i64,
        path: GString,
        label: GString,
        ok: bool,
        error: VarDictionary,
    );
    #[signal]
    fn repository_job_cancelled(job: i64, path: GString, label: GString);

    /// New entries are in the git command log (`command_log`).
    #[signal]
    fn commands_logged();

    /// The repository library changed; `error` is why saving it failed, or "".
    #[signal]
    fn library_changed(error: GString);

    /// The summary of library entry `path` (see `repo_summary`) arrived.
    #[signal]
    fn repo_summary_ready(path: GString);

    /// Emitted in response to `ping` (M0 boundary check).
    #[signal]
    fn pong(message: GString);

    /// Version of `gitbello-core`.
    #[func]
    fn core_version(&self) -> GString {
        gitbello_core::VERSION.into()
    }

    /// Asks the core for a greeting and emits it through `pong`.
    #[func]
    fn ping(&mut self, name: GString) {
        let message = gitbello_core::greeting(&name.to_string());
        self.signals().pong().emit(&gstr(&message));
    }

    /// Why the runtime could not start (git missing or too old); empty when running.
    #[func]
    fn start_error(&self) -> GString {
        gstr(&self.start_error)
    }

    /// Problem reading the config file (defaults are used); empty when fine.
    #[func]
    fn config_warning(&self) -> GString {
        gstr(&self.config_warning)
    }

    #[func]
    fn git_version(&self) -> GString {
        runtime_cell::with(|rt| gstr(&rt.git_version().to_string())).unwrap_or_default()
    }

    /// Initializes a repository on a worker thread; returns its job id.
    /// `options`: `{initial_branch, gitignore (template name or ""), readme,
    /// first_commit, existing}` (`existing` initializes a folder with files).
    #[func]
    fn create_repository(&mut self, path: GString, options: VarDictionary) -> i64 {
        let flag = |key: &str| {
            options
                .get(key)
                .and_then(|v| v.try_to::<bool>().ok())
                .unwrap_or(false)
        };
        let text = |key: &str| options.get(key).map(|v| v.to_string()).unwrap_or_default();
        let branch = text("initial_branch");
        let mut create = CreateOptions::new(if branch.is_empty() { "main" } else { &branch });
        let template = text("gitignore");
        create.gitignore = (!template.is_empty()).then_some(template);
        create.readme = flag("readme");
        create.first_commit = flag("first_commit");
        create.existing = flag("existing");
        job_id(runtime_cell::with(|rt| {
            rt.create_repository(Path::new(&path.to_string()), create)
        }))
    }

    /// Clones a repository on a worker thread; returns its job id.
    /// `options`: `{branch ("" for the remote's default), submodules}`.
    #[func]
    fn clone_repository(&mut self, url: GString, path: GString, options: VarDictionary) -> i64 {
        let branch = options
            .get("branch")
            .map(|v| v.to_string())
            .unwrap_or_default();
        let clone = CloneOptions {
            branch: (!branch.trim().is_empty()).then(|| branch.trim().to_owned()),
            submodules: options
                .get("submodules")
                .and_then(|v| v.try_to::<bool>().ok())
                .unwrap_or(false),
        };
        let path = PathBuf::from(path.to_string());
        job_id(runtime_cell::with(|rt| {
            if let Some(parent) = path.parent() {
                rt.config_mut().last_clone_folder = Some(parent.to_path_buf());
                let _ = rt.save_config();
            }
            rt.clone_repository(&url.to_string(), &path, clone)
        }))
    }

    /// Cancels a create, initialize, clone, scan or location job.
    #[func]
    fn cancel_repository_job(&self, job: i64) -> bool {
        u64::try_from(job)
            .ok()
            .and_then(|job| runtime_cell::with(|rt| rt.cancel_job(job)))
            .unwrap_or(false)
    }

    /// Opens a repository (or returns the existing session for it). Add the
    /// returned node to the tree; free it after `close_session`.
    #[func]
    fn open_session(&mut self, path: GString) -> Option<Gd<RepoSession>> {
        let key = runtime_cell::with(|rt| rt.open(Path::new(&path.to_string())))?;
        if let Some(existing) = self.sessions.get(&key).filter(|s| s.is_instance_valid()) {
            return Some(existing.clone());
        }
        let mut session = RepoSession::new_alloc();
        session.bind_mut().set_key(key.clone());
        session.set_name(&StringName::from(
            format!(
                "Session {}",
                key.file_name()
                    .map_or_else(|| "repo".into(), |n| n.to_string_lossy())
            )
            .as_str(),
        ));
        self.sessions.insert(key, session.clone());
        Some(session)
    }

    /// Closes a session's repository in the core (jobs, watcher, state).
    #[func]
    fn close_session(&mut self, session: Gd<RepoSession>) {
        let key = session.bind().key().to_path_buf();
        self.sessions.remove(&key);
        runtime_cell::with(|rt| rt.close(&key));
    }

    /// Refresh after the window regains focus (PLAN §3.6).
    #[func]
    fn focus_in(&self, session: Gd<RepoSession>) {
        let key = session.bind().key().to_path_buf();
        runtime_cell::with(|rt| rt.on_focus(&key));
    }

    /// Why the repository library could not be read (it starts empty and
    /// the old file is kept as `library.toml.broken`), or "".
    #[func]
    fn library_warning(&self) -> GString {
        gstr(&self.library_warning)
    }

    /// Every library entry, in the order added: `{path, name (display name
    /// or folder name), folder_name, display_name, pinned, added_at,
    /// last_opened_at (unix seconds, -1 when never opened)}`.
    #[func]
    fn library_rows(&self) -> Array<VarDictionary> {
        runtime_cell::with(|rt| {
            let mut rows = Array::new();
            for entry in rt.library().entries() {
                let folder = entry.path.file_name().map_or_else(
                    || entry.path.display().to_string(),
                    |n| n.to_string_lossy().into_owned(),
                );
                rows.push(&vdict! {
                    "path" => &path_str(&entry.path),
                    "name" => &gstr(&entry.name()),
                    "folder_name" => &gstr(&folder),
                    "display_name" => &gstr(entry.display_name.as_deref().unwrap_or_default()),
                    "pinned" => entry.pinned,
                    "added_at" => entry.added_at,
                    "last_opened_at" => entry.last_opened_at.unwrap_or(-1),
                });
            }
            rows
        })
        .unwrap_or_default()
    }

    /// Paths of the `count` most recently opened library entries.
    #[func]
    fn recent_repos(&self, count: i64) -> PackedStringArray {
        let count = usize::try_from(count).unwrap_or(0);
        runtime_cell::with(|rt| {
            rt.library()
                .recent(count)
                .iter()
                .map(|e| path_str(&e.path))
                .collect()
        })
        .unwrap_or_default()
    }

    /// Adds a repository folder (as `location_result` resolved it). Returns
    /// whether it was new.
    #[func]
    fn library_add(&mut self, path: GString) -> bool {
        runtime_cell::with(|rt| rt.library_add(Path::new(&path.to_string()))).unwrap_or(false)
    }

    /// Removes an entry (never its files); `library_undo_remove` brings it back.
    #[func]
    fn library_remove(&mut self, path: GString) -> bool {
        runtime_cell::with(|rt| rt.library_remove(Path::new(&path.to_string()))).unwrap_or(false)
    }

    #[func]
    fn library_can_undo_remove(&self) -> bool {
        runtime_cell::with(|rt| rt.library().can_undo_remove()).unwrap_or(false)
    }

    /// Puts the last removed entry back; returns its path, or "".
    #[func]
    fn library_undo_remove(&mut self) -> GString {
        runtime_cell::with(|rt| rt.library_undo_remove())
            .flatten()
            .map_or_else(GString::new, |p| path_str(&p))
    }

    /// Sets the display name; an empty `name` (or the folder name) clears it.
    #[func]
    fn library_rename(&mut self, path: GString, name: GString) -> bool {
        runtime_cell::with(|rt| rt.library_rename(Path::new(&path.to_string()), &name.to_string()))
            .unwrap_or(false)
    }

    #[func]
    fn library_pin(&mut self, path: GString, pinned: bool) -> bool {
        runtime_cell::with(|rt| rt.library_pin(Path::new(&path.to_string()), pinned))
            .unwrap_or(false)
    }

    /// Moves entry `old` to the repository folder `new` (Change location);
    /// its per-repo UI state moves too.
    #[func]
    fn library_relocate(&mut self, old: GString, new: GString) -> bool {
        let (old, new) = (
            PathBuf::from(old.to_string()),
            PathBuf::from(new.to_string()),
        );
        let moved = runtime_cell::with(|rt| rt.library_relocate(&old, &new)).unwrap_or(false);
        if moved {
            let _ = self.ui_state.rename(&old, &new);
        }
        moved
    }

    /// Reads the summaries of library entries `paths` in the background
    /// (a few at a time); each one ends with `repo_summary_ready`.
    #[func]
    fn load_repo_summaries(&mut self, paths: PackedStringArray) {
        let paths: Vec<PathBuf> = paths
            .as_slice()
            .iter()
            .map(|p| PathBuf::from(p.to_string()))
            .collect();
        runtime_cell::with(|rt| rt.load_summaries(&paths));
    }

    /// The last summary read for `path`: `{missing, error (as git_error's,
    /// or {}), branch, detached, changes, conflicts, upstream, ahead,
    /// behind}`, or {} before the first read.
    #[func]
    fn repo_summary(&self, path: GString) -> VarDictionary {
        runtime_cell::with(|rt| rt.summary(Path::new(&path.to_string())).map(summary_dict))
            .flatten()
            .unwrap_or_default()
    }

    /// Looks for repositories under `root`, `depth` folders down; returns
    /// the job id (`repository_job_*` signals, then `scan_results`).
    #[func]
    fn scan_repositories(&mut self, root: GString, depth: i64) -> i64 {
        let depth = usize::try_from(depth).unwrap_or(gitbello_core::scan::DEFAULT_DEPTH);
        job_id(runtime_cell::with(|rt| {
            rt.scan(Path::new(&root.to_string()), depth)
        }))
    }

    /// The repositories a finished scan found (once): `{path, worktrees,
    /// bare, known (already in the library)}`.
    #[func]
    fn scan_results(&mut self, job: i64) -> Array<VarDictionary> {
        let Ok(job) = u64::try_from(job) else {
            return Array::new();
        };
        runtime_cell::with(|rt| {
            let mut rows = Array::new();
            for hit in rt.take_scan(job).unwrap_or_default() {
                let worktrees: PackedStringArray =
                    hit.worktrees.iter().map(|p| path_str(p)).collect();
                rows.push(&vdict! {
                    "path" => &path_str(&hit.path),
                    "worktrees" => &worktrees,
                    "bare" => hit.bare,
                    "known" => rt.library().contains(&hit.path),
                });
            }
            rows
        })
        .unwrap_or_default()
    }

    /// Resolves folder `path` to its repository in the background; with
    /// `expected_for` (a library entry) also compares root commits. Returns
    /// the job id (`repository_job_*` signals, then `location_result`).
    #[func]
    fn check_location(&mut self, path: GString, expected_for: GString) -> i64 {
        let expected = PathBuf::from(expected_for.to_string());
        let expected = (!expected.as_os_str().is_empty()).then_some(expected);
        job_id(runtime_cell::with(|rt| {
            rt.check_location(Path::new(&path.to_string()), expected.as_deref())
        }))
    }

    /// A finished location check (once): `{path, root ("" when the folder is
    /// not in a repository), same_root (1 same, 0 different, -1 unknown)}`.
    #[func]
    fn location_result(&mut self, job: i64) -> VarDictionary {
        let Ok(job) = u64::try_from(job) else {
            return VarDictionary::new();
        };
        runtime_cell::with(|rt| rt.take_location(job))
            .flatten()
            .map(|check| {
                vdict! {
                    "path" => &path_str(&check.path),
                    "root" => &check.root.as_deref().map_or_else(GString::new, path_str),
                    "same_root" => check.same_root.map_or(-1, i64::from),
                }
            })
            .unwrap_or_default()
    }

    /// Names of the bundled `.gitignore` templates.
    #[func]
    fn gitignore_templates(&self) -> PackedStringArray {
        GITIGNORE_TEMPLATES
            .iter()
            .map(|(name, _)| gstr(name))
            .collect()
    }

    /// Why `path` cannot be initialized in place, or "".
    #[func]
    fn init_folder_error(&self, path: GString) -> GString {
        gstr(init_folder_error(Path::new(&path.to_string())).unwrap_or_default())
    }

    /// Where Clone suggests putting a repository: the Settings folder, the
    /// last clone's parent folder, or "" (the documents folder).
    #[func]
    fn clone_folder(&self) -> GString {
        runtime_cell::with(|rt| {
            let c = rt.config();
            c.clone_folder
                .as_deref()
                .or(c.last_clone_folder.as_deref())
                .map_or_else(GString::new, path_str)
        })
        .unwrap_or_default()
    }

    /// Tabs to restore on launch.
    #[func]
    fn saved_tabs(&self) -> PackedStringArray {
        runtime_cell::with(|rt| rt.config().open_tabs.iter().map(|p| path_str(p)).collect())
            .unwrap_or_default()
    }

    #[func]
    fn saved_active_tab(&self) -> i64 {
        runtime_cell::with(|rt| rt.config().active_tab.map_or(-1, to_i64)).unwrap_or(-1)
    }

    /// Remembers open tabs in the config file. Returns
    /// an error message, or an empty string.
    #[func]
    fn save_tabs(&mut self, paths: PackedStringArray, active: i64) -> GString {
        runtime_cell::with(|rt| {
            let config = rt.config_mut();
            config.open_tabs = paths
                .as_slice()
                .iter()
                .map(|p| PathBuf::from(p.to_string()))
                .collect();
            config.active_tab = usize::try_from(active).ok();
            rt.save_config()
                .err()
                .map_or_else(GString::new, |e| gstr(&e.to_string()))
        })
        .unwrap_or_default()
    }

    /// `system`, `light` or `dark`.
    #[func]
    fn theme_choice(&self) -> GString {
        runtime_cell::with(|rt| gstr(rt.config().theme.as_str()))
            .unwrap_or_else(|| gstr(ThemeChoice::System.as_str()))
    }

    #[func]
    fn set_theme_choice(&mut self, choice: GString) -> bool {
        let Some(theme) = ThemeChoice::parse(&choice.to_string()) else {
            return false;
        };
        runtime_cell::with(|rt| {
            rt.config_mut().theme = theme;
            rt.save_config().is_ok()
        })
        .unwrap_or(false)
    }

    /// UI state saved for repository `repo` (any of its paths), such as
    /// `history_width`: name to integer.
    #[func]
    fn repo_ui_state(&self, repo: GString) -> VarDictionary {
        let mut out = VarDictionary::new();
        for (name, value) in self.ui_state.get(Path::new(&repo.to_string())) {
            out.set(&gstr(&name), value);
        }
        out
    }

    /// Saves one UI state value for `repo`. Returns an error message, or an
    /// empty string.
    #[func]
    fn set_repo_ui_state(&mut self, repo: GString, name: GString, value: i64) -> GString {
        self.ui_state
            .set(Path::new(&repo.to_string()), &name.to_string(), value)
            .err()
            .map_or_else(GString::new, |e| gstr(&e.to_string()))
    }

    /// The rename of `old` to `new` as `[prefix, old, new, suffix]`, to
    /// show as `prefix{old → new}suffix` (see `diff::rename_parts`).
    #[func]
    fn rename_parts(&self, old: GString, new: GString) -> PackedStringArray {
        let parts = rename_parts(&old.to_string(), &new.to_string());
        [parts.prefix, parts.old, parts.new, parts.suffix]
            .iter()
            .map(|p| gstr(p))
            .collect()
    }

    /// The saved mode of `viewer` (`text` or `image`), such as `split`.
    #[func]
    fn diff_mode(&self, viewer: GString) -> GString {
        let viewer = Viewer::parse(&viewer.to_string()).unwrap_or_default();
        let mode = runtime_cell::with(|rt| match viewer {
            Viewer::Text => rt.config().diff_text_mode,
            Viewer::Image => rt.config().diff_image_mode,
            Viewer::None => viewer.default_mode(),
        })
        .unwrap_or(viewer.default_mode());
        GString::from(mode.id())
    }

    /// Saves `mode` for `viewer`; false when `mode` is not one of its modes
    /// or the config could not be written.
    #[func]
    fn set_diff_mode(&mut self, viewer: GString, mode: GString) -> bool {
        let viewer = Viewer::parse(&viewer.to_string()).unwrap_or_default();
        let Some(mode) =
            DiffMode::parse(&mode.to_string()).filter(|m| viewer.all_modes().contains(m))
        else {
            return false;
        };
        runtime_cell::with(|rt| {
            match viewer {
                Viewer::Text => rt.config_mut().diff_text_mode = mode,
                Viewer::Image => rt.config_mut().diff_image_mode = mode,
                Viewer::None => return false,
            }
            rt.save_config().is_ok()
        })
        .unwrap_or(false)
    }

    /// Whether diffs show the minimap (saved in the config); without it
    /// only the strip of change marks is shown.
    #[func]
    fn diff_minimap(&self) -> bool {
        runtime_cell::with(|rt| rt.config().diff_minimap).unwrap_or(true)
    }

    #[func]
    fn set_diff_minimap(&mut self, value: bool) -> bool {
        runtime_cell::with(|rt| {
            rt.config_mut().diff_minimap = value;
            rt.save_config().is_ok()
        })
        .unwrap_or(false)
    }

    /// `ff-only`, `merge` or `rebase`: what a plain pull does.
    #[func]
    fn pull_mode(&self) -> GString {
        runtime_cell::with(|rt| gstr(rt.config().pull_mode.as_str())).unwrap_or_default()
    }

    /// Opens the configured (or the platform's) terminal in `path`.
    /// Returns an error message, or an empty string.
    #[func]
    fn open_terminal(&self, path: GString) -> GString {
        let template = runtime_cell::with(|rt| rt.config().terminal_command.clone()).flatten();
        let dir = PathBuf::from(path.to_string());
        launch::launch_terminal(template.as_deref(), &dir)
            .err()
            .map_or_else(GString::new, |e| gstr(&e.to_string()))
    }

    /// Why `name` cannot be a branch or tag name, or an empty string.
    #[func]
    fn ref_name_error(&self, name: GString) -> GString {
        gstr(ref_name_error(&name.to_string()).unwrap_or_default())
    }

    /// Why `prefix` cannot start branch names, or "" (see the
    /// `branch_prefix` setting).
    #[func]
    fn branch_prefix_error(&self, prefix: GString) -> GString {
        gstr(branch_prefix_error(&prefix.to_string()).unwrap_or_default())
    }

    /// Why a repository cannot be created or cloned at `path` (it must be
    /// missing or an empty folder), or an empty string.
    #[func]
    fn new_repository_path_error(&self, path: GString) -> GString {
        gstr(new_worktree_path_error(Path::new(&path.to_string())).unwrap_or_default())
    }

    /// Why a new worktree cannot go at `path` (it must be missing or an empty
    /// folder), or an empty string.
    #[func]
    fn new_worktree_path_error(&self, path: GString) -> GString {
        gstr(new_worktree_path_error(Path::new(&path.to_string())).unwrap_or_default())
    }

    /// The settings the Settings dialog edits: `{pull_mode,
    /// auto_fetch_minutes, terminal_command,
    /// worktree_template, branch_prefix, language, accent, added_color,
    /// removed_color, clone_folder, diff_minimap, ignore_hint}`; an empty terminal command
    /// means the platform's, an empty colour the theme's (else `#rrggbb`), an
    /// empty clone folder the last one used.
    #[func]
    fn settings(&self) -> VarDictionary {
        runtime_cell::with(|rt| {
            let c = rt.config();
            vdict! {
                "pull_mode" => c.pull_mode.as_str(),
                "auto_fetch_minutes" => i64::from(c.auto_fetch_minutes),
                "terminal_command" => &gstr(c.terminal_command.as_deref().unwrap_or_default()),
                "worktree_template" => &gstr(&c.worktree_template),
                "branch_prefix" => &gstr(&c.branch_prefix),
                "language" => c.language.as_str(),
                "accent" => &gstr(c.accent.as_deref().unwrap_or_default()),
                "added_color" => &gstr(c.added_color.as_deref().unwrap_or_default()),
                "removed_color" => &gstr(c.removed_color.as_deref().unwrap_or_default()),
                "clone_folder" => &c.clone_folder.as_deref().map_or_else(GString::new, path_str),
                "diff_minimap" => c.diff_minimap,
                "ignore_hint" => c.ignore_hint,
            }
        })
        .unwrap_or_default()
    }

    /// Validates and saves `settings` (keys as in `settings`; missing keys
    /// stay). Returns an error message, or an empty string.
    #[func]
    fn set_settings(&mut self, settings: VarDictionary) -> GString {
        let text = |key: &str| settings.get(key).map(|v| v.to_string());
        let pull_mode = match text("pull_mode") {
            None => None,
            Some(mode) => match PullMode::parse(&mode) {
                Some(mode) => Some(mode),
                None => return gstr("Pull mode must be ff-only, merge or rebase."),
            },
        };
        let minutes = match settings.get("auto_fetch_minutes") {
            None => None,
            Some(value) => match value
                .try_to::<i64>()
                .ok()
                .and_then(|m| u32::try_from(m).ok())
            {
                Some(minutes) => Some(minutes),
                None => return gstr("The auto-fetch interval must be a whole number of minutes."),
            },
        };
        let template = text("worktree_template");
        if template.as_deref().is_some_and(|t| t.trim().is_empty()) {
            return gstr("Enter a worktree folder template.");
        }
        let prefix = text("branch_prefix").map(|p| p.trim().to_owned());
        if let Some(error) = prefix.as_deref().and_then(branch_prefix_error) {
            return gstr(error);
        }
        let language = match text("language") {
            None => None,
            Some(value) => match LanguageChoice::parse(&value) {
                Some(language) => Some(language),
                None => return gstr("Language must be system, en or it."),
            },
        };
        // `None` leaves a colour, `Some(None)` clears it.
        let color = |key: &str| -> Result<Option<Option<String>>, ()> {
            match text(key) {
                None => Ok(None),
                Some(c) if c.trim().is_empty() => Ok(Some(None)),
                Some(c) => parse_accent(&c).map(|c| Some(Some(c))).ok_or(()),
            }
        };
        let Ok(accent) = color("accent") else {
            return gstr("The accent colour must look like #4c9cff.");
        };
        let Ok(added_color) = color("added_color") else {
            return gstr("The added colour must look like #4c9cff.");
        };
        let Ok(removed_color) = color("removed_color") else {
            return gstr("The removed colour must look like #4c9cff.");
        };
        let minimap = match settings.get("diff_minimap") {
            None => None,
            Some(value) => match value.try_to::<bool>() {
                Ok(shown) => Some(shown),
                Err(_) => return gstr("Show minimap must be true or false."),
            },
        };
        let ignore_hint = match settings.get("ignore_hint") {
            None => None,
            Some(value) => match value.try_to::<bool>() {
                Ok(shown) => Some(shown),
                Err(_) => return gstr("Suggest folders to ignore must be true or false."),
            },
        };
        runtime_cell::with(|rt| {
            let config = rt.config_mut();
            if let Some(shown) = minimap {
                config.diff_minimap = shown;
            }
            if let Some(shown) = ignore_hint {
                config.ignore_hint = shown;
            }
            if let Some(mode) = pull_mode {
                config.pull_mode = mode;
            }
            if let Some(minutes) = minutes {
                config.auto_fetch_minutes = minutes;
            }
            if let Some(terminal) = text("terminal_command") {
                let terminal = terminal.trim();
                config.terminal_command = (!terminal.is_empty()).then(|| terminal.to_owned());
            }
            if let Some(template) = template {
                config.worktree_template = template.trim().to_owned();
            }
            if let Some(prefix) = prefix {
                config.branch_prefix = prefix;
            }
            if let Some(language) = language {
                config.language = language;
            }
            if let Some(accent) = accent {
                config.accent = accent;
            }
            if let Some(added) = added_color {
                config.added_color = added;
            }
            if let Some(removed) = removed_color {
                config.removed_color = removed;
            }
            if let Some(folder) = text("clone_folder") {
                let folder = folder.trim();
                config.clone_folder = (!folder.is_empty()).then(|| PathBuf::from(folder));
            }
            rt.save_config()
                .err()
                .map_or_else(GString::new, |e| gstr(&e.to_string()))
        })
        .unwrap_or_else(|| gstr(&self.start_error))
    }

    /// User shortcut overrides: action id to shortcut text.
    #[func]
    fn keybindings(&self) -> VarDictionary {
        runtime_cell::with(|rt| {
            let mut out = VarDictionary::new();
            for (action, shortcut) in &rt.config().keybindings {
                out.set(&gstr(action), &gstr(shortcut));
            }
            out
        })
        .unwrap_or_default()
    }

    /// Sets (or with an empty `shortcut`, removes) an override and saves.
    #[func]
    fn set_keybinding(&mut self, action: GString, shortcut: GString) -> bool {
        runtime_cell::with(|rt| {
            let bindings = &mut rt.config_mut().keybindings;
            let (action, shortcut) = (action.to_string(), shortcut.to_string());
            if shortcut.is_empty() {
                bindings.remove(&action);
            } else {
                bindings.insert(action, shortcut);
            }
            rt.save_config().is_ok()
        })
        .unwrap_or(false)
    }

    /// Git commands with `seq > after`: `{seq, repo, command, started (unix
    /// seconds), duration_ms, exit_code, outcome ("ok", "cancelled" or the
    /// error kind id)}`.
    #[func]
    fn command_log(&self, after: i64) -> Array<VarDictionary> {
        let after = u64::try_from(after).unwrap_or(0);
        runtime_cell::with(|rt| {
            let mut out = Array::new();
            for record in rt.command_log().records_since(after) {
                let outcome = match record.outcome {
                    CommandOutcome::Succeeded => "ok",
                    CommandOutcome::Cancelled => "cancelled",
                    CommandOutcome::Failed(kind) => convert::error_kind_id(kind),
                };
                let started = record
                    .started
                    .duration_since(UNIX_EPOCH)
                    .map_or(0.0, |d| d.as_secs_f64());
                out.push(&vdict! {
                    "seq" => i64::try_from(record.seq).unwrap_or(i64::MAX),
                    "repo" => &path_str(&record.repo),
                    "command" => &gstr(&record.command),
                    "started" => started,
                    "duration_ms" => record.duration.as_secs_f64() * 1e3,
                    "exit_code" => record.exit_code.map_or(-1, i64::from),
                    "outcome" => outcome,
                });
            }
            out
        })
        .unwrap_or_default()
    }

    /// Indices of `candidates` that fuzzy-match `query`, best first.
    #[func]
    fn fuzzy_rank(&self, query: GString, candidates: PackedStringArray) -> PackedInt32Array {
        let items: Vec<String> = candidates
            .as_slice()
            .iter()
            .map(GString::to_string)
            .collect();
        gitbello_core::fuzzy::rank(&query.to_string(), &items)
            .into_iter()
            .map(|i| i32::try_from(i).unwrap_or(i32::MAX))
            .collect()
    }
}

/// A job id for GDScript; -1 when the runtime is not running.
fn job_id(job: Option<u64>) -> i64 {
    job.map_or(-1, |job| i64::try_from(job).unwrap_or(i64::MAX))
}

fn summary_dict(summary: &RepoSummary) -> VarDictionary {
    vdict! {
        "missing" => summary.missing,
        "error" => &summary.error.as_ref().map(convert::error_dict).unwrap_or_default(),
        "branch" => &gstr(summary.branch.as_deref().unwrap_or_default()),
        "detached" => summary.detached,
        "changes" => to_i64(summary.changes),
        "conflicts" => summary.conflicts,
        "upstream" => summary.upstream,
        "ahead" => i64::from(summary.ahead),
        "behind" => i64::from(summary.behind),
    }
}
