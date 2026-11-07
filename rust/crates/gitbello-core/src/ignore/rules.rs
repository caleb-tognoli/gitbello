//! The ignore rules viewer's model (M7.7b, `docs/IGNORE_RULES.md` §2): every
//! file git reads ignore rules from, its lines, and what each line decides,
//! worked out from `git ls-files --directory` and `git check-ignore -v`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use super::{escape_path, parent, relative, slash, IgnoreTarget};
use crate::repo::{FileState, RepoStatus};

/// Which kind of file a source is, in git's order of precedence (a nested
/// `.gitignore` wins over the root one, which wins over `info/exclude`,
/// which wins over the global file).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceKind {
    Root,
    Nested,
    /// `info/exclude`: this computer, every worktree.
    Local,
    /// `core.excludesFile`: every repository of this user.
    Global,
}

impl SourceKind {
    pub fn id(self) -> &'static str {
        match self {
            Self::Root => "root",
            Self::Nested => "nested",
            Self::Local => "local",
            Self::Global => "global",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineKind {
    Rule,
    /// A `!` line, which brings back what an earlier rule ignored.
    Negation,
    Comment,
    Blank,
}

impl LineKind {
    pub fn id(self) -> &'static str {
        match self {
            Self::Rule => "rule",
            Self::Negation => "negation",
            Self::Comment => "comment",
            Self::Blank => "blank",
        }
    }
}

/// An untracked path git ignores. A folder whose contents are all ignored is
/// one entry (`is_dir`), as `ls-files --directory` lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HiddenPath {
    /// Repo-relative, `/`-separated, without a trailing `/`.
    pub path: PathBuf,
    pub is_dir: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IgnoreLine {
    /// 1-based, as `check-ignore -v` numbers them.
    pub number: usize,
    /// Without its line ending.
    pub text: String,
    pub kind: LineKind,
    /// Untracked paths this line is the one to ignore, sorted.
    pub hidden: Vec<HiddenPath>,
    /// Tracked files it matches (they stay tracked), sorted.
    pub tracked: Vec<PathBuf>,
    /// For a negation: untracked files it brings back.
    pub reincluded: usize,
}

impl IgnoreLine {
    pub fn hidden_files(&self) -> usize {
        self.hidden.iter().filter(|h| !h.is_dir).count()
    }

    pub fn hidden_folders(&self) -> usize {
        self.hidden.iter().filter(|h| h.is_dir).count()
    }

