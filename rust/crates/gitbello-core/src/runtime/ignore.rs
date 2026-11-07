//! Ignore rules (M7.7, `docs/IGNORE_RULES.md`): previewing a rule, writing
//! it (and untracking what it matches), the rules viewer's model and its
//! edits, Stop ignoring, and undo.

use super::*;
use crate::ignore::{
    append_lines, check, match_form, missing_lines, remove_lines, template_missing, unignore,
    HiddenPath, IgnoreLine, IgnorePreview, IgnoreRule, IgnoreRules, IgnoreSource, IgnoreTarget,
    IgnoreUndo, LineKind, SourceKind, Unignore, Untrack, PREVIEW_SAMPLE,
};
use crate::new_repo::gitignore_template;

pub const IGNORE_PREVIEW_JOB_LABEL: &str = "preview ignore rule";
pub const IGNORE_JOB_LABEL: &str = "ignore";
pub const UNDO_IGNORE_JOB_LABEL: &str = "undo ignore";
pub const IGNORE_RULES_JOB_LABEL: &str = "load ignore rules";
pub const REMOVE_IGNORE_RULE_JOB_LABEL: &str = "remove ignore rule";
pub const UNTRACK_IGNORED_JOB_LABEL: &str = "stop tracking ignored files";
pub const STOP_IGNORING_JOB_LABEL: &str = "stop ignoring";

/// The jobs that write an ignore file or untrack files.
pub const IGNORE_WRITE_LABELS: [&str; 5] = [
    IGNORE_JOB_LABEL,
    UNDO_IGNORE_JOB_LABEL,
    REMOVE_IGNORE_RULE_JOB_LABEL,
    UNTRACK_IGNORED_JOB_LABEL,
    STOP_IGNORING_JOB_LABEL,
];

/// Rules remembered for undo, per repository.
pub const MAX_IGNORE_UNDO: usize = 20;

/// A rule's preview, the rules viewer's model and the jobs working them out,
/// per repository.
#[derive(Default)]
pub(super) struct IgnoreState {
    pub(super) preview: Option<IgnorePreview>,
    pub(super) preview_job: Option<JobId>,
    /// Rules written, newest last, for undo.
    pub(super) undo: Vec<IgnoreUndo>,
    /// Paths to include in the commit when the next status arrives.
    pub(super) picks: Vec<PathBuf>,
    pub(super) rules: Option<IgnoreRules>,
    pub(super) rules_job: Option<JobId>,
    /// The rules viewer is open: reload the rules with every status.
    pub(super) watching: bool,
    /// Write jobs on the global excludes file, which every repository reads.
    pub(super) global_jobs: Vec<JobId>,
}

impl IgnoreState {
    /// Takes `job` out of the global jobs; whether it was one.
    pub(super) fn take_global(&mut self, job: JobId) -> bool {
        let before = self.global_jobs.len();
        self.global_jobs.retain(|j| *j != job);
        before != self.global_jobs.len()
    }
}

impl RepoState {
    /// Whether the rules are kept up to date (the viewer, or "Show ignored
    /// files" in Changes).
    pub(super) fn wants_ignore_rules(&self) -> bool {
        self.ignore.watching || self.change_filter.ignored
    }

    /// The model of [`Runtime::load_ignore_rules`], once it arrived.
    pub fn ignore_rules(&self) -> Option<&IgnoreRules> {
        self.ignore.rules.as_ref()
    }

    /// Whether `path` is an ignored folder listed by "Show ignored files".
    pub fn ignored_folder(&self, path: &Path) -> bool {
        self.listed.is_some()
            && self.ignore.rules.as_ref().is_some_and(|rules| {
                rules
                    .ignored
                    .iter()
                    .any(|(e, _)| e.is_dir && e.path == path)
            })
    }

    /// The file and line that ignore `path` (a row of "Show ignored files").
    pub fn ignored_by(&self, path: &Path) -> Option<(&IgnoreSource, &IgnoreLine)> {
        let rules = self.ignore.rules.as_ref()?;
        let (source, line) = rules.ignored_by(path)?;
        Some((rules.source(source)?, rules.line(source, line)?))
    }
}

