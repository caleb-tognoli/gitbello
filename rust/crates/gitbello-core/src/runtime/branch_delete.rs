//! Deleting branches: what the delete dialog shows first, one job that
//! deletes a branch with its worktree and its remote branch, deleting a
//! remote branch or a tag on the remote too, and undo (the local branch at
//! its commit, the remote branch pushed back, the upstream).

use super::*;
use crate::backend::{ContentMerge, CONTENT_MERGE_LIMIT};

pub const BRANCH_DELETE_INFO_JOB_LABEL: &str = "check branch";
pub const WORKTREE_DELETE_INFO_JOB_LABEL: &str = "check worktree";
pub const DELETE_BRANCH_JOB_LABEL: &str = "delete branch";
pub const DELETE_REMOTE_BRANCH_JOB_LABEL: &str = "delete remote branch";
pub const UNDO_BRANCH_DELETE_JOB_LABEL: &str = "undo branch delete";

/// Deletes remembered for undo, per repository.
pub const MAX_BRANCH_UNDO: usize = 20;

/// A branch on a remote: `origin` and `topic` for `origin/topic`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteBranch {
    pub remote: String,
    pub branch: String,
}

impl RemoteBranch {
    /// `origin/topic`.
    pub fn short_name(&self) -> String {
        format!("{}/{}", self.remote, self.branch)
    }

    /// `refs/remotes/origin/topic`.
    pub fn tracking_ref(&self) -> String {
        format!("refs/remotes/{}/{}", self.remote, self.branch)
    }
}

/// What deleting a local branch would do, for the dialog
/// ([`Runtime::load_branch_delete_info`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BranchDeleteInfo {
    pub branch: String,
    /// What it is compared with: the base's local branch (`main`), else the
    /// base (`origin/main`); commits in either count as merged.
    pub base: Option<String>,
    /// Commits on the branch (merges left out) whose change `base` lacks:
    /// a commit squashed or rebased into it counts as merged (see
    /// [`crate::backend::GitBackend::merged_by_content`]).
    pub not_in_base: u32,
    /// `base` has the branch's whole change in one commit: squash-merged.
    pub squashed: bool,
    /// `not_in_base` and `squashed` are known; until then they are 0 and
    /// false (the rest is known when the load starts).
    pub checked: bool,
    /// Commits not pushed to its upstream.
    pub ahead: u32,
    /// Its upstream, while the remote still has it.
    pub remote: Option<RemoteBranch>,
    /// The worktree that has it checked out, if any.
    pub worktree: Option<PathBuf>,
    /// It is checked out here.
    pub is_head: bool,
}

/// What deleting a worktree would lose besides its changes, for the dialog
/// ([`Runtime::load_worktree_delete_info`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorktreeDeleteInfo {
    pub path: PathBuf,
    /// The operation in progress there.
    pub operation: Option<Operation>,
    /// The local branch that operation started from (a rebase's or a
    /// bisect's: the worktree shows as detached meanwhile).
    pub branch: Option<String>,
    /// Detached with no operation: the commits of its HEAD that no branch,
    /// remote branch or tag has.
    pub unreferenced: u32,
    /// Its HEAD commit, if it has one.
    pub head: Option<String>,
}

/// One delete ([`Runtime::delete_branch`]): the local `branch` (none for a
/// remote branch alone), `remote` on its remote too, after removing
/// `worktree` (`(path, force)`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BranchDelete {
    pub branch: Option<String>,
    pub remote: Option<RemoteBranch>,
    pub worktree: Option<(PathBuf, bool)>,
}

/// What a delete removed; [`Runtime::undo_branch_delete`] puts it back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeletedBranch {
    /// The local branch and its commit.
    pub branch: Option<(String, String)>,
    /// The local branch's upstream.
    pub upstream: Option<RemoteBranch>,
    /// The remote branch deleted, at the commit this repository knew.
    pub remote: Option<(RemoteBranch, String)>,
}

impl DeletedBranch {
    /// What the undo names it by: the local branch, else the remote one.
    pub fn id(&self) -> String {
        match (&self.branch, &self.remote) {
            (Some((name, _)), _) => name.clone(),
            (None, Some((remote, _))) => remote.short_name(),
            (None, None) => String::new(),
        }
    }
}

impl RepoState {
    /// The delete info of the last [`Runtime::load_branch_delete_info`].
    pub fn branch_delete_info(&self) -> Option<&BranchDeleteInfo> {
        self.branch_delete.info.as_ref()
    }