    /// A rule or negation that decides nothing (no path git sees matches it,
    /// or a later line always wins).
    pub fn unused(&self) -> bool {
        matches!(self.kind, LineKind::Rule | LineKind::Negation)
            && self.hidden.is_empty()
            && self.tracked.is_empty()
            && self.reincluded == 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IgnoreSource {
    pub kind: SourceKind,
    /// The folder a `.gitignore` sits in (repo-relative; empty for the root
    /// one and for the other kinds).
    pub dir: PathBuf,
    /// Absolute path.
    pub file: PathBuf,
    /// As shown: `.gitignore`, `src/.gitignore`, `info/exclude`, or the
    /// global file's path.
    pub name: String,
    pub exists: bool,
    pub lines: Vec<IgnoreLine>,
}

impl IgnoreSource {
    pub fn new(kind: SourceKind, dir: PathBuf, file: PathBuf, name: String) -> Self {
        Self {
            kind,
            dir,
            file,
            name,
            exists: false,
            lines: Vec::new(),
        }
    }

    /// Where rules added to this source go.
    pub fn target(&self) -> IgnoreTarget {
        match self.kind {
            SourceKind::Root | SourceKind::Nested => IgnoreTarget::Shared {
                dir: self.dir.clone(),
            },
            SourceKind::Local => IgnoreTarget::Local,
            SourceKind::Global => IgnoreTarget::Global,
        }
    }

    /// Paths this file hides (folders count once).
    pub fn hidden_count(&self) -> usize {
        self.lines.iter().map(|l| l.hidden.len()).sum()
    }

    pub fn tracked_count(&self) -> usize {
        self.lines.iter().map(|l| l.tracked.len()).sum()
    }
}

/// One record of `git check-ignore -v -n -z`: the line that decides `path`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IgnoreMatch {
    /// As git names the file: repo-relative for a `.gitignore`, else as
    /// configured or found (relative or absolute).
    pub source: String,
    pub line: usize,
    pub pattern: String,
    pub path: PathBuf,
}

impl IgnoreMatch {
    /// The line ignores the path (rather than bringing it back with `!`).
    pub fn ignores(&self) -> bool {
        !self.pattern.starts_with('!')
    }
}

/// The ignore state of a worktree, from
/// [`crate::runtime::Runtime::load_ignore_rules`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct IgnoreRules {
    /// The root `.gitignore` (listed even when missing), the nested ones by
    /// path, `info/exclude`, then the global file when git has one.
    pub sources: Vec<IgnoreSource>,
    /// Every untracked path git ignores, sorted, with the source and line
    /// (indices) that ignore it.
    pub ignored: Vec<(HiddenPath, Option<(usize, usize)>)>,
    by_path: HashMap<PathBuf, usize>,
}

impl IgnoreRules {
    /// Builds the model. `sources` come with their contents (`None` for a
    /// missing file); `ignored` is `ls-files -o -i --directory` (folders with
    /// a trailing `/`); `matches` holds `check-ignore -v` for the ignored
    /// paths, the tracked files that match a rule, and the untracked files
    /// (for negations); `tracked` lists the tracked ones.
    pub fn build(
        sources: Vec<(IgnoreSource, Option<Vec<u8>>)>,
        ignored: &[PathBuf],
        matches: &[IgnoreMatch],
        tracked: &[PathBuf],
    ) -> Self {
        let mut rules = Self {
            sources: sources
                .into_iter()
                .map(|(mut source, contents)| {
                    source.exists = contents.is_some();
                    source.lines = parse_lines(contents.as_deref().unwrap_or_default());
                    source
                })
                .collect(),
            ..Self::default()
        };
        let by_path: HashMap<String, &IgnoreMatch> =
            matches.iter().map(|m| (slash(&m.path), m)).collect();
        let tracked: std::collections::HashSet<String> = tracked.iter().map(|p| slash(p)).collect();
        // A folder whose files are ignored by rules of their own is listed
        // along with them, and no line ignores the folder itself: skip it.
        let mut entries: Vec<HiddenPath> = Vec::new();
        for raw in ignored {
            let text = raw.to_string_lossy().replace('\\', "/");
            let is_dir = text.ends_with('/');
            let path = text.trim_end_matches('/').to_owned();
            let found = by_path
                .get(&path)
                .or_else(|| by_path.get(&format!("{path}/")));
            if is_dir && found.is_none() {
                continue;
            }
            entries.push(HiddenPath {
                path: PathBuf::from(path),
                is_dir,
            });
        }
        entries.sort_by(|a, b| a.path.cmp(&b.path));
        for entry in entries {
            let key = slash(&entry.path);
            let at = by_path
                .get(&key)
                .or_else(|| by_path.get(&format!("{key}/")))
                .and_then(|m| rules.locate(m).map(|line| (line, m.ignores())));
            let decided = at.filter(|(_, ignores)| *ignores).map(|(at, _)| at);
            if let Some((source, line)) = decided {
                rules.sources[source].lines[line].hidden.push(entry.clone());
            }
            rules
                .by_path
                .insert(entry.path.clone(), rules.ignored.len());
            rules.ignored.push((entry, decided));
        }
        let mut sorted: Vec<&IgnoreMatch> = matches.iter().collect();
        sorted.sort_by(|a, b| a.path.cmp(&b.path));
        for m in sorted {
            let key = slash(&m.path);
            let Some((source, line)) = rules.locate(m) else {
                continue;
            };
            let target = &mut rules.sources[source].lines[line];
            if tracked.contains(&key) {
                if m.ignores() {
                    target.tracked.push(PathBuf::from(key));
                }
            } else if !m.ignores() {
                target.reincluded += 1;
            }
        }
        rules
    }

    /// The source and line of a `check-ignore` record.
    fn locate(&self, m: &IgnoreMatch) -> Option<(usize, usize)> {
        let source = self.source_index(&m.source)?;
        let line = m.line.checked_sub(1)?;
        (line < self.sources[source].lines.len()).then_some((source, line))
    }