impl Runtime {
    /// Folders (repo-relative, `/`-separated) with a `.gitignore` that holds
    /// every one of `paths`, the root first; the root is listed even when it
    /// has none yet.
    pub fn ignore_files(&self, key: &Path, paths: &[PathBuf]) -> Vec<PathBuf> {
        let Some(toplevel) = self.toplevel_of(key) else {
            return Vec::new();
        };
        let mut out = vec![PathBuf::new()];
        let mut common: Option<Vec<String>> = None;
        for path in paths {
            let parts: Vec<String> = path
                .to_string_lossy()
                .replace('\\', "/")
                .split('/')
                .map(str::to_owned)
                .collect();
            let folder = &parts[..parts.len().saturating_sub(1)];
            common = Some(match common {
                None => folder.to_vec(),
                Some(c) => c
                    .iter()
                    .zip(folder)
                    .take_while(|(a, b)| a == b)
                    .map(|(a, _)| a.clone())
                    .collect(),
            });
        }
        let mut dir = PathBuf::new();
        for part in common.unwrap_or_default() {
            dir.push(part);
            if toplevel.join(&dir).join(".gitignore").is_file() {
                out.push(PathBuf::from(dir.to_string_lossy().replace('\\', "/")));
            }
        }
        out
    }

    /// Works out what `rule` would hide and which tracked files it matches,
    /// replacing (and cancelling) the previous preview. It arrives as
    /// [`RuntimeEvent::IgnorePreviewLoaded`].
    pub fn load_ignore_preview(&mut self, key: &Path, rule: IgnoreRule) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get_mut(key)?;
        let common = state.paths.as_ref()?.common_dir.clone();
        let untracked = untracked_paths(state.status.as_ref()?);
        if let Some(old) = state.ignore.preview_job.take() {
            self.scheduler.cancel(old);
        }
        state.ignore.preview = None;
        let job = self
            .scheduler
            .submit(JobSpec::read(key, IGNORE_PREVIEW_JOB_LABEL, move |ctx| {
                let preview = preview(
                    ctx.backend(),
                    &toplevel,
                    &common,
                    rule,
                    &untracked,
                    ctx.cancel_token(),
                )?;
                Ok(JobOutput::IgnorePreview(Box::new(preview)))
            }));
        state.ignore.preview_job = Some(job);
        Some(job)
    }

    /// The preview of the last [`Self::load_ignore_preview`], once it arrived.
    pub fn ignore_preview(&self, key: &Path) -> Option<&IgnorePreview> {
        self.repos.get(key)?.ignore.preview.as_ref()
    }

    /// Adds `rule` to its file, then deals with the tracked files it matches
    /// as `untrack` says. The `.gitignore` and the untracked files are
    /// included in the commit. Label [`IGNORE_JOB_LABEL`].
    pub fn add_ignore_rule(
        &mut self,
        key: &Path,
        rule: IgnoreRule,
        untrack: Untrack,
    ) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let common = self.repos.get(key)?.paths.as_ref()?.common_dir.clone();
        let global = rule.target == IgnoreTarget::Global;
        let job = self.scheduler.submit(JobSpec::write(
            key,
            IGNORE_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                let file = target_file(
                    ctx.backend(),
                    &toplevel,
                    &common,
                    &rule.target,
                    ctx.cancel_token(),
                )?;
                let undo = add_rule(
                    ctx.backend(),
                    &toplevel,
                    &file,
                    &rule,
                    untrack,
                    ctx.cancel_token(),
                )?;
                Ok(JobOutput::Ignored(undo.map(Box::new)))
            },
        ));
        self.note_ignore_job(key, job, global);
        Some(job)
    }

    pub fn can_undo_ignore(&self, key: &Path) -> bool {
        self.repos
            .get(key)
            .is_some_and(|s| !s.ignore.undo.is_empty())
    }

    /// Takes back the most recent ignore edit: the lines a rule added or the
    /// line removed, and the files it stopped tracking. Label
    /// [`UNDO_IGNORE_JOB_LABEL`].
    pub fn undo_ignore(&mut self, key: &Path) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let undo = self.repos.get_mut(key)?.ignore.undo.pop()?;
        let global = undo.everywhere;
        let job = self.scheduler.submit(JobSpec::write(
            key,
            UNDO_IGNORE_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                undo_rule(ctx.backend(), &toplevel, &undo, ctx.cancel_token())?;
                Ok(JobOutput::Done)
            },
        ));
        self.note_ignore_job(key, job, global);
        Some(job)
    }

    /// Works out every ignore file of the worktree, its lines and what each
    /// decides, replacing (and cancelling) the previous load. It arrives as
    /// [`RuntimeEvent::IgnoreRulesLoaded`].
    pub fn load_ignore_rules(&mut self, key: &Path) -> Option<JobId> {
        let state = self.repos.get_mut(key)?;
        submit_ignore_rules(&self.scheduler, state)
    }

    /// Keeps the rules up to date while the viewer is open (each status
    /// reloads them), and loads them when `open`.
    pub fn watch_ignore_rules(&mut self, key: &Path, open: bool) {
        let Some(state) = self.repos.get_mut(key) else {
            return;
        };
        state.ignore.watching = open;
        if open {
            submit_ignore_rules(&self.scheduler, state);
        } else {
            drop_ignore_rules(&self.scheduler, state);
        }
    }

    /// The rules model, once [`Self::load_ignore_rules`] delivered it.
    pub fn ignore_rules(&self, key: &Path) -> Option<&IgnoreRules> {
        self.repos.get(key)?.ignore_rules()
    }

    /// Removes line `line` (an index) of source `source`, which must still
    /// read as the model shows it. Label [`REMOVE_IGNORE_RULE_JOB_LABEL`].
    pub fn remove_ignore_rule(&mut self, key: &Path, source: usize, line: usize) -> Option<JobId> {
        let state = self.repos.get(key)?;
        let rules = state.ignore.rules.as_ref()?;
        let src = rules.source(source)?;
        let at = rules.line(source, line)?;
        if !matches!(at.kind, LineKind::Rule | LineKind::Negation) {
            return None;
        }
        let (file, number, text) = (src.file.clone(), at.number, at.text.clone());
        let global = src.kind == SourceKind::Global;
        let job = self.scheduler.submit(JobSpec::write(
            key,
            REMOVE_IGNORE_RULE_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |_| {
                let undo = remove_line(&file, number, &text, global)?;
                Ok(JobOutput::Ignored(Some(Box::new(undo))))
            },
        ));
        self.note_ignore_job(key, job, global);
        Some(job)
    }

    /// Stops tracking the tracked files line `line` of source `source`
    /// matches (`git rm --cached`; they stay on disk and are included in the
    /// commit). Label [`UNTRACK_IGNORED_JOB_LABEL`].
    pub fn untrack_ignored(&mut self, key: &Path, source: usize, line: usize) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let rules = self.repos.get(key)?.ignore.rules.as_ref()?;
        let paths = rules.line(source, line)?.tracked.clone();
        let file = rules.source(source)?.file.clone();
        if paths.is_empty() {
            return None;
        }
        let job = self.scheduler.submit(JobSpec::write(
            key,
            UNTRACK_IGNORED_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                let backend = ctx.backend();
                let entries = backend.index_entries(&toplevel, &paths, ctx.cancel_token())?;
                backend.untrack(&toplevel, &paths, ctx.cancel_token())?;
                Ok(JobOutput::Ignored(Some(Box::new(IgnoreUndo {
                    file,
                    before: None,
                    after: Vec::new(),
                    wrote: false,
                    lines: Vec::new(),
                    index_entries: entries,
                    picks: paths,
                    everywhere: false,
                }))))
            },
        ));
        Some(job)
    }

    /// Makes git stop ignoring `path` (a row of "Show ignored files"):
    /// removes the line when it names exactly that path, otherwise adds a
    /// `!` line (see [`crate::ignore::unignore`]). Label
    /// [`STOP_IGNORING_JOB_LABEL`].
    pub fn stop_ignoring(&mut self, key: &Path, path: &Path) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get(key)?;
        let common = state.paths.as_ref()?.common_dir.clone();
        let rules = state.ignore.rules.as_ref()?;
        let (source, line) = rules.ignored_by(path)?;
        let (src, at) = (rules.source(source)?, rules.line(source, line)?);
        let entry = rules
            .ignored
            .iter()
            .map(|(e, _)| e)
            .find(|e| e.path == path)?
            .clone();
        let plan = unignore(src, at, &entry);
        let (file, number, text) = (src.file.clone(), at.number, at.text.clone());
        let global = src.kind == SourceKind::Global && plan == Unignore::RemoveLine;
        let job = self.scheduler.submit(JobSpec::write(
            key,
            STOP_IGNORING_JOB_LABEL,
            RefreshSet::EMPTY.with(RefreshKind::Status),
            move |ctx| {
                let undo = match plan {
                    Unignore::RemoveLine => remove_line(&file, number, &text, false)?,
                    Unignore::Negate { target, line } => {
                        let file = target_file(
                            ctx.backend(),
                            &toplevel,
                            &common,
                            &target,
                            ctx.cancel_token(),
                        )?;
                        let rule = IgnoreRule {
                            pattern: line,
                            target,
                        };
                        let undo = add_rule(
                            ctx.backend(),
                            &toplevel,
                            &file,
                            &rule,
                            Untrack::Keep,
                            ctx.cancel_token(),
                        )?;
                        undo.ok_or_else(|| already_negated(&entry))?
                    }
                };
                Ok(JobOutput::Ignored(Some(Box::new(undo))))
            },
        ));
        self.note_ignore_job(key, job, global);
        Some(job)
    }

    /// The rule lines of the bundled `.gitignore` template `name` that the
    /// root `.gitignore` lacks, one per line (empty when it has them all);
    /// `None` before the rules are loaded or for an unknown template.
    pub fn ignore_template_lines(&self, key: &Path, name: &str) -> Option<String> {
        let template = gitignore_template(name)?;
        let root = self.ignore_rules(key)?.root()?;
        let contents: Vec<&str> = root.lines.iter().map(|l| l.text.as_str()).collect();
        Some(template_missing(template, contents.join("\n").as_bytes()))
    }

    /// A folder of untracked files worth ignoring
    /// ([`crate::ignore::folder_hint`]), and how many files it holds.
    pub fn ignore_hint(&self, key: &Path) -> Option<(PathBuf, usize)> {
        let state = self.repos.get(key)?;
        if state.is_amending() {
            return None;
        }
        crate::ignore::folder_hint(state.status.as_ref()?)
    }

    fn note_ignore_job(&mut self, key: &Path, job: JobId, global: bool) {
        if let Some(state) = self.repos.get_mut(key).filter(|_| global) {
            state.ignore.global_jobs.push(job);
        }
    }

    /// Handles the ignore jobs' results. Returns whether `label` was one
    /// that needs nothing else.
    pub(super) fn apply_ignore_event(
        state: &mut RepoState,
        job: JobId,
        label: &str,
        kind: &EventKind,
        repo: &Path,
        out: &mut Vec<RuntimeEvent>,
    ) -> bool {
        if label == IGNORE_PREVIEW_JOB_LABEL {
            if let EventKind::Finished(Ok(JobOutput::IgnorePreview(preview))) = kind {
                if state.ignore.preview_job == Some(job) {
                    state.ignore.preview = Some(preview.as_ref().clone());
                    out.push(RuntimeEvent::IgnorePreviewLoaded {
                        repo: repo.to_owned(),
                        job,
                    });
                }
                return true;
            }
            return false;
        }
        if label == IGNORE_RULES_JOB_LABEL {
            if state.ignore.rules_job != Some(job) {
                return matches!(kind, EventKind::Finished(Ok(_)) | EventKind::Cancelled);
            }
            match kind {
                EventKind::Finished(Ok(JobOutput::IgnoreRules(rules))) => {
                    state.ignore.rules_job = None;
                    state.ignore.rules = Some(rules.as_ref().clone());
                    state.rebuild_changes();
                    out.push(RuntimeEvent::IgnoreRulesLoaded {
                        repo: repo.to_owned(),
                        job,
                    });
                    return true;
                }
                EventKind::Finished(Err(_)) => state.ignore.rules_job = None,
                EventKind::Cancelled => {
                    state.ignore.rules_job = None;
                    return true;
                }
                _ => {}
            }
            return false;
        }
        if let EventKind::Finished(Ok(JobOutput::Ignored(Some(undo)))) = kind {
            state.ignore.picks = undo.picks.clone();
            state.ignore.undo.push(undo.as_ref().clone());
            let excess = state.ignore.undo.len().saturating_sub(MAX_IGNORE_UNDO);
            state.ignore.undo.drain(..excess);
        }
        false
    }

    /// After a filter change: loads the rules "Show ignored files" needs, or
    /// lets them go.
    pub(super) fn sync_ignore_rules(&mut self, key: &Path) {
        let Some(state) = self.repos.get_mut(key) else {
            return;
        };
        if !state.wants_ignore_rules() {
            drop_ignore_rules(&self.scheduler, state);
        } else if state.ignore.rules.is_none() && state.ignore.rules_job.is_none() {
            submit_ignore_rules(&self.scheduler, state);
        }
    }
}

