//! `git for-each-ref` with NUL-separated fields, plus `git remote -v` for
//! the remotes (their names split remote-tracking names) and the worktrees'
//! HEAD reflogs (when each branch was last checked out).

use std::collections::HashMap;
use std::path::PathBuf;

use super::{git_path, text, ParseError};

const FORMAT: &str = "--format=%(refname)%00%(objectname)%00%(objecttype)%00%(*objectname)\
%00%(upstream)%00%(upstream:track,nobracket)%00%(HEAD)%00%(symref)%00%(worktreepath)\
%00%(committerdate:unix)";

pub const REFS_ARGS: &[&str] = &["for-each-ref", FORMAT];

const FIELDS: usize = 10;
const WHAT: &str = "refs";

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum RefKind {
    Branch,
    RemoteBranch { remote: String },
    Tag,
    Stash,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Tracking {
    pub ahead: u32,
    pub behind: u32,
    /// The configured upstream no longer exists (for example after a squash
    /// merge and branch deletion on the remote).
    pub gone: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ref {
    /// Full name, e.g. `refs/heads/main`.
    pub name: String,
    pub kind: RefKind,
    /// Display name: `main`, `origin/main`, `v1.0`.
    pub short_name: String,
    /// Object the ref points at (a tag object for annotated tags).
    pub target: String,
    /// Commit an annotated tag points at.
    pub peeled: Option<String>,
    /// Full name of the upstream ref, e.g. `refs/remotes/origin/main`.
    pub upstream: Option<String>,
    pub tracking: Tracking,
    /// The branch checked out in this worktree.
    pub is_head: bool,
    /// For symbolic refs such as `refs/remotes/origin/HEAD`.
    pub symref_target: Option<String>,
    /// Worktree where this branch is checked out, if any.
    pub worktree: Option<PathBuf>,
    /// Committer date (Unix seconds) of the commit the ref points at; `None`
    /// for annotated tags and symbolic refs.
    pub committed_at: Option<i64>,
    /// When the branch was last checked out in any worktree (Unix seconds,
    /// from the HEAD reflogs; see [`parse_checkouts`]). `None` when no reflog
    /// remembers it, and for other kinds of refs.
    pub checked_out_at: Option<i64>,
}

/// A configured remote and its URLs (`git remote -v`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Remote {
    pub name: String,
    pub fetch_url: String,
    /// Usually the fetch URL; differs when `pushurl` is set.
    pub push_url: String,
}

impl Ref {
    /// The commit this ref ultimately points at.
    pub fn commit(&self) -> &str {
        self.peeled.as_deref().unwrap_or(&self.target)
    }

    /// For remote-tracking refs, the branch name without the remote.
    pub fn remote_branch_name(&self) -> Option<&str> {
        match &self.kind {
            RefKind::RemoteBranch { remote } => self
                .short_name
                .strip_prefix(remote.as_str())
                .and_then(|rest| rest.strip_prefix('/')),
            _ => None,
        }
    }
}

/// `git remote` output: one name per line.
pub fn parse_remotes(output: &[u8]) -> Vec<String> {
    text(output)
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(str::to_owned)
        .collect()
}

/// `git remote -v` output: `name<TAB>url (fetch|push)` lines, two per remote,
/// in the order git lists the remotes.
pub fn parse_remote_urls(output: &[u8]) -> Vec<Remote> {
    let mut remotes: Vec<Remote> = Vec::new();
    for line in text(output).lines() {
        let Some((name, rest)) = line.split_once('\t') else {
            continue;
        };
        let (url, push) = if let Some(url) = rest.strip_suffix(" (push)") {
            (url, true)
        } else {
            (rest.strip_suffix(" (fetch)").unwrap_or(rest), false)
        };
        let index = match remotes.iter().position(|r| r.name == name) {
            Some(index) => index,
            None => {
                remotes.push(Remote {
                    name: name.to_owned(),
                    fetch_url: url.to_owned(),
                    push_url: url.to_owned(),
                });
                remotes.len() - 1
            }
        };
        if push {
            remotes[index].push_url = url.to_owned();
        } else {
            remotes[index].fetch_url = url.to_owned();
        }
    }
    remotes
}

/// Parses [`REFS_ARGS`] output. `remotes` (from [`parse_remotes`]) resolves
/// remote names that contain `/`.
pub fn parse_refs(output: &[u8], remotes: &[String]) -> Result<Vec<Ref>, ParseError> {
    let mut refs = Vec::new();
    for line in output.split(|&b| b == b'\n').filter(|l| !l.is_empty()) {
        let f: Vec<&[u8]> = line.split(|&b| b == 0).collect();
        if f.len() != FIELDS {
            return Err(ParseError::new(
                WHAT,
                format!(
                    "expected {FIELDS} fields, got {} in `{}`",
                    f.len(),
                    text(line)
                ),
            ));
        }
        let name = text(f[0]);
        let (kind, short_name) = classify(&name, remotes);
        let non_empty = |bytes: &[u8]| (!bytes.is_empty()).then(|| text(bytes));
        refs.push(Ref {
            kind,
            short_name,
            target: text(f[1]),
            peeled: non_empty(f[3]),
            upstream: non_empty(f[4]),
            tracking: parse_tracking(&text(f[5]))?,
            is_head: f[6] == b"*",
            symref_target: non_empty(f[7]),
            worktree: (!f[8].is_empty()).then(|| git_path(f[8])),
            committed_at: text(f[9]).trim().parse().ok(),
            checked_out_at: None,
            name,
        });
    }
    Ok(refs)
}

/// The latest time each branch was checked out, from a HEAD reflog's lines
/// (`<old> <new> <name> <<email>> <time> <tz>\t<message>`): the target of
/// `checkout: moving from <a> to <b>` and of a rebase's `returning to
/// refs/heads/<b>`. Targets that are not branch names (commits, tags) are
/// kept too; [`apply_checkouts`] only looks up branches. Bad lines are skipped:
/// a reflog read from its tail may start mid-line.
pub fn parse_checkouts(reflog: &[u8], out: &mut HashMap<String, i64>) {
    for line in reflog.split(|&b| b == b'\n') {
        let line = text(line);
        let Some((who, message)) = line.split_once('\t') else {
            continue;
        };
        let mut tail = who.trim_end().rsplitn(3, ' ');
        let (Some(_tz), Some(time)) = (tail.next(), tail.next()) else {
            continue;
        };
        let Ok(time) = time.parse::<i64>() else {
            continue;
        };
        let target = if let Some(moving) = message.strip_prefix("checkout: moving from ") {
            moving.rsplit_once(" to ").map(|(_, to)| to)
        } else if message.starts_with("rebase") {
            message
                .split_once("returning to refs/heads/")
                .map(|(_, to)| to)
        } else {
            None
        };
        let Some(target) = target.map(str::trim).filter(|t| !t.is_empty()) else {
            continue;
        };
        let at = out.entry(target.to_owned()).or_insert(time);
        *at = (*at).max(time);
    }
}

/// Sets each local branch's [`Ref::checked_out_at`] from [`parse_checkouts`].
pub fn apply_checkouts(refs: &mut [Ref], checkouts: &HashMap<String, i64>) {
    for r in refs.iter_mut().filter(|r| r.kind == RefKind::Branch) {
        r.checked_out_at = checkouts.get(&r.short_name).copied();
    }
}

fn classify(name: &str, remotes: &[String]) -> (RefKind, String) {
    if let Some(short) = name.strip_prefix("refs/heads/") {
        return (RefKind::Branch, short.to_owned());
    }
    if let Some(short) = name.strip_prefix("refs/tags/") {
        return (RefKind::Tag, short.to_owned());
    }
    if name == "refs/stash" {
        return (RefKind::Stash, "stash".to_owned());
    }
    if let Some(short) = name.strip_prefix("refs/remotes/") {
        // Longest matching remote name wins (`a/b` over `a`).
        let remote = remotes
            .iter()
            .filter(|r| short.starts_with(r.as_str()) && short[r.len()..].starts_with('/'))
            .max_by_key(|r| r.len())
            .cloned()
            .unwrap_or_else(|| short.split('/').next().unwrap_or_default().to_owned());
        return (RefKind::RemoteBranch { remote }, short.to_owned());
    }
    (RefKind::Other, name.to_owned())
}

/// `ahead 3, behind 2`, `ahead 1`, `behind 4`, `gone` or empty.
fn parse_tracking(track: &str) -> Result<Tracking, ParseError> {
    let mut tracking = Tracking::default();
    for part in track.split(',').map(str::trim).filter(|p| !p.is_empty()) {
        let bad = || ParseError::new(WHAT, format!("bad tracking `{track}`"));
        match part.split_once(' ') {
            Some(("ahead", n)) => tracking.ahead = n.parse().map_err(|_| bad())?,
            Some(("behind", n)) => tracking.behind = n.parse().map_err(|_| bad())?,
            None if part == "gone" => tracking.gone = true,
            _ => return Err(bad()),
        }
    }
    Ok(tracking)
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: &str = "1111111111111111111111111111111111111111";
    const B: &str = "2222222222222222222222222222222222222222";

    /// A ref line without a commit date.
    fn line(fields: [&str; FIELDS - 1]) -> String {
        line_at(fields, "")
    }

    fn line_at(fields: [&str; FIELDS - 1], date: &str) -> String {
        fields.join("\0") + "\0" + date + "\n"
    }

    fn captured() -> Vec<u8> {
        [
            line_at(
                [
                    "refs/heads/main",
                    A,
                    "commit",
                    "",
                    "refs/remotes/origin/main",
                    "ahead 2, behind 1",
                    "*",
                    "",
                    "/home/a/repo",
                ],
                "1700000000",
            ),
            line([
                "refs/heads/feature/wörk",
                B,
                "commit",
                "",
                "refs/remotes/origin/feature/wörk",
                "gone",
                " ",
                "",
                "",
            ]),
            line([
                "refs/heads/local-only",
                B,
                "commit",
                "",
                "",
                "",
                " ",
                "",
                "/home/a/repo.worktrees/local-only",
            ]),
            line([
                "refs/remotes/origin/HEAD",
                A,
                "commit",
                "",
                "",
                "",
                " ",
                "refs/remotes/origin/main",
                "",
            ]),
            line([
                "refs/remotes/origin/main",
                A,
                "commit",
                "",
                "",
                "",
                " ",
                "",
                "",
            ]),
            line([
                "refs/remotes/team/x/topic",
                B,
                "commit",
                "",
                "",
                "",
                " ",
                "",
                "",
            ]),
            line(["refs/stash", B, "commit", "", "", "", " ", "", ""]),
            line(["refs/tags/v1.0", B, "tag", A, "", "", " ", "", ""]),
            line(["refs/tags/light", A, "commit", "", "", "", " ", "", ""]),
            line(["refs/notes/commits", A, "commit", "", "", "", " ", "", ""]),
        ]
        .concat()
        .into_bytes()
    }

    #[test]
    fn parses_branches_with_tracking() {
        let refs = parse_refs(&captured(), &["origin".into(), "team/x".into()]).unwrap();
        assert_eq!(refs.len(), 10);
        let main = &refs[0];
        assert_eq!(
            (main.kind.clone(), main.short_name.as_str()),
            (RefKind::Branch, "main")
        );
        assert!(main.is_head);
        assert_eq!(main.upstream.as_deref(), Some("refs/remotes/origin/main"));
        assert_eq!(
            main.tracking,
            Tracking {
                ahead: 2,
                behind: 1,
                gone: false
            }
        );
        assert_eq!(main.worktree, Some(PathBuf::from("/home/a/repo")));
        assert_eq!(main.committed_at, Some(1_700_000_000));
        assert_eq!(refs[1].committed_at, None);

        let gone = &refs[1];
        assert_eq!(gone.short_name, "feature/wörk");
        assert!(gone.tracking.gone && !gone.is_head);
        assert_eq!(refs[2].upstream, None);
        assert!(refs[2].worktree.is_some());
    }

    #[test]
    fn splits_remote_names_using_the_remote_list() {
        let refs = parse_refs(
            &captured(),
            &["origin".into(), "team/x".into(), "team".into()],
        )
        .unwrap();
        assert_eq!(
            refs[3].symref_target.as_deref(),
            Some("refs/remotes/origin/main")
        );
        assert_eq!(
            refs[4].kind,
            RefKind::RemoteBranch {
                remote: "origin".into()
            }
        );
        assert_eq!(refs[4].remote_branch_name(), Some("main"));
        assert_eq!(
            refs[5].kind,
            RefKind::RemoteBranch {
                remote: "team/x".into()
            }
        );
        assert_eq!(refs[5].remote_branch_name(), Some("topic"));
    }

    #[test]
    fn handles_tags_stash_and_other_refs() {
        let refs = parse_refs(&captured(), &["origin".into()]).unwrap();
        assert_eq!(refs[6].kind, RefKind::Stash);
        let annotated = &refs[7];
        assert_eq!(annotated.kind, RefKind::Tag);
        assert_eq!((annotated.target.as_str(), annotated.commit()), (B, A));
        assert_eq!(refs[8].commit(), A);
        assert_eq!(refs[9].kind, RefKind::Other);
    }

    #[test]
    fn reads_checkouts_from_a_reflog() {
        // Read from its tail, a reflog may start mid-line.
        let reflog = [
            "ed main",
            "0 1 A U Thor <a@x> 100 +0000\tcommit (initial): one",
            "1 2 A U Thor <a@x> 200 +0100\tcheckout: moving from main to feature/wörk",
            "2 1 A U Thor <a@x> 300 -0200\tcheckout: moving from feature/wörk to main",
            "1 3 A U Thor <a@x> 400 +0000\tcheckout: moving from main to 3333333",
            "3 2 A U Thor <a@x> 250 +0000\tcheckout: moving from 3333333 to feature/wörk",
            "2 4 A U Thor <a@x> 500 +0000\trebase (finish): returning to refs/heads/local-only",
            "4 4 bad line without a time\tcheckout: moving from a to b",
        ]
        .join("\n");
        let mut checkouts = HashMap::new();
        parse_checkouts(reflog.as_bytes(), &mut checkouts);
        assert_eq!(checkouts.get("main"), Some(&300));
        assert_eq!(checkouts.get("feature/wörk"), Some(&250));
        assert_eq!(checkouts.get("local-only"), Some(&500));
        assert_eq!(checkouts.get("b"), None);
        // A later reflog (another worktree's) keeps the newest time.
        parse_checkouts(
            b"1 2 B <b@x> 900 +0000\tcheckout: moving from x to main\n",
            &mut checkouts,
        );
        let mut refs = parse_refs(&captured(), &["origin".into()]).unwrap();
        apply_checkouts(&mut refs, &checkouts);
        assert_eq!(refs[0].checked_out_at, Some(900));
        assert_eq!(refs[1].checked_out_at, Some(250));
        assert_eq!(refs[4].checked_out_at, None);
    }

    #[test]
    fn parses_remote_list_and_rejects_bad_lines() {
        assert_eq!(parse_remotes(b"origin\nteam/x\n\n"), ["origin", "team/x"]);
        let urls = parse_remote_urls(
            "origin\thttps://example.com/a.git (fetch)\norigin\thttps://example.com/a.git (push)\n\
             team/x\tC:/My Repos/x (fetch)\nteam/x\tgit@host:x.git (push)\n"
                .as_bytes(),
        );
        assert_eq!(
            urls,
            [
                Remote {
                    name: "origin".into(),
                    fetch_url: "https://example.com/a.git".into(),
                    push_url: "https://example.com/a.git".into(),
                },
                Remote {
                    name: "team/x".into(),
                    fetch_url: "C:/My Repos/x".into(),
                    push_url: "git@host:x.git".into(),
                },
            ]
        );
        assert!(parse_refs(b"refs/heads/a\0only two\n", &[]).is_err());
        let bad = line([
            "refs/heads/a",
            A,
            "commit",
            "",
            "",
            "ahead lots",
            " ",
            "",
            "",
        ]);
        assert!(parse_refs(bad.as_bytes(), &[]).is_err());
    }
}
