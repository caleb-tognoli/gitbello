use thiserror::Error;

/// A failed git invocation (PLAN §3.2). `kind` lets the UI offer specific fixes.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("git {command}: {kind}{}", stderr_suffix(.stderr))]
pub struct GitError {
    /// The git arguments, for display and logging (without the global flags).
    pub command: String,
    /// Exit code, when the process ran and exited normally.
    pub exit_code: Option<i32>,
    /// Captured stderr, or a description of the I/O failure.
    pub stderr: String,
    pub kind: GitErrorKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Error)]
#[non_exhaustive]
pub enum GitErrorKind {
    #[error("git executable not found")]
    GitNotFound,
    #[error("git is older than the supported minimum")]
    VersionTooOld,
    #[error("could not start git")]
    Spawn,
    #[error("I/O error while talking to git")]
    Io,
    #[error("not a git repository")]
    NotARepository,
    #[error("authentication failed")]
    AuthFailed,
    #[error("rejected: not a fast-forward")]
    NonFastForward,
    #[error("conflict")]
    Conflict,
    #[error("another git process holds a lock")]
    LockExists,
    #[error("cancelled")]
    Cancelled,
    #[error("git failed")]
    Other,
}

fn stderr_suffix(stderr: &str) -> String {
    let trimmed = stderr.trim();
    if trimmed.is_empty() {
        String::new()
    } else {
        format!(": {trimmed}")
    }
}

impl GitError {
    pub fn new(command: impl Into<String>, kind: GitErrorKind, stderr: impl Into<String>) -> Self {
        Self {
            command: command.into(),
            exit_code: None,
            stderr: stderr.into(),
            kind,
        }
    }

    /// Builds the error for a git process that exited unsuccessfully.
    pub fn from_exit(
        command: impl Into<String>,
        exit_code: Option<i32>,
        stdout: &[u8],
        stderr: &[u8],
    ) -> Self {
        let stderr = String::from_utf8_lossy(stderr).into_owned();
        let kind = GitErrorKind::classify(&String::from_utf8_lossy(stdout), &stderr);
        Self {
            command: command.into(),
            exit_code,
            stderr,
            kind,
        }
    }
}

impl GitErrorKind {
    /// Classifies a failure from git's output. Relies on `LC_ALL=C`, which the
    /// runner always sets.
    pub fn classify(stdout: &str, stderr: &str) -> Self {
        let has = |needle: &str| stderr.contains(needle) || stdout.contains(needle);
        if has("not a git repository") {
            Self::NotARepository
        } else if has(".lock': File exists") || has(".lock': file exists") {
            Self::LockExists
        } else if has("Authentication failed")
            || has("could not read Username")
            || has("could not read Password")
            || has("terminal prompts disabled")
            || has("Permission denied (publickey")
        {
            Self::AuthFailed
        } else if has("[rejected]") && (has("non-fast-forward") || has("fetch first")) {
            Self::NonFastForward
        } else if has("CONFLICT")
            || has("needs merge")
            || has("you need to resolve your current index first")
        {
            Self::Conflict
        } else {
            Self::Other
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_captured_output() {
        let cases = [
            (
                "",
                "fatal: not a git repository (or any of the parent directories): .git\n",
                GitErrorKind::NotARepository,
            ),
            (
                "",
                "fatal: Unable to create '/r/.git/index.lock': File exists.\n\nAnother git process seems to be running",
                GitErrorKind::LockExists,
            ),
            (
                "",
                "fatal: could not read Username for 'https://github.com': terminal prompts disabled\n",
                GitErrorKind::AuthFailed,
            ),
            (
                "",
                "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
                GitErrorKind::AuthFailed,
            ),
            (
                "",
                "To ../remote.git\n ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs",
                GitErrorKind::NonFastForward,
            ),
            (
                "",
                " ! [rejected]        main -> main (non-fast-forward)\n",
                GitErrorKind::NonFastForward,
            ),
            (
                "Auto-merging a.txt\nCONFLICT (content): Merge conflict in a.txt\nAutomatic merge failed",
                "",
                GitErrorKind::Conflict,
            ),
            ("", "fatal: bad revision 'nope'\n", GitErrorKind::Other),
        ];
        for (stdout, stderr, expected) in cases {
            assert_eq!(
                GitErrorKind::classify(stdout, stderr),
                expected,
                "{stderr}{stdout}"
            );
        }
    }

    #[test]
    fn display_includes_command_kind_and_stderr() {
        let err = GitError::from_exit(
            "log --all",
            Some(128),
            b"",
            b"fatal: not a git repository\n",
        );
        assert_eq!(err.kind, GitErrorKind::NotARepository);
        assert_eq!(err.exit_code, Some(128));
        assert_eq!(
            err.to_string(),
            "git log --all: not a git repository: fatal: not a git repository"
        );
    }
}