/// Reloads the rules after a status change, when something shows them.
pub(super) fn reload_ignore_rules(scheduler: &JobScheduler, state: &mut RepoState) {
    if state.wants_ignore_rules() {
        submit_ignore_rules(scheduler, state);
    }
}

fn submit_ignore_rules(scheduler: &JobScheduler, state: &mut RepoState) -> Option<JobId> {
    let toplevel = state.toplevel.clone().filter(|_| state.is_ready())?;
    let common = state.paths.as_ref()?.common_dir.clone();
    let untracked = state
        .status
        .as_ref()
        .map(untracked_paths)
        .unwrap_or_default();
    if let Some(old) = state.ignore.rules_job.take() {
        scheduler.cancel(old);
    }
    let job = scheduler.submit(JobSpec::read(
        &state.key,
        IGNORE_RULES_JOB_LABEL,
        move |ctx| {
            let rules = load_rules(
                ctx.backend(),
                &toplevel,
                &common,
                &untracked,
                ctx.cancel_token(),
            )?;
            Ok(JobOutput::IgnoreRules(Box::new(rules)))
        },
    ));
    state.ignore.rules_job = Some(job);
    Some(job)
}

fn drop_ignore_rules(scheduler: &JobScheduler, state: &mut RepoState) {
    if let Some(old) = state.ignore.rules_job.take() {
        scheduler.cancel(old);
    }
    if state.ignore.rules.take().is_some() {
        state.rebuild_changes();
    }
}