    /// The info of the last [`Runtime::load_worktree_delete_info`].
    pub fn worktree_delete_info(&self) -> Option<&WorktreeDeleteInfo> {
        self.branch_delete.worktree_info.as_ref()
    }

    /// Whether the delete named `id` ([`DeletedBranch::id`]) can be undone.
    pub fn can_undo_branch_delete(&self, id: &str) -> bool {
        self.branch_delete.undo.iter().any(|d| d.id() == id)
    }

    /// Remote branch `short_name` (`origin/topic`) split at its remote (the
    /// longest remote name that matches), or `None`.
    pub fn split_remote_branch(&self, short_name: &str) -> Option<RemoteBranch> {
        let remote = self
            .remotes()
            .iter()
            .filter(|r| {
                short_name.len() > r.len() + 1
                    && short_name.starts_with(r.as_str())
                    && short_name[r.len()..].starts_with('/')
            })
            .max_by_key(|r| r.len())?;
        Some(RemoteBranch {
            remote: remote.clone(),
            branch: short_name[remote.len() + 1..].to_owned(),
        })
    }

    /// `branch`'s upstream as a remote branch, while the remote still has it.
    pub(super) fn live_upstream(&self, branch: &str) -> Option<RemoteBranch> {
        let (remote, name) = self.upstream_of(branch)?;
        let found = RemoteBranch {
            remote,
            branch: name,
        };
        let tracking = found.tracking_ref();
        self.refs
            .as_deref()?
            .iter()
            .any(|r| r.name == tracking)
            .then_some(found)
    }
}

/// The delete info and undo records of one repository.
#[derive(Default)]
pub(super) struct BranchDeleteState {
    info: Option<BranchDeleteInfo>,
    info_job: Option<JobId>,
    worktree_info: Option<WorktreeDeleteInfo>,
    worktree_job: Option<JobId>,
    undo: Vec<DeletedBranch>,
}

