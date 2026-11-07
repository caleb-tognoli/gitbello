//! Ignore rules (M7.7, `docs/IGNORE_RULES.md`): the rules the Changes view
//! offers for a file, the form `git ls-files -x` previews them in, and the
//! edits that add a rule to an ignore file or take it back.
//!
//! Paths are repository-relative and `/`-separated, as status reports them.
//! A rule's pattern may hold several lines (one per selected file); each is
//! written as one line of the target file.

use std::path::{Path, PathBuf};

use crate::changes::IndexEntry;

mod rules;

pub use rules::{
    folder_hint, parse_check_ignore, parse_lines, template_missing, unignore, HiddenPath,
    IgnoreLine, IgnoreMatch, IgnoreRules, IgnoreSource, LineKind, SourceKind, Unignore,
    HINT_MIN_FILES,
};

/// Where a rule is written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IgnoreTarget {
    /// A `.gitignore`; `dir` is its repo-relative folder (empty for the root one).
    Shared { dir: PathBuf },
    /// `info/exclude` in the common git dir: this computer, every worktree.
    Local,
    /// The user's `core.excludesFile` (every repository of this user).
    Global,
}

impl IgnoreTarget {
    /// The folder the target's patterns are relative to (the root for
    /// `info/exclude` and the global file).
    pub fn dir(&self) -> &Path {
        match self {
            Self::Shared { dir } => dir,
            Self::Local | Self::Global => Path::new(""),
        }
    }