/// Includes the paths a rule asked for, now that status lists them.
pub(super) fn apply_ignore_picks(state: &mut RepoState) {
    if state.ignore.picks.is_empty() || state.commit_mode().locks_picks() {
        return;
    }
    let picks = std::mem::take(&mut state.ignore.picks);
    state.selection.pick_files(&picks, true);
}

fn untracked_paths(status: &RepoStatus) -> Vec<PathBuf> {
    status
        .changes
        .iter()
        .filter(|c| c.state == FileState::Untracked)
        .map(|c| c.path.clone())
        .collect()
}

/// The file `target` writes; the global one is looked up with git.
fn target_file(
    backend: &dyn GitBackend,
    toplevel: &Path,
    common: &Path,
    target: &IgnoreTarget,
    cancel: &CancelToken,
) -> Result<PathBuf, GitError> {
    if let Some(file) = target.file(toplevel, common, None) {
        return Ok(file);
    }
    backend
        .global_excludes_file(toplevel, cancel)?
        .ok_or_else(|| {
            GitError::new(
                "config core.excludesFile",
                GitErrorKind::Other,
                "no global excludes file: set core.excludesFile or HOME",
            )
        })
}

fn load_rules(
    backend: &dyn GitBackend,
    toplevel: &Path,
    common: &Path,
    untracked: &[PathBuf],
    cancel: &CancelToken,
) -> Result<IgnoreRules, GitError> {
    let mut sources = vec![IgnoreSource::new(
        SourceKind::Root,
        PathBuf::new(),
        toplevel.join(".gitignore"),
        ".gitignore".into(),
    )];
    for file in backend.ignore_files(toplevel, cancel)? {
        let name = file.to_string_lossy().replace('\\', "/");
        let Some(dir) = name.strip_suffix("/.gitignore") else {
            continue;
        };
        sources.push(IgnoreSource::new(
            SourceKind::Nested,
            PathBuf::from(dir),
            toplevel.join(&file),
            name.clone(),
        ));
    }
    sources.push(IgnoreSource::new(
        SourceKind::Local,
        PathBuf::new(),
        common.join("info").join("exclude"),
        "info/exclude".into(),
    ));
    if let Some(global) = backend.global_excludes_file(toplevel, cancel)? {
        let name = global.to_string_lossy().replace('\\', "/");
        sources.push(IgnoreSource::new(
            SourceKind::Global,
            PathBuf::new(),
            global,
            name,
        ));
    }
    let mut with_contents = Vec::with_capacity(sources.len());
    for source in sources {
        let contents = read_optional(&source.file)?;
        with_contents.push((source, contents));
    }
    let negations = with_contents.iter().any(|(_, contents)| {
        contents.as_deref().is_some_and(|c| {
            String::from_utf8_lossy(c)
                .lines()
                .any(|l| l.starts_with('!'))
        })
    });
    let ignored = backend.ignored_entries(toplevel, cancel)?;
    let tracked = backend.tracked_ignored(toplevel, cancel)?;
    let mut matches = backend.ignore_matches(toplevel, &ignored, false, cancel)?;
    matches.extend(backend.ignore_matches(toplevel, &tracked, true, cancel)?);
    if negations {
        matches.extend(backend.ignore_matches(toplevel, untracked, false, cancel)?);
    }
    Ok(IgnoreRules::build(
        with_contents,
        &ignored,
        &matches,
        &tracked,
    ))
}