impl Runtime {
    /// Works out what deleting local `branch` would do; it arrives as
    /// [`RuntimeEvent::BranchDeleteInfoLoaded`].
    pub fn load_branch_delete_info(&mut self, key: &Path, branch: &str) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get_mut(key)?;
        let found = state.branch(branch)?.clone();
        // The base and its local branch (`origin/main` and `main`): a commit
        // in either is not lost. It shows as the local name.
        let remote_base = state.default_base();
        let local_base = remote_base
            .as_deref()
            .and_then(|b| state.split_remote_branch(b))
            .map(|r| r.branch)
            .filter(|b| state.branch(b).is_some());
        let bases: Vec<String> = remote_base
            .iter()
            .chain(local_base.iter())
            .filter(|b| **b != branch)
            .cloned()
            .collect();
        let base = local_base.or(remote_base);
        let remote = state.live_upstream(branch);
        // The status is read again soon after a switch, the branches later:
        // until then the branch list still marks the old branch as HEAD.
        let is_head = state
            .current_branch()
            .map_or(found.is_head, |current| current == branch);
        let worktree = found
            .worktree
            .clone()
            .filter(|_| !is_head && is_head == found.is_head);
        if let Some(old) = state.branch_delete.info_job.take() {
            self.scheduler.cancel(old);
        }
        // What is known now shows at once; the job adds what is merged.
        let partial = BranchDeleteInfo {
            branch: branch.to_owned(),
            base,
            not_in_base: 0,
            squashed: false,
            checked: false,
            ahead: if remote.is_some() {
                found.tracking.ahead
            } else {
                0
            },
            remote,
            worktree,
            is_head,
        };
        state.branch_delete.info = Some(partial.clone());
        let job = self.scheduler.submit(JobSpec::read(
            key,
            BRANCH_DELETE_INFO_JOB_LABEL,
            move |ctx| {
                let tip = format!("refs/heads/{}", partial.branch);
                let merge = if bases.is_empty() {
                    ContentMerge::default()
                } else {
                    ctx.backend()
                        .merged_by_content(
                            &toplevel,
                            &bases,
                            &[tip],
                            CONTENT_MERGE_LIMIT,
                            ctx.cancel_token(),
                        )?
                        .first()
                        .copied()
                        .unwrap_or_default()
                };
                Ok(JobOutput::BranchDeleteInfo(Box::new(BranchDeleteInfo {
                    not_in_base: merge.missing,
                    squashed: merge.squashed,
                    checked: true,
                    ..partial
                })))
            },
        ));
        state.branch_delete.info_job = Some(job);
        Some(job)
    }

    /// Works out what deleting linked worktree `path` would lose besides its
    /// changes: the branch an operation there started from and, detached,
    /// the commits nothing else has. Arrives as
    /// [`RuntimeEvent::WorktreeDeleteInfoLoaded`].
    pub fn load_worktree_delete_info(&mut self, key: &Path, path: &Path) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get_mut(key)?;
        let found = state
            .worktrees()?
            .iter()
            .find(|wt| normalize(&wt.path) == normalize(path))?
            .clone();
        if let Some(old) = state.branch_delete.worktree_job.take() {
            self.scheduler.cancel(old);
        }
        state.branch_delete.worktree_info = None;
        let job = self.scheduler.submit(JobSpec::read(
            key,
            WORKTREE_DELETE_INFO_JOB_LABEL,
            move |ctx| {
                let (backend, cancel) = (ctx.backend(), ctx.cancel_token());
                let details = backend.operation_details(&found.path, cancel)?;
                let mut info = WorktreeDeleteInfo {
                    path: found.path.clone(),
                    operation: details.as_ref().map(|d| d.kind),
                    branch: None,
                    unreferenced: 0,
                    head: found.head.clone(),
                };
                if let Some(name) = details.and_then(|d| d.head_name) {
                    let full = format!("refs/heads/{name}");
                    if backend.resolve(&toplevel, &full, cancel)?.is_some() {
                        info.branch = Some(name);
                    }
                } else if found.detached && info.operation.is_none() {
                    if let Some(head) = &found.head {
                        info.unreferenced = backend.unreferenced_count(&toplevel, head, cancel)?;
                    }
                }
                Ok(JobOutput::WorktreeDeleteInfo(Box::new(info)))
            },
        ));
        state.branch_delete.worktree_job = Some(job);
        Some(job)
    }

    /// Removes worktree `path` (`force` discarding its changes or lock) as
    /// [`WorktreeOp::Remove`] does, first keeping commit `oid` as new branch
    /// `keep` (unless it already is: trying again after a failure). Label
    /// `remove worktree`.
    pub fn remove_worktree_keeping(
        &self,
        key: &Path,
        path: PathBuf,
        force: bool,
        keep: String,
        oid: String,
    ) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        self.repos.get(key).filter(|s| s.is_ready())?;
        let leftovers = self.leftover_worktrees.clone();
        let label = WorktreeOp::Remove {
            path: path.clone(),
            force,
        }
        .label();
        Some(
            self.scheduler
                .submit(JobSpec::write(key, label, worktree_refresh(), move |ctx| {
                    let (backend, repo, cancel) = (ctx.backend(), ctx.repo(), ctx.cancel_token());
                    let full = format!("refs/heads/{keep}");
                    if backend.resolve(&toplevel, &full, cancel)?.as_deref() != Some(oid.as_str()) {
                        let create = RefOp::CreateBranch {
                            name: keep,
                            start: oid,
                            checkout: false,
                        };
                        backend.ref_op(&toplevel, &create, cancel)?;
                    }
                    remove_worktree(backend, repo, &path, force, &leftovers, cancel)
                        .map(|()| JobOutput::Done)
                })),
        )
    }

    /// Deletes what `delete` names: its worktree first (stopping if that
    /// fails), then the remote branch (a remote that no longer has it is
    /// fine; a failure keeps the local branch), then the local branch, merged
    /// or not. Label [`DELETE_BRANCH_JOB_LABEL`], or
    /// [`DELETE_REMOTE_BRANCH_JOB_LABEL`] without a local branch.
    pub fn delete_branch(&self, key: &Path, delete: BranchDelete) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let state = self.repos.get(key).filter(|s| s.is_ready())?;
        let upstream = delete
            .branch
            .as_deref()
            .and_then(|b| state.upstream_of(b))
            .map(|(remote, branch)| RemoteBranch { remote, branch });
        let leftovers = self.leftover_worktrees.clone();
        let label = if delete.branch.is_some() {
            DELETE_BRANCH_JOB_LABEL
        } else {
            DELETE_REMOTE_BRANCH_JOB_LABEL
        };
        let refresh = if delete.worktree.is_some() {
            worktree_refresh()
        } else {
            RefreshSet::EMPTY.with(RefreshKind::Refs)
        };
        Some(
            self.scheduler
                .submit(JobSpec::write(key, label, refresh, move |ctx| {
                    let (backend, repo, cancel) = (ctx.backend(), ctx.repo(), ctx.cancel_token());
                    let progress = Box::new(ctx.progress_sink());
                    delete_job(
                        backend, repo, &toplevel, &delete, upstream, &leftovers, progress, cancel,
                    )
                    .map(|deleted| JobOutput::BranchDeleted(Box::new(deleted)))
                })),
        )
    }

    /// Puts back the delete named `id` ([`DeletedBranch::id`]): the local
    /// branch at its commit (unless another branch took the name), the
    /// remote branch pushed back (a plain push, which never overwrites
    /// commits someone pushed since), then the upstream. Label
    /// [`UNDO_BRANCH_DELETE_JOB_LABEL`].
    pub fn undo_branch_delete(&self, key: &Path, id: &str) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let deleted = self
            .repos
            .get(key)?
            .branch_delete
            .undo
            .iter()
            .rev()
            .find(|d| d.id() == id)?
            .clone();
        Some(
            self.scheduler.submit(JobSpec::write(
                key,
                UNDO_BRANCH_DELETE_JOB_LABEL,
                RefreshSet::EMPTY
                    .with(RefreshKind::Refs)
                    .with(RefreshKind::Status),
                move |ctx| {
                    let progress = Box::new(ctx.progress_sink());
                    undo_job(
                        ctx.backend(),
                        &toplevel,
                        &deleted,
                        progress,
                        ctx.cancel_token(),
                    )
                    .map(|()| JobOutput::BranchRestored(Box::new(deleted)))
                },
            )),
        )
    }

    /// Deletes tag `name`, and on `remote` too unless `None` (a remote
    /// without it is fine). Label `delete tag`.
    pub fn delete_tag(&self, key: &Path, name: &str, remote: Option<String>) -> Option<JobId> {
        let toplevel = self.toplevel_of(key)?;
        let delete = RefOp::DeleteTag {
            name: name.to_owned(),
        };
        let refspec = format!(":refs/tags/{name}");
        Some(self.scheduler.submit(JobSpec::write(
            key,
            delete.label(),
            RefreshSet::EMPTY.with(RefreshKind::Refs),
            move |ctx| {
                let (backend, cancel) = (ctx.backend(), ctx.cancel_token());
                if let Some(remote) = &remote {
                    let progress = Box::new(ctx.progress_sink());
                    push_delete(backend, &toplevel, remote, &refspec, progress, cancel)?;
                }
                backend
                    .ref_op(&toplevel, &delete, cancel)
                    .map(|()| JobOutput::Done)
            },
        )))
    }

    /// Handles the delete jobs' results. Returns whether `label` needs
    /// nothing else.
    pub(super) fn apply_branch_delete_event(
        state: &mut RepoState,
        job: JobId,
        label: &str,
        kind: &EventKind,
        repo: &Path,
        out: &mut Vec<RuntimeEvent>,
    ) -> bool {
        if label == WORKTREE_DELETE_INFO_JOB_LABEL {
            if state.branch_delete.worktree_job == Some(job) {
                match kind {
                    EventKind::Finished(Ok(JobOutput::WorktreeDeleteInfo(info))) => {
                        state.branch_delete.worktree_info = Some(info.as_ref().clone());
                    }
                    EventKind::Finished(_) => state.branch_delete.worktree_info = None,
                    _ => return true,
                }
                state.branch_delete.worktree_job = None;
                out.push(RuntimeEvent::WorktreeDeleteInfoLoaded {
                    repo: repo.to_owned(),
                    job,
                });
            }
            return true;
        }
        if label == BRANCH_DELETE_INFO_JOB_LABEL {
            if let EventKind::Finished(Ok(JobOutput::BranchDeleteInfo(info))) = kind {
                if state.branch_delete.info_job == Some(job) {
                    state.branch_delete.info_job = None;
                    state.branch_delete.info = Some(info.as_ref().clone());
                    out.push(RuntimeEvent::BranchDeleteInfoLoaded {
                        repo: repo.to_owned(),
                        job,
                    });
                }
                return true;
            }
            // A failed check leaves the info unchecked, and says so.
            if let EventKind::Finished(Err(_)) = kind {
                if state.branch_delete.info_job == Some(job) {
                    state.branch_delete.info_job = None;
                    out.push(RuntimeEvent::BranchDeleteInfoLoaded {
                        repo: repo.to_owned(),
                        job,
                    });
                }
            }
            return false;
        }
        let undo = &mut state.branch_delete.undo;
        match kind {
            EventKind::Finished(Ok(JobOutput::BranchDeleted(deleted))) => {
                undo.push(deleted.as_ref().clone());
                let excess = undo.len().saturating_sub(MAX_BRANCH_UNDO);
                undo.drain(..excess);
            }
            EventKind::Finished(Ok(JobOutput::BranchRestored(restored))) => {
                if let Some(at) = undo.iter().rposition(|d| d == restored.as_ref()) {
                    undo.remove(at);
                }
            }
            _ => {}
        }
        false
    }
}

