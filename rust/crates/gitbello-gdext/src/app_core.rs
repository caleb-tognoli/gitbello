use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use gitbello_core::changes::split_message;
use gitbello_core::config::ThemeChoice;
use gitbello_core::git::CommandOutcome;
use gitbello_core::jobs::RefreshKind;
use gitbello_core::paths;
use gitbello_core::runtime::{JobState, Runtime, RuntimeEvent};
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
}

#[godot_api]
impl INode for AppCore {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            sessions: HashMap::new(),
            start_error: String::new(),
            config_warning: String::new(),
        }
    }

    fn ready(&mut self) {
        // GITBELLO_CONFIG points tests and dev runs at a scratch config file.
        let config_path = std::env::var_os("GITBELLO_CONFIG")
            .map(PathBuf::from)
            .or_else(paths::config_file);
        let (config, warning) = Runtime::load_config(config_path.as_deref());
        if let Some(warning) = warning {
            self.config_warning = warning.to_string();
        }
        match Runtime::new(config, config_path) {
            Ok(runtime) => runtime_cell::install(runtime),
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
        // `base_mut()` so those calls can bind this object again.
        let mut guard = self.base_mut();
        for event in events {
            dispatch(&mut guard, &sessions, event);
        }
        drop(guard);
        for (_, mut session) in sessions {
            if session.is_instance_valid() {
                session.bind_mut().pump_graph();
            }
        }
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
        RuntimeEvent::GraphReset { repo } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.bind_mut().reset_graph();
            }
        }
        RuntimeEvent::DiffChanged { repo } => {
            if let Some(mut session) = find(sessions, &repo) {
                session.emit_signal("diff_changed", &[]);
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
            let Some(mut session) = find(sessions, &repo) else {
                return;
            };
            let job = i64::try_from(job).unwrap_or(i64::MAX).to_variant();
            let label = gstr(&label).to_variant();
            match state {
                JobState::Started => {}
                JobState::Progress(p) => {
                    let percent = p.percent.map_or(-1, i64::from);
                    session.emit_signal(
                        "job_progress",
                        &[job, label, percent.to_variant(), gstr(&p.text).to_variant()],
                    );
                }
                JobState::Finished(error) => {
                    let ok = error.is_none();
                    let error = error.as_ref().map(convert::error_dict).unwrap_or_default();
                    session.emit_signal(
                        "job_finished",
                        &[job, label, ok.to_variant(), error.to_variant()],
                    );
                    if !ok {
                        core.emit_signal(
                            "git_error",
                            &[path_str(&repo).to_variant(), error.to_variant()],
                        );
                    }
                }
                JobState::Cancelled => {}
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

    /// New entries are in the git command log (`command_log`).
    #[signal]
    fn commands_logged();

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

    /// Recently opened repositories, most recent first.
    #[func]
    fn recent_repos(&self) -> PackedStringArray {
        runtime_cell::with(|rt| {
            rt.config()
                .known_repos
                .iter()
                .map(|p| path_str(p))
                .collect()
        })
        .unwrap_or_default()
    }

    /// Removes a repository from the recent list (for example, if it is gone).
    #[func]
    fn forget_repo(&mut self, path: GString) {
        let path = PathBuf::from(path.to_string());
        runtime_cell::with(|rt| {
            rt.config_mut().known_repos.retain(|p| *p != path);
            let _ = rt.save_config();
        });
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

    /// Remembers open tabs (and the recent list) in the config file. Returns
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