fn preview(
    backend: &dyn GitBackend,
    toplevel: &Path,
    common: &Path,
    rule: IgnoreRule,
    untracked: &[PathBuf],
    cancel: &CancelToken,
) -> Result<IgnorePreview, GitError> {
    let warning = check(&rule.pattern);
    let file = target_file(backend, toplevel, common, &rule.target, cancel)?;
    let contents = read_optional(&file)?.unwrap_or_default();
    let exists = !rule.lines().is_empty() && missing_lines(&contents, &rule).is_empty();
    let forms = match_form(&rule);
    let mut hidden = backend.untracked_matching(toplevel, untracked, &forms, cancel)?;
    let mut tracked = backend.tracked_matching(toplevel, &forms, cancel)?;
    let (hidden_count, tracked_count) = (hidden.len(), tracked.len());
    hidden.truncate(PREVIEW_SAMPLE);
    tracked.truncate(PREVIEW_SAMPLE);
    Ok(IgnorePreview {
        rule,
        exists,
        warning,
        hidden_count,
        hidden_sample: hidden,
        tracked_count,
        tracked_sample: tracked,
    })
}

fn add_rule(
    backend: &dyn GitBackend,
    toplevel: &Path,
    file: &Path,
    rule: &IgnoreRule,
    untrack: Untrack,
    cancel: &CancelToken,
) -> Result<Option<IgnoreUndo>, GitError> {
    let forms = match_form(rule);
    let tracked = match untrack {
        Untrack::Keep => Vec::new(),
        Untrack::Remove | Untrack::RefuseIfTracked => {
            backend.tracked_matching(toplevel, &forms, cancel)?
        }
    };
    if untrack == Untrack::RefuseIfTracked && !tracked.is_empty() {
        return Err(GitError::new(
            "ignore",
            GitErrorKind::TrackedMatches,
            format!("{} tracked files match the rule", tracked.len()),
        ));
    }
    let before = read_optional(file)?;
    let lines: Vec<String> = missing_lines(before.as_deref().unwrap_or_default(), rule)
        .into_iter()
        .map(str::to_owned)
        .collect();
    let line_refs: Vec<&str> = lines.iter().map(String::as_str).collect();
    let after = append_lines(before.as_deref().unwrap_or_default(), &line_refs);
    if !lines.is_empty() {
        write_file(file, &after)?;
    }
    let mut index_entries = Vec::new();
    if untrack == Untrack::Remove && !tracked.is_empty() {
        let untracked = backend
            .index_entries(toplevel, &tracked, cancel)
            .and_then(|entries| {
                backend.untrack(toplevel, &tracked, cancel)?;
                Ok(entries)
            });
        match untracked {
            Ok(entries) => index_entries = entries,
            Err(err) => {
                if !lines.is_empty() {
                    restore_file(file, before.as_deref())?;
                }
                return Err(err);
            }
        }
    }
    if lines.is_empty() && index_entries.is_empty() {
        return Ok(None);
    }
    let mut picks = Vec::new();
    if !index_entries.is_empty() {
        if let IgnoreTarget::Shared { dir } = &rule.target {
            picks.push(PathBuf::from(
                dir.join(".gitignore").to_string_lossy().replace('\\', "/"),
            ));
        }
        picks.extend(tracked);
    }
    Ok(Some(IgnoreUndo {
        file: file.to_owned(),
        before,
        after,
        wrote: !lines.is_empty(),
        lines,
        index_entries,
        picks,
        everywhere: rule.target == IgnoreTarget::Global,
    }))
}