    fn source_index(&self, name: &str) -> Option<usize> {
        let name = name.replace('\\', "/");
        let kind = if Path::new(&name).is_absolute() || name.starts_with('/') {
            if name.ends_with("/info/exclude") {
                SourceKind::Local
            } else {
                SourceKind::Global
            }
        } else if name == ".gitignore" || name.ends_with("/.gitignore") {
            let dir = parent(&name);
            return self.sources.iter().position(|s| {
                matches!(s.kind, SourceKind::Root | SourceKind::Nested) && slash(&s.dir) == dir
            });
        } else if name.ends_with("info/exclude") {
            SourceKind::Local
        } else {
            SourceKind::Global
        };
        self.sources.iter().position(|s| s.kind == kind)
    }

    /// The source and line that ignore `path` (an entry of [`Self::ignored`]).
    pub fn ignored_by(&self, path: &Path) -> Option<(usize, usize)> {
        self.ignored[*self.by_path.get(path)?].1
    }

    pub fn source(&self, index: usize) -> Option<&IgnoreSource> {
        self.sources.get(index)
    }

    pub fn line(&self, source: usize, line: usize) -> Option<&IgnoreLine> {
        self.sources.get(source)?.lines.get(line)
    }

    /// The root `.gitignore`.
    pub fn root(&self) -> Option<&IgnoreSource> {
        self.sources.iter().find(|s| s.kind == SourceKind::Root)
    }

    /// The ignored entries as status rows, for "Show ignored files".
    pub fn status_rows(&self) -> impl Iterator<Item = crate::repo::FileChange> + '_ {
        self.ignored
            .iter()
            .map(|(entry, _)| crate::repo::FileChange {
                path: entry.path.clone(),
                original_path: None,
                state: FileState::Ignored,
                score: None,
                submodule: false,
                index_mode: None,
                index_oid: None,
            })
    }
}

/// The lines of an ignore file, numbered as git numbers them (a UTF-8 BOM
/// is skipped).
pub fn parse_lines(contents: &[u8]) -> Vec<IgnoreLine> {
    let contents = contents.strip_prefix(b"\xef\xbb\xbf").unwrap_or(contents);
    if contents.is_empty() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(contents);
    let text = text.strip_suffix('\n').unwrap_or(&text);
    text.split('\n')
        .enumerate()
        .map(|(i, line)| {
            let line = line.trim_end_matches('\r');
            let trimmed = line.trim();
            let kind = if trimmed.is_empty() {
                LineKind::Blank
            } else if line.starts_with('#') {
                LineKind::Comment
            } else if line.starts_with('!') {
                LineKind::Negation
            } else {
                LineKind::Rule
            };
            IgnoreLine {
                number: i + 1,
                text: line.to_owned(),
                kind,
                hidden: Vec::new(),
                tracked: Vec::new(),
                reincluded: 0,
            }
        })
        .collect()
}

/// Parses `git check-ignore -v -n -z` (`source\0line\0pattern\0path\0`
/// records), dropping the paths no line matches.
pub fn parse_check_ignore(output: &[u8]) -> Vec<IgnoreMatch> {
    let fields: Vec<&[u8]> = output.split(|&b| b == 0).collect();
    fields
        .as_chunks::<4>()
        .0
        .iter()
        .filter(|f| !f[0].is_empty())
        .filter_map(|f| {
            Some(IgnoreMatch {
                source: String::from_utf8_lossy(f[0]).into_owned(),
                line: std::str::from_utf8(f[1]).ok()?.parse().ok()?,
                pattern: String::from_utf8_lossy(f[2]).into_owned(),
                path: crate::repo::git_path(f[3]),
            })
        })
        .collect()
}

/// How to stop ignoring a path, from the line that ignores it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Unignore {
    /// The line names exactly this path: remove it.
    RemoveLine,
    /// Add this `!` line to the target (after the rule, so it wins).
    Negate { target: IgnoreTarget, line: String },
}

/// What Stop ignoring does for `entry`, ignored by `line` of `source`.
/// Rules in the global file are negated in `info/exclude`, which wins over
/// it, so other repositories are not touched.
pub fn unignore(source: &IgnoreSource, line: &IgnoreLine, entry: &HiddenPath) -> Unignore {
    let dir = slash(&source.dir);
    let path = slash(&entry.path);
    let rel = relative(&path, &dir).unwrap_or_else(|| path.clone());
    // A pattern with a `/` (other than a trailing one) is anchored to its
    // file's folder; one without matches the name in every folder below.
    let pattern = line.text.trim_end().trim_end_matches('/');
    let exact = pattern.contains('/') && pattern.trim_start_matches('/') == escape_path(&rel);
    if exact && source.kind != SourceKind::Global {
        return Unignore::RemoveLine;
    }
    let (target, rel) = match source.kind {
        SourceKind::Global => (IgnoreTarget::Local, path),
        _ => (source.target(), rel),
    };
    let slash_end = if entry.is_dir { "/" } else { "" };
    Unignore::Negate {
        target,
        line: format!("!/{}{slash_end}", escape_path(&rel)),
    }
}