    /// The file the target writes; `global` is the user's excludes file
    /// (see [`crate::backend::GitBackend::global_excludes_file`]).
    pub fn file(
        &self,
        toplevel: &Path,
        common_dir: &Path,
        global: Option<&Path>,
    ) -> Option<PathBuf> {
        match self {
            Self::Shared { dir } => Some(toplevel.join(dir).join(".gitignore")),
            Self::Local => Some(common_dir.join("info").join("exclude")),
            Self::Global => global.map(Path::to_owned),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IgnoreRule {
    /// As written, relative to the target's folder; one rule per line.
    pub pattern: String,
    pub target: IgnoreTarget,
}

impl IgnoreRule {
    /// The rule lines (blank lines dropped, trailing `\r` trimmed).
    pub fn lines(&self) -> Vec<&str> {
        self.pattern
            .lines()
            .map(|l| l.trim_end_matches('\r'))
            .filter(|l| !l.trim().is_empty())
            .collect()
    }
}

/// What to do with tracked files the rule matches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Untrack {
    /// Leave them tracked.
    Keep,
    /// Stop tracking them (`git rm --cached`), keeping them on disk.
    Remove,
    /// Write nothing and fail with [`crate::git::GitErrorKind::TrackedMatches`]
    /// when there are any (the quick entries, which leave that choice to the dialog).
    RefuseIfTracked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SuggestionKind {
    /// Exactly these paths.
    File,
    /// The file's name, in any folder.
    Name,
    /// Every file with the extension.
    Extension,
    /// Files with the extension in the files' folder and below.
    ExtensionBelow,
    /// A folder above the files (`level` 0 is the nearest).
    Folder,
}

impl SuggestionKind {
    pub fn id(self) -> &'static str {
        match self {
            Self::File => "file",
            Self::Name => "name",
            Self::Extension => "extension",
            Self::ExtensionBelow => "extension_below",
            Self::Folder => "folder",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Suggestion {
    pub kind: SuggestionKind,
    pub pattern: String,
    /// What the label names: "hero.import", "*.import", "assets/".
    pub subject: String,
    /// Folder level (0 = nearest); 0 for the other kinds.
    pub level: u32,
}

/// Something to point out about a pattern before it is written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PatternWarning {
    /// No rule lines (only blanks or comments).
    Empty,
    /// A line like `*` or `/` that ignores the whole folder.
    MatchesEverything,
    /// A `!` line: git cannot re-include a file whose folder is excluded.
    Negation,
}

impl PatternWarning {
    pub fn id(self) -> &'static str {
        match self {
            Self::Empty => "empty",
            Self::MatchesEverything => "matches_everything",
            Self::Negation => "negation",
        }
    }
}

/// What a rule would do, from [`crate::runtime::Runtime::load_ignore_preview`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IgnorePreview {
    pub rule: IgnoreRule,
    /// Every line is already in the target file.
    pub exists: bool,
    pub warning: Option<PatternWarning>,
    /// Changes that would leave the Changes list (untracked files it matches).
    pub hidden_count: usize,
    pub hidden_sample: Vec<PathBuf>,
    /// Tracked files the rule matches (they stay tracked unless untracked).
    pub tracked_count: usize,
    pub tracked_sample: Vec<PathBuf>,
}

/// What [`crate::runtime::Runtime::undo_ignore`] needs to take a rule back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IgnoreUndo {
    pub file: PathBuf,
    /// The file before the rule (`None`: it did not exist).
    pub before: Option<Vec<u8>>,
    pub after: Vec<u8>,
    /// Whether the file was written (not when only files were untracked).
    pub wrote: bool,
    /// The lines the rule added (none when a line was removed).
    pub lines: Vec<String>,
    /// Index entries of the files it stopped tracking.
    pub index_entries: Vec<IndexEntry>,
    /// Repo-relative paths to include in the commit once status shows them
    /// (the `.gitignore` and the untracked files, after untracking).
    pub picks: Vec<PathBuf>,
    /// The global excludes file was edited (every repository reads it).
    pub everywhere: bool,
}

/// Paths listed in a preview at most, per list.
pub const PREVIEW_SAMPLE: usize = 50;

/// Names too common to ignore everywhere by name alone.
const COMMON_NAMES: &[&str] = &[
    ".gitignore",
    ".gitattributes",
    "__init__.py",
    "build.rs",
    "cargo.toml",
    "index.html",
    "index.js",
    "index.ts",
    "lib.rs",
    "license",
    "main.rs",
    "mod.rs",
    "package.json",
    "readme.md",
];

/// The rules offered for `paths` (repo-relative), written relative to `dir`
/// (the target's folder, which holds every path), narrowest first: the files,
/// their name, their extension everywhere and below their folder, then each
/// folder above them up to `dir`.
pub fn suggestions(paths: &[PathBuf], dir: &Path) -> Vec<Suggestion> {
    let dir = slash(dir);
    let rel: Vec<String> = paths
        .iter()
        .filter_map(|p| relative(&slash(p), &dir))
        .collect();
    if rel.is_empty() || rel.len() != paths.len() {
        return Vec::new();
    }
    let mut out = Vec::new();
    let names: Vec<&str> = rel.iter().map(|p| file_name(p)).collect();
    out.push(Suggestion {
        kind: SuggestionKind::File,
        pattern: rel
            .iter()
            .map(|p| format!("/{}", escape_path(p)))
            .collect::<Vec<_>>()
            .join("\n"),
        subject: if rel.len() == 1 {
            names[0].to_owned()
        } else {
            String::new()
        },
        level: 0,
    });
    let same_name = names.iter().all(|n| *n == names[0]);
    let nested = rel.iter().any(|p| p.contains('/'));
    if same_name && nested && !COMMON_NAMES.contains(&names[0].to_lowercase().as_str()) {
        out.push(Suggestion {
            kind: SuggestionKind::Name,
            pattern: escape(names[0]),
            subject: names[0].to_owned(),
            level: 0,
        });
    }
    let folders: Vec<&str> = rel.iter().map(|p| parent(p)).collect();
    let common = common_folder(&folders);
    if let Some(ext) = shared_extension(&names) {
        let subject = format!("*.{ext}");
        out.push(Suggestion {
            kind: SuggestionKind::Extension,
            pattern: format!("*.{}", escape(ext)),
            subject: subject.clone(),
            level: 0,
        });
        if !common.is_empty() {
            out.push(Suggestion {
                kind: SuggestionKind::ExtensionBelow,
                pattern: format!("/{}/**/*.{}", escape_path(&common), escape(ext)),
                subject,
                level: 0,
            });
        }
    }
    let mut folder = common.as_str();
    let mut level = 0;
    while !folder.is_empty() {
        out.push(Suggestion {
            kind: SuggestionKind::Folder,
            pattern: format!("/{}/", escape_path(folder)),
            subject: format!("{}/", file_name(folder)),
            level,
        });
        folder = parent(folder);
        level += 1;
    }
    out
}

/// `name` escaped for a pattern: glob characters and backslashes, trailing
/// spaces, and a leading `#` or `!`.
pub fn escape(name: &str) -> String {
    let trailing = name.len() - name.trim_end_matches(' ').len();
    let body = &name[..name.len() - trailing];
    let mut out = String::with_capacity(name.len() + 2);
    if body.starts_with('#') || body.starts_with('!') {
        out.push('\\');
    }
    for c in body.chars() {
        if matches!(c, '*' | '?' | '[' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    for _ in 0..trailing {
        out.push_str("\\ ");
    }
    out
}

/// Each component of a `/`-separated path escaped.
fn escape_path(path: &str) -> String {
    path.split('/').map(escape).collect::<Vec<_>>().join("/")
}

/// The `git ls-files -x` patterns, from the repository root, that match what
/// `rule` hides once written. A nested `.gitignore`'s rules get its folder in
/// front, and since `ls-files -x` does not apply a folder pattern to the files
/// inside it, each pattern also comes with `/**`. Comments and `!` lines
/// match nothing here.
pub fn match_form(rule: &IgnoreRule) -> Vec<String> {
    let dir = slash(rule.target.dir());
    let prefix = if dir.is_empty() {
        String::new()
    } else {
        format!("{}/", escape_path(&dir))
    };
    let mut out = Vec::new();
    for line in rule.lines() {
        let line = trim_unescaped_spaces(line);
        if line.starts_with('#') || line.starts_with('!') || line.is_empty() {
            continue;
        }
        let dir_only = line.ends_with('/') && !line.ends_with("\\/");
        let body = line.trim_end_matches('/');
        if body.is_empty() {
            continue;
        }
        let anchored = body.contains('/');
        let body = body.trim_start_matches('/');
        let base = if anchored {
            format!("/{prefix}{body}")
        } else {
            format!("/{prefix}**/{body}")
        };
        if !dir_only {
            out.push(base.clone());
        }
        out.push(format!("{base}/**"));
    }
    out
}

/// Strips the trailing spaces git ignores (those not escaped with `\`).
fn trim_unescaped_spaces(line: &str) -> &str {
    let mut end = line.len();
    while end > 0 && line.as_bytes()[end - 1] == b' ' {
        if end >= 2 && line.as_bytes()[end - 2] == b'\\' {
            break;
        }
        end -= 1;
    }
    &line[..end]
}

/// What to point out about `pattern` before writing it.
pub fn check(pattern: &str) -> Option<PatternWarning> {
    let lines: Vec<&str> = pattern
        .lines()
        .map(|l| trim_unescaped_spaces(l.trim_end_matches('\r')))
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .collect();
    if lines.is_empty() {
        return Some(PatternWarning::Empty);
    }
    if lines
        .iter()
        .any(|l| matches!(*l, "*" | "/" | "**" | "/*" | "/**" | "*/" | "**/"))
    {
        return Some(PatternWarning::MatchesEverything);
    }
    if lines.iter().any(|l| l.starts_with('!')) {
        return Some(PatternWarning::Negation);
    }
    None
}

/// The lines of `rule` that `contents` (an ignore file) lacks.
pub fn missing_lines<'a>(contents: &[u8], rule: &'a IgnoreRule) -> Vec<&'a str> {
    let text = String::from_utf8_lossy(contents);
    let have: Vec<&str> = text.lines().map(|l| l.trim_end_matches('\r')).collect();
    let mut out: Vec<&str> = Vec::new();
    for line in rule.lines() {
        if !have.contains(&line) && !out.contains(&line) {
            out.push(line);
        }
    }
    out
}

/// `contents` with `lines` appended, in the file's line endings (CRLF when it
/// already uses them), after a newline if the last line lacks one.
pub fn append_lines(contents: &[u8], lines: &[&str]) -> Vec<u8> {
    let eol: &[u8] = if contents.windows(2).any(|w| w == b"\r\n") {
        b"\r\n"
    } else {
        b"\n"
    };
    let mut out = contents.to_vec();
    if out.last().is_some_and(|b| *b != b'\n') {
        out.extend_from_slice(eol);
    }
    for line in lines {
        out.extend_from_slice(line.as_bytes());
        out.extend_from_slice(eol);
    }
    out
}

/// `contents` without the last occurrence of each of `lines`, or `None` when
/// one of them is no longer there.
pub fn remove_lines(contents: &[u8], lines: &[String]) -> Option<Vec<u8>> {
    let text = String::from_utf8_lossy(contents);
    let mut kept: Vec<&str> = text.split_inclusive('\n').collect();
    for line in lines.iter().rev() {
        let at = kept
            .iter()
            .rposition(|l| l.trim_end_matches('\n').trim_end_matches('\r') == line)?;
        kept.remove(at);
    }
    Some(kept.concat().into_bytes())
}

/// `path` with `/` separators and no leading or trailing ones.
fn slash(path: &Path) -> String {
    path.to_string_lossy()
        .replace('\\', "/")
        .trim_matches('/')
        .to_owned()
}

/// `path` relative to folder `dir` (both `/`-separated), if inside it.
fn relative(path: &str, dir: &str) -> Option<String> {
    if dir.is_empty() {
        return Some(path.to_owned());
    }
    path.strip_prefix(dir)?
        .strip_prefix('/')
        .filter(|rest| !rest.is_empty())
        .map(str::to_owned)
}

fn file_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn parent(path: &str) -> &str {
    path.rfind('/').map_or("", |at| &path[..at])
}

/// The deepest folder holding every one of `folders`.
fn common_folder(folders: &[&str]) -> String {
    let Some(first) = folders.first() else {
        return String::new();
    };
    let mut common: Vec<&str> = first.split('/').filter(|s| !s.is_empty()).collect();
    for folder in &folders[1..] {
        let parts: Vec<&str> = folder.split('/').filter(|s| !s.is_empty()).collect();
        let same = common
            .iter()
            .zip(&parts)
            .take_while(|(a, b)| a == b)
            .count();
        common.truncate(same);
    }
    common.join("/")
}

/// The extension every name shares (after the last dot; dotfiles like
/// `.env` have none).
fn shared_extension<'a>(names: &[&'a str]) -> Option<&'a str> {
    let ext = |name: &'a str| -> Option<&'a str> {
        let at = name.rfind('.')?;
        (at > 0 && at + 1 < name.len()).then(|| &name[at + 1..])
    };
    let first = ext(names.first()?)?;
    names.iter().all(|n| ext(n) == Some(first)).then_some(first)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(list: &[&str]) -> Vec<PathBuf> {
        list.iter().map(PathBuf::from).collect()
    }

    fn patterns(list: &[Suggestion]) -> Vec<(&'static str, &str)> {
        list.iter()
            .map(|s| (s.kind.id(), s.pattern.as_str()))
            .collect()
    }

    fn rule(pattern: &str, dir: &str) -> IgnoreRule {
        IgnoreRule {
            pattern: pattern.to_owned(),
            target: IgnoreTarget::Shared { dir: dir.into() },
        }
    }

    #[test]
    fn suggests_file_name_extension_and_each_folder() {
        let list = suggestions(&paths(&["src/game/assets/hero.import"]), Path::new(""));
        assert_eq!(
            patterns(&list),
            vec![
                ("file", "/src/game/assets/hero.import"),
                ("name", "hero.import"),
                ("extension", "*.import"),
                ("extension_below", "/src/game/assets/**/*.import"),
                ("folder", "/src/game/assets/"),
                ("folder", "/src/game/"),
                ("folder", "/src/"),
            ]
        );
        assert_eq!(list[4].subject, "assets/");
        assert_eq!(list[6].level, 2);
        assert_eq!(list[2].subject, "*.import");
    }

    #[test]
    fn a_root_file_has_no_folders_and_no_separate_name() {
        let list = suggestions(&paths(&["notes.txt"]), Path::new(""));
        assert_eq!(
            patterns(&list),
            vec![("file", "/notes.txt"), ("extension", "*.txt")]
        );
    }

    #[test]
    fn common_names_and_dotfiles() {
        let list = suggestions(&paths(&["web/package.json"]), Path::new(""));
        assert!(!list.iter().any(|s| s.kind == SuggestionKind::Name));
        let list = suggestions(&paths(&["app/.env"]), Path::new(""));
        assert_eq!(
            patterns(&list),
            vec![("file", "/app/.env"), ("name", ".env"), ("folder", "/app/")]
        );
    }

    #[test]
    fn several_files() {
        let list = suggestions(&paths(&["a/b/x.log", "a/c/y.log"]), Path::new(""));
        assert_eq!(
            patterns(&list),
            vec![
                ("file", "/a/b/x.log\n/a/c/y.log"),
                ("extension", "*.log"),
                ("extension_below", "/a/**/*.log"),
                ("folder", "/a/"),
            ]
        );
        let mixed = suggestions(&paths(&["a/x.log", "b/y.txt"]), Path::new(""));
        assert_eq!(patterns(&mixed), vec![("file", "/a/x.log\n/b/y.txt")]);
    }

    #[test]
    fn relative_to_a_nested_gitignore() {
        let list = suggestions(&paths(&["src/game/hero.import"]), Path::new("src"));
        assert_eq!(
            patterns(&list),
            vec![
                ("file", "/game/hero.import"),
                ("name", "hero.import"),
                ("extension", "*.import"),
                ("extension_below", "/game/**/*.import"),
                ("folder", "/game/"),
            ]
        );
        assert!(suggestions(&paths(&["other/x.txt"]), Path::new("src")).is_empty());
    }

    #[test]
    fn escapes_special_names() {
        assert_eq!(escape("#notes"), "\\#notes");
        assert_eq!(escape("!important"), "\\!important");
        assert_eq!(escape("a[1]*?.txt"), "a\\[1]\\*\\?.txt");
        assert_eq!(escape("back\\slash"), "back\\\\slash");
        assert_eq!(escape("trailing  "), "trailing\\ \\ ");
        assert_eq!(escape("mid space"), "mid space");
        assert_eq!(escape("città é.txt"), "città é.txt");
        let list = suggestions(&paths(&["dir [x]/#a b.txt"]), Path::new(""));
        assert_eq!(list[0].pattern, "/dir \\[x]/\\#a b.txt");
    }

    #[test]
    fn match_forms() {
        assert_eq!(match_form(&rule("/u/", "")), vec!["/u/**"]);
        assert_eq!(match_form(&rule("v/", "")), vec!["/**/v/**"]);
        assert_eq!(
            match_form(&rule("*.log", "")),
            vec!["/**/*.log", "/**/*.log/**"]
        );
        assert_eq!(
            match_form(&rule("*.x", "src")),
            vec!["/src/**/*.x", "/src/**/*.x/**"]
        );
        assert_eq!(
            match_form(&rule("/a/b.txt", "src")),
            vec!["/src/a/b.txt", "/src/a/b.txt/**"]
        );
        assert_eq!(
            match_form(&rule("# note\n!keep.log\n\nbuild/ ", "")),
            vec!["/**/build/**"]
        );
        let local = IgnoreRule {
            pattern: "/out/".into(),
            target: IgnoreTarget::Local,
        };
        assert_eq!(match_form(&local), vec!["/out/**"]);
    }

    #[test]
    fn warnings() {
        assert_eq!(check(""), Some(PatternWarning::Empty));
        assert_eq!(check("# only a comment\n"), Some(PatternWarning::Empty));
        assert_eq!(check("*"), Some(PatternWarning::MatchesEverything));
        assert_eq!(
            check("/build/\n/**"),
            Some(PatternWarning::MatchesEverything)
        );
        assert_eq!(check("!keep.log"), Some(PatternWarning::Negation));
        assert_eq!(check("*.log"), None);
    }

    #[test]
    fn appends_in_the_files_line_endings() {
        let r = rule("*.log\n/out/", "");
        assert_eq!(append_lines(b"", &r.lines()), b"*.log\n/out/\n");
        assert_eq!(append_lines(b"a\nb", &["c"]), b"a\nb\nc\n");
        assert_eq!(append_lines(b"a\r\nb\r\n", &["c"]), b"a\r\nb\r\nc\r\n");
        assert_eq!(append_lines(b"a\r\nb", &["c"]), b"a\r\nb\r\nc\r\n");
    }

    #[test]
    fn missing_and_removed_lines() {
        let r = rule("*.log\n/out/\n*.log", "");
        assert_eq!(
            missing_lines(b"/out/\r\nnode_modules/\r\n", &r),
            vec!["*.log"]
        );
        assert!(missing_lines(b"*.log\n/out/\n", &r).is_empty());
        let lines = vec!["*.log".to_owned(), "/out/".to_owned()];
        assert_eq!(
            remove_lines(b"a\n*.log\nb\n*.log\n/out/\n", &lines).as_deref(),
            Some(&b"a\n*.log\nb\n"[..])
        );
        assert_eq!(
            remove_lines(b"x\r\n*.log\r\n/out/\r\n", &lines).as_deref(),
            Some(&b"x\r\n"[..])
        );
        assert_eq!(remove_lines(b"a\n*.log\n", &lines), None);
    }
}