/// Removes line `number` (1-based) of `file`, which must still read `text`.
fn remove_line(
    file: &Path,
    number: usize,
    text: &str,
    global: bool,
) -> Result<IgnoreUndo, GitError> {
    let before = read_optional(file)?.ok_or_else(|| stale_line(file))?;
    let body = before.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&before);
    let bom = before.len() - body.len();
    let mut lines: Vec<&[u8]> = body.split_inclusive(|&b| b == b'\n').collect();
    let at = number
        .checked_sub(1)
        .filter(|&i| i < lines.len())
        .ok_or_else(|| stale_line(file))?;
    let current = lines[at];
    let current = current.strip_suffix(b"\n").unwrap_or(current);
    let current = current.strip_suffix(b"\r").unwrap_or(current);
    if current != text.as_bytes() {
        return Err(stale_line(file));
    }
    lines.remove(at);
    let mut after = before[..bom].to_vec();
    after.extend(lines.concat());
    write_file(file, &after)?;
    Ok(IgnoreUndo {
        file: file.to_owned(),
        before: Some(before.clone()),
        after,
        wrote: true,
        lines: Vec::new(),
        index_entries: Vec::new(),
        picks: Vec::new(),
        everywhere: global,
    })
}

fn undo_rule(
    backend: &dyn GitBackend,
    toplevel: &Path,
    undo: &IgnoreUndo,
    cancel: &CancelToken,
) -> Result<(), GitError> {
    let current = read_optional(&undo.file)?;
    let restored = if !undo.wrote || current.as_deref() == Some(undo.after.as_slice()) {
        None
    } else if undo.lines.is_empty() {
        // A removed line, and the file changed since.
        return Err(stale_ignore_file(&undo.file));
    } else {
        let current = current.clone().unwrap_or_default();
        Some(remove_lines(&current, &undo.lines).ok_or_else(|| stale_ignore_file(&undo.file))?)
    };
    backend.restore_index_entries(toplevel, &undo.index_entries, cancel)?;
    if !undo.wrote {
        return Ok(());
    }
    match restored {
        // Unchanged since the edit: back to exactly what it was.
        None => restore_file(&undo.file, undo.before.as_deref()),
        Some(contents) => write_file(&undo.file, &contents),
    }
}