/// The work of [`Runtime::delete_branch`].
#[allow(clippy::too_many_arguments)]
pub(super) fn delete_job(
    backend: &dyn GitBackend,
    repo: &Path,
    toplevel: &Path,
    delete: &BranchDelete,
    upstream: Option<RemoteBranch>,
    leftovers: &Mutex<HashSet<PathBuf>>,
    progress: crate::backend::ProgressSink,
    cancel: &CancelToken,
) -> Result<DeletedBranch, GitError> {
    let branch = match &delete.branch {
        Some(name) => {
            let tip = format!("refs/heads/{name}");
            let oid = backend.resolve(toplevel, &tip, cancel)?.ok_or_else(|| {
                GitError::new(
                    "delete branch",
                    GitErrorKind::Other,
                    format!("error: branch '{name}' not found"),
                )
            })?;
            Some((name.clone(), oid))
        }
        None => None,
    };
    if let Some((path, force)) = &delete.worktree {
        remove_worktree(backend, repo, path, *force, leftovers, cancel)?;
    }
    let mut remote = None;
    if let Some(target) = &delete.remote {
        let known = backend.resolve(toplevel, &target.tracking_ref(), cancel)?;
        let refspec = format!(":refs/heads/{}", target.branch);
        let deleted = push_delete(
            backend,
            toplevel,
            &target.remote,
            &refspec,
            progress,
            cancel,
        )?;
        if !deleted {
            // The remote no longer had it: forget the stale remote branch.
            let forget = RefOp::DeleteRef {
                name: target.tracking_ref(),
            };
            let _ = backend.ref_op(toplevel, &forget, cancel);
        }
        // Undo puts back what this repository showed, even when the
        // remote had already lost it.
        remote = known.map(|oid| (target.clone(), oid));
    }
    if let Some((name, _)) = &branch {
        let delete = RefOp::DeleteBranch {
            name: name.clone(),
            force: true,
        };
        backend.ref_op(toplevel, &delete, cancel)?;
    }
    Ok(DeletedBranch {
        branch,
        upstream,
        remote,
    })
}