/// The rule lines of `template` that `contents` (the root `.gitignore`)
/// lacks, in the template's order, one per line.
pub fn template_missing(template: &str, contents: &[u8]) -> String {
    let text = String::from_utf8_lossy(contents);
    let have: Vec<&str> = text
        .lines()
        .map(|l| l.trim_end_matches('\r').trim_end())
        .collect();
    let mut out: Vec<&str> = Vec::new();
    for line in template.lines() {
        let line = line.trim_end_matches('\r').trim_end();
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        if !have.contains(&line) && !out.contains(&line) {
            out.push(line);
        }
    }
    out.join("\n")
}

/// Folder names that hold build output or dependencies, suggested as soon
/// as status shows files in them.
const OUTPUT_FOLDERS: &[&str] = &[
    ".godot",
    ".gradle",
    ".import",
    ".mypy_cache",
    ".next",
    ".pytest_cache",
    ".venv",
    "__pycache__",
    "bin",
    "build",
    "dist",
    "node_modules",
    "obj",
    "target",
    "venv",
];

/// Untracked files a folder needs before it is suggested when its name is
/// not a known output folder (and it must hold most of the changes).
pub const HINT_MIN_FILES: usize = 50;

/// A folder of untracked files worth ignoring: one named like build output
/// or dependencies, or one holding at least [`HINT_MIN_FILES`] and most of
/// the changes. Returns the folder (repo-relative) and how many untracked
/// files it holds.
pub fn folder_hint(status: &RepoStatus) -> Option<(PathBuf, usize)> {
    let untracked: Vec<String> = status
        .changes
        .iter()
        .filter(|c| c.state == FileState::Untracked)
        .map(|c| slash(&c.path))
        .collect();
    let changes = status
        .changes
        .iter()
        .filter(|c| c.state != FileState::Ignored)
        .count();
    // Shallowest known output folder first.
    let mut known: HashMap<String, usize> = HashMap::new();
    for path in &untracked {
        let parts: Vec<&str> = path.split('/').collect();
        if let Some(at) = parts[..parts.len() - 1]
            .iter()
            .position(|p| OUTPUT_FOLDERS.contains(p))
        {
            *known.entry(parts[..=at].join("/")).or_default() += 1;
        }
    }
    if let Some((folder, count)) = known
        .into_iter()
        .min_by(|a, b| (a.0.matches('/').count(), &a.0).cmp(&(b.0.matches('/').count(), &b.0)))
    {
        return Some((PathBuf::from(folder), count));
    }
    let mut top: HashMap<&str, usize> = HashMap::new();
    for path in &untracked {
        if let Some(at) = path.find('/') {
            *top.entry(&path[..at]).or_default() += 1;
        }
    }
    top.into_iter()
        .filter(|(_, n)| *n >= HINT_MIN_FILES && *n * 2 > changes)
        .max_by(|a, b| a.1.cmp(&b.1).then(b.0.cmp(a.0)))
        .map(|(folder, n)| (PathBuf::from(folder), n))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::repo::FileChange;

    fn source(
        kind: SourceKind,
        dir: &str,
        name: &str,
        contents: &str,
    ) -> (IgnoreSource, Option<Vec<u8>>) {
        (
            IgnoreSource::new(
                kind,
                PathBuf::from(dir),
                PathBuf::from(format!("/r/{name}")),
                name.to_owned(),
            ),
            Some(contents.as_bytes().to_vec()),
        )
    }

    fn m(source: &str, line: usize, pattern: &str, path: &str) -> IgnoreMatch {
        IgnoreMatch {
            source: source.into(),
            line,
            pattern: pattern.into(),
            path: path.into(),
        }
    }

    #[test]
    fn parses_lines_with_kinds() {
        let lines = parse_lines(b"\xef\xbb\xbf*.log\r\n# note\r\n\r\n!keep.log\r\n  \r\n/build/");
        let kinds: Vec<&str> = lines.iter().map(|l| l.kind.id()).collect();
        assert_eq!(
            kinds,
            ["rule", "comment", "blank", "negation", "blank", "rule"]
        );
        assert_eq!(lines[0].text, "*.log");
        assert_eq!(lines[5].number, 6);
        assert_eq!(parse_lines(b"a\n").len(), 1);
        assert!(parse_lines(b"").is_empty());
    }

    #[test]
    fn parses_check_ignore_records() {
        let out = b".gitignore\x001\x00*.log\x00a.log\x00\x00\x00\x00zzz\x00C:/u/ignore\x003\x00*.bak\x00d/z \xc3\xa9.bak\x00";
        let matches = parse_check_ignore(out);
        assert_eq!(matches.len(), 2);
        assert_eq!(matches[0], m(".gitignore", 1, "*.log", "a.log"));
        assert_eq!(matches[1].path, PathBuf::from("d/z é.bak"));
        assert_eq!(matches[1].line, 3);
    }

    #[test]
    fn attributes_paths_to_lines() {
        let rules = IgnoreRules::build(
            vec![
                source(
                    SourceKind::Root,
                    "",
                    ".gitignore",
                    "*.log\n# c\n/build/\n!keep.log\nunused/\n",
                ),
                source(SourceKind::Nested, "src", "src/.gitignore", "*.tmp\n"),
                source(SourceKind::Local, "", "info/exclude", "# git\ndocs/\n"),
                source(SourceKind::Global, "", "C:/u/ignore", "*.bak\n"),
            ],
            &[
                "a.log".into(),
                "build/".into(),
                "docs/".into(),
                "mix/".into(),
                "mix/1.log".into(),
                "mix/2.bak".into(),
                "src/t.tmp".into(),
            ],
            &[
                m(".gitignore", 1, "*.log", "a.log"),
                m(".gitignore", 3, "/build/", "build/"),
                m(".git/info/exclude", 2, "docs/", "docs/"),
                m(".gitignore", 1, "*.log", "mix/1.log"),
                m("C:/u/ignore", 1, "*.bak", "mix/2.bak"),
                m("src/.gitignore", 1, "*.tmp", "src/t.tmp"),
                m(".gitignore", 1, "*.log", "tracked.log"),
                m(".gitignore", 4, "!keep.log", "keep.log"),
            ],
            &["tracked.log".into()],
        );
        let root = &rules.sources[0];
        assert_eq!(root.lines[0].hidden_files(), 2);
        assert_eq!(root.lines[0].tracked, [PathBuf::from("tracked.log")]);
        assert_eq!(root.lines[2].hidden_folders(), 1);
        assert_eq!(root.lines[3].reincluded, 1);
        assert!(!root.lines[3].unused());
        assert!(root.lines[4].unused());
        assert!(!root.lines[1].unused(), "comments are never unused");
        assert_eq!(root.hidden_count(), 3);
        assert_eq!(rules.sources[1].hidden_count(), 1);
        assert_eq!(rules.sources[2].lines[1].hidden_folders(), 1);
        assert_eq!(rules.sources[3].hidden_count(), 1);
        // The unattributed `mix/` is left out; its files are listed.
        let paths: Vec<&Path> = rules
            .ignored
            .iter()
            .map(|(e, _)| e.path.as_path())
            .collect();
        assert_eq!(
            paths,
            [
                Path::new("a.log"),
                Path::new("build"),
                Path::new("docs"),
                Path::new("mix/1.log"),
                Path::new("mix/2.bak"),
                Path::new("src/t.tmp")
            ]
        );
        assert_eq!(rules.ignored_by(Path::new("mix/2.bak")), Some((3, 0)));
        assert_eq!(rules.ignored_by(Path::new("build")), Some((0, 2)));
        assert_eq!(rules.status_rows().count(), 6);
    }

    #[test]
    fn locates_local_exclude_from_a_linked_worktree() {
        let rules = IgnoreRules::build(
            vec![
                source(SourceKind::Root, "", ".gitignore", ""),
                source(SourceKind::Local, "", "info/exclude", "docs/\n"),
            ],
            &["docs/".into()],
            &[m("C:/r/.git/info/exclude", 1, "docs/", "docs/")],
            &[],
        );
        assert_eq!(rules.ignored_by(Path::new("docs")), Some((1, 0)));
    }

    fn line(text: &str) -> IgnoreLine {
        parse_lines(text.as_bytes()).remove(0)
    }

    fn entry(path: &str, is_dir: bool) -> HiddenPath {
        HiddenPath {
            path: path.into(),
            is_dir,
        }
    }

    #[test]
    fn stop_ignoring_removes_an_exact_line_or_negates() {
        let (root, _) = source(SourceKind::Root, "", ".gitignore", "");
        assert_eq!(
            unignore(&root, &line("/build/"), &entry("build", true)),
            Unignore::RemoveLine
        );
        assert_eq!(
            unignore(&root, &line("/a b.log"), &entry("a b.log", false)),
            Unignore::RemoveLine
        );
        assert_eq!(
            unignore(&root, &line("logs/x.log"), &entry("logs/x.log", false)),
            Unignore::RemoveLine
        );
        let negate = |line: &str| Unignore::Negate {
            target: IgnoreTarget::Shared {
                dir: PathBuf::new(),
            },
            line: line.into(),
        };
        // `x.log` at the root also ignores `x.log` in every folder.
        assert_eq!(
            unignore(&root, &line("x.log"), &entry("x.log", false)),
            negate("!/x.log")
        );
        assert_eq!(
            unignore(&root, &line("*.log"), &entry("logs/a.log", false)),
            negate("!/logs/a.log")
        );
        assert_eq!(
            unignore(&root, &line("target/"), &entry("crate/target", true)),
            negate("!/crate/target/")
        );
        let (nested, _) = source(SourceKind::Nested, "src", "src/.gitignore", "");
        assert_eq!(
            unignore(&nested, &line("/t.tmp"), &entry("src/t.tmp", false)),
            Unignore::RemoveLine
        );
        assert_eq!(
            unignore(&nested, &line("*.tmp"), &entry("src/a/[x].tmp", false)),
            Unignore::Negate {
                target: IgnoreTarget::Shared { dir: "src".into() },
                line: "!/a/\\[x].tmp".into()
            }
        );
        let (global, _) = source(SourceKind::Global, "", "C:/u/ignore", "");
        assert_eq!(
            unignore(&global, &line("/z.bak"), &entry("z.bak", false)),
            Unignore::Negate {
                target: IgnoreTarget::Local,
                line: "!/z.bak".into()
            }
        );
    }

    #[test]
    fn lists_missing_template_lines() {
        let template = "# Godot\n.godot/\n\n*.translation\n!keep\n.godot/\n";
        assert_eq!(
            template_missing(template, b".godot/\r\n"),
            "*.translation\n!keep"
        );
        assert_eq!(
            template_missing(template, b".godot/\n*.translation\n!keep\n"),
            ""
        );
    }

    fn status(untracked: &[String], modified: usize) -> RepoStatus {
        let mut status = RepoStatus::default();
        let change = |path: String, state| FileChange {
            path: path.into(),
            original_path: None,
            state,
            score: None,
            submodule: false,
            index_mode: None,
            index_oid: None,
        };
        for path in untracked {
            status
                .changes
                .push(change(path.clone(), FileState::Untracked));
        }
        for i in 0..modified {
            status.changes.push(change(
                format!("m{i}.txt"),
                FileState::Tracked {
                    index: crate::repo::Change::Unmodified,
                    worktree: crate::repo::Change::Modified,
                },
            ));
        }
        status
    }

    #[test]
    fn hints_at_output_folders() {
        let paths = |prefix: &str, n: usize| -> Vec<String> {
            (0..n).map(|i| format!("{prefix}/f{i}")).collect()
        };
        let known = status(
            &[paths("game/.godot/imported", 2), vec!["a.txt".into()]].concat(),
            30,
        );
        assert_eq!(folder_hint(&known), Some((PathBuf::from("game/.godot"), 2)));
        let shallow = status(
            &[paths("a/node_modules/x", 3), paths("node_modules/y", 1)].concat(),
            0,
        );
        assert_eq!(
            folder_hint(&shallow),
            Some((PathBuf::from("node_modules"), 1))
        );
        let big = status(&paths("assets", HINT_MIN_FILES), 10);
        assert_eq!(
            folder_hint(&big),
            Some((PathBuf::from("assets"), HINT_MIN_FILES))
        );
        let few = status(&paths("assets", HINT_MIN_FILES - 1), 0);
        assert_eq!(folder_hint(&few), None);
        let mostly_edits = status(&paths("assets", HINT_MIN_FILES), HINT_MIN_FILES);
        assert_eq!(folder_hint(&mostly_edits), None);
    }
}