fn stale_ignore_file(path: &Path) -> GitError {
    GitError::new(
        format!("undo ignore {}", path.display()),
        GitErrorKind::Stale,
        "the ignore file changed since and the edit can no longer be taken back",
    )
}

fn stale_line(path: &Path) -> GitError {
    GitError::new(
        format!("remove ignore rule {}", path.display()),
        GitErrorKind::Stale,
        "the ignore file changed since it was read; reload and try again",
    )
}

fn already_negated(entry: &HiddenPath) -> GitError {
    GitError::new(
        format!("stop ignoring {}", entry.path.display()),
        GitErrorKind::Other,
        "the ignore file already brings it back, but a folder above it is still ignored",
    )
}

fn io_error(path: &Path, err: &std::io::Error) -> GitError {
    GitError::new(
        format!("write {}", path.display()),
        GitErrorKind::Io,
        err.to_string(),
    )
}

fn read_optional(path: &Path) -> Result<Option<Vec<u8>>, GitError> {
    match fs::read(path) {
        Ok(contents) => Ok(Some(contents)),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(io_error(path, &err)),
    }
}

fn write_file(path: &Path, contents: &[u8]) -> Result<(), GitError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| io_error(path, &e))?;
    }
    fs::write(path, contents).map_err(|e| io_error(path, &e))
}

/// Puts `path` back as `before` (deleting it when it did not exist).
fn restore_file(path: &Path, before: Option<&[u8]>) -> Result<(), GitError> {
    match before {
        Some(contents) => write_file(path, contents),
        None => match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(io_error(path, &err)),
        },
    }
}