/// Pushes the deletion `refspec` (`:refs/...`) to `remote`. Returns `false`
/// when the remote did not have it.
fn push_delete(
    backend: &dyn GitBackend,
    toplevel: &Path,
    remote: &str,
    refspec: &str,
    progress: crate::backend::ProgressSink,
    cancel: &CancelToken,
) -> Result<bool, GitError> {
    let push = SyncOp::Push(PushSpec {
        remote: remote.to_owned(),
        refspecs: vec![refspec.to_owned()],
        set_upstream: false,
        force_with_lease: None,
    });
    match backend.sync(toplevel, &push, progress, cancel) {
        Ok(()) => Ok(true),
        Err(err) if err.stderr.contains("remote ref does not exist") => Ok(false),
        Err(err) => Err(err),
    }
}

/// The work of [`Runtime::undo_branch_delete`].
fn undo_job(
    backend: &dyn GitBackend,
    toplevel: &Path,
    deleted: &DeletedBranch,
    progress: crate::backend::ProgressSink,
    cancel: &CancelToken,
) -> Result<(), GitError> {
    if let Some((name, oid)) = &deleted.branch {
        match backend.resolve(toplevel, &format!("refs/heads/{name}"), cancel)? {
            Some(now) if now == *oid => {}
            Some(_) => {
                return Err(GitError::new(
                    "undo branch delete",
                    GitErrorKind::AlreadyExists,
                    format!("fatal: a branch named '{name}' already exists"),
                ))
            }
            None => {
                let create = RefOp::CreateBranch {
                    name: name.clone(),
                    start: oid.clone(),
                    checkout: false,
                };
                backend.ref_op(toplevel, &create, cancel)?;
            }
        }
    }
    if let Some((target, oid)) = &deleted.remote {
        let push = SyncOp::Push(PushSpec {
            remote: target.remote.clone(),
            refspecs: vec![format!("{oid}:refs/heads/{}", target.branch)],
            set_upstream: false,
            force_with_lease: None,
        });
        backend.sync(toplevel, &push, progress, cancel)?;
    }
    if let (Some((name, _)), Some(upstream)) = (&deleted.branch, &deleted.upstream) {
        if backend
            .resolve(toplevel, &upstream.tracking_ref(), cancel)?
            .is_some()
        {
            let track = RefOp::SetUpstream {
                branch: name.clone(),
                upstream: Some(upstream.short_name()),
            };
            backend.ref_op(toplevel, &track, cancel)?;
        }
    }
    Ok(())
}
