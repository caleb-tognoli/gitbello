//! `gitbello-cli fixture <dir> [--repos N]`: builds throwaway repositories for
//! the Godot smoke tests (GDScript never runs git itself).
//!
//! Each `repo-<n>` has: two commits on `main`, a `feature/login` branch, a
//! `v1.0` tag, a bare `origin` remote with `main` pushed and one commit ahead,
//! a stash, a linked worktree and one modified plus one untracked file. The
//! remote also has a commit (`remote.txt`) that `repo-<n>` has not fetched,
//! so a fetch leaves `main` one ahead and one behind.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use gitbello_core::git::GitRunner;

pub fn run(args: &[String]) -> Result<()> {
    let mut dir = None;
    let mut repos = 1usize;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--repos" => {
                repos = iter
                    .next()
                    .context("--repos needs a number")?
                    .parse()
                    .context("--repos needs a number")?;
            }
            other if dir.is_none() => dir = Some(PathBuf::from(other)),
            other => bail!("unexpected argument `{other}`"),
        }
    }
    let dir = dir.context("fixture needs a target directory")?;
    if dir.exists() && fs::read_dir(&dir)?.next().is_some() {
        bail!("{} is not empty", dir.display());
    }
    fs::create_dir_all(&dir)?;
    let runner = GitRunner::discover()?;
    let global_config = dir.join("global.gitconfig");
    fs::write(&global_config, "")?;
    for n in 1..=repos {
        let repo = dir.join(format!("repo-{n}"));
        build_repo(&runner, &repo, &global_config, n)
            .with_context(|| format!("building {}", repo.display()))?;
        println!("{}", repo.display());
    }
    Ok(())
}

struct Git<'a> {
    runner: &'a GitRunner,
    global_config: &'a Path,
    clock: std::cell::Cell<i64>,
}

impl Git<'_> {
    fn run(&self, dir: &Path, args: &[&str], stdin: Option<&str>) -> Result<()> {
        let time = self.clock.get();
        self.clock.set(time + 60);
        let date = format!("{time} +0000");
        let mut cmd = self
            .runner
            .write(dir)
            .env("GIT_CONFIG_GLOBAL", self.global_config)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "Fixture")
            .env("GIT_AUTHOR_EMAIL", "fixture@example.com")
            .env("GIT_AUTHOR_DATE", &date)
            .env("GIT_COMMITTER_NAME", "Fixture")
            .env("GIT_COMMITTER_EMAIL", "fixture@example.com")
            .env("GIT_COMMITTER_DATE", &date)
            .args(["-c", "commit.gpgsign=false", "-c", "core.autocrlf=false"])
            .args(args);
        if let Some(input) = stdin {
            cmd = cmd.stdin(input);
        }
        cmd.run()?;
        Ok(())
    }

    fn commit(&self, repo: &Path, file: &str, content: &str, message: &str) -> Result<()> {
        fs::write(repo.join(file), content)?;
        self.run(repo, &["add", "--", file], None)?;
        self.run(repo, &["commit", "--quiet", "-F", "-"], Some(message))
    }
}

fn slash(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

/// Someone else's commit on the remote, pushed from a throwaway clone.
fn push_remote_change(git: &Git<'_>, repo: &Path, remote: &Path, n: usize) -> Result<()> {
    let clone = repo.with_file_name(format!("repo-{n}-other"));
    git.run(
        repo,
        &["clone", "--quiet", &slash(remote), &slash(&clone)],
        None,
    )?;
    git.commit(&clone, "remote.txt", "from elsewhere\n", "Remote change")?;
    git.run(&clone, &["push", "--quiet", "origin", "main"], None)?;
    remove_tree(&clone).with_context(|| format!("removing {}", clone.display()))
}

/// `remove_dir_all` that first clears the read-only flag git puts on object
/// files (Windows refuses to delete those).
fn remove_tree(dir: &Path) -> std::io::Result<()> {
    fn walk(path: &Path) {
        if let Ok(meta) = fs::symlink_metadata(path) {
            let mut perms = meta.permissions();
            #[allow(clippy::permissions_set_readonly_false)]
            perms.set_readonly(false);
            let _ = fs::set_permissions(path, perms);
            if meta.is_dir() {
                for entry in fs::read_dir(path).into_iter().flatten().flatten() {
                    walk(&entry.path());
                }
            }
        }
    }
    if fs::remove_dir_all(dir).is_ok() {
        return Ok(());
    }
    walk(dir);
    fs::remove_dir_all(dir)
}

fn build_repo(runner: &GitRunner, repo: &Path, global_config: &Path, n: usize) -> Result<()> {
    fs::create_dir_all(repo)?;
    let git = Git {
        runner,
        global_config,
        clock: std::cell::Cell::new(1_700_000_000),
    };
    git.run(repo, &["init", "--quiet", "--initial-branch=main"], None)?;
    git.commit(
        repo,
        "README.md",
        &format!("# repo {n}\n"),
        "Initial commit",
    )?;
    git.commit(repo, "app.txt", "v1\n", "Add app")?;
    git.run(repo, &["tag", "-a", "-m", "First release", "v1.0"], None)?;
    git.run(repo, &["branch", "feature/login"], None)?;

    let remote = repo.with_file_name(format!("repo-{n}-origin.git"));
    git.run(
        repo,
        &[
            "init",
            "--quiet",
            "--bare",
            "--initial-branch=main",
            &slash(&remote),
        ],
        None,
    )?;
    git.run(repo, &["remote", "add", "origin", &slash(&remote)], None)?;
    git.run(repo, &["push", "--quiet", "-u", "origin", "main"], None)?;
    push_remote_change(&git, repo, &remote, n)?;
    git.commit(repo, "app.txt", "v2\n", "Improve app")?;

    fs::write(repo.join("app.txt"), "stashed change\n")?;
    git.run(
        repo,
        &["stash", "push", "--quiet", "-m", "work in progress"],
        None,
    )?;

    let worktree = repo.with_file_name(format!("repo-{n}-feature"));
    git.run(
        repo,
        &[
            "worktree",
            "add",
            "--quiet",
            &slash(&worktree),
            "feature/login",
        ],
        None,
    )?;

    fs::write(repo.join("app.txt"), "local edit\n")?;
    fs::write(repo.join("notes.txt"), "untracked\n")?;
    Ok(())
}
