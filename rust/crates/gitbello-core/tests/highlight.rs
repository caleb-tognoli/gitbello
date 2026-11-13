//! Golden tests for syntax highlighting: every `tests/highlight/<id>/sample.*`
//! is lexed and compared with the `.tokens` file next to it. Set
//! `GITBELLO_BLESS=1` (or run `cargo xtask bless-highlight`) to rewrite
//! them, then review the change in the diff.

use std::fs;
use std::path::{Path, PathBuf};

use gitbello_core::highlight::{
    detect, dump, Language, LineState, LineStates, Syntax, Token, TokenKind, MAX_LEXED_CHARS,
};

fn samples_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/highlight")
}

/// The sample files, one folder per language.
fn samples() -> Vec<PathBuf> {
    let mut out = Vec::new();
    for dir in fs::read_dir(samples_dir()).expect("samples folder") {
        let dir = dir.expect("entry").path();
        if !dir.is_dir() {
            continue;
        }
        for file in fs::read_dir(&dir).expect("language folder") {
            let file = file.expect("entry").path();
            let is_sample = file
                .file_name()
                .is_some_and(|n| n.to_string_lossy().starts_with("sample"));
            if is_sample && file.extension().is_none_or(|e| e != "tokens") {
                out.push(file);
            }
        }
    }
    out.sort();
    out
}

fn tokens_path(sample: &Path) -> PathBuf {
    let mut name = sample.file_name().expect("name").to_os_string();
    name.push(".tokens");
    sample.with_file_name(name)
}

/// The first differing line of `expected` and `got`, for the failure message.
fn first_difference(expected: &str, got: &str) -> String {
    let (e, g): (Vec<&str>, Vec<&str>) = (expected.lines().collect(), got.lines().collect());
    let at = (0..e.len().max(g.len()))
        .find(|&i| e.get(i) != g.get(i))
        .unwrap_or(0);
    let from = at.saturating_sub(3);
    let show = |lines: &[&str]| -> String {
        lines
            .iter()
            .enumerate()
            .skip(from)
            .take(at - from + 4)
            .map(|(i, l)| format!("{:>4} {l}\n", i + 1))
            .collect()
    };
    format!(
        "first difference at line {}\n--- expected\n{}--- got\n{}",
        at + 1,
        show(&e),
        show(&g)
    )
}

#[test]
fn samples_match_expected_tokens() {
    let bless = std::env::var_os("GITBELLO_BLESS").is_some();
    let samples = samples();
    assert!(!samples.is_empty(), "no samples found");
    let mut failures = Vec::new();
    for sample in &samples {
        let language =
            detect(sample, None).unwrap_or_else(|| panic!("no language for {}", sample.display()));
        assert_eq!(
            sample.parent().and_then(Path::file_name),
            Some(std::ffi::OsStr::new(language.id())),
            "{} is in the folder of another language",
            sample.display()
        );
        let text = fs::read(sample).expect("read sample");
        // Samples are compared as LF text whatever the checkout did.
        let text: Vec<u8> = text.into_iter().filter(|&b| b != b'\r').collect();
        let got = dump(language, &text);
        let path = tokens_path(sample);
        if bless {
            fs::write(&path, &got).expect("write tokens");
            continue;
        }
        let expected = fs::read_to_string(&path)
            .unwrap_or_default()
            .replace('\r', "");
        if expected != got {
            failures.push(format!(
                "{}: {}",
                sample.display(),
                first_difference(&expected, &got)
            ));
        }
    }
    assert!(
        failures.is_empty(),
        "tokens changed (rerun with GITBELLO_BLESS=1 if intended):\n{}",
        failures.join("\n")
    );
}

/// Kinds no lexer produces yet (empty since M7.13 P3); a kind produced by
/// a sample must not be listed.
const NOT_YET_PRODUCED: &[TokenKind] = &[];

#[test]
fn every_language_has_a_sample_and_every_kind_is_produced() {
    let samples = samples();
    let mut produced = std::collections::HashSet::new();
    for language in Language::all() {
        let sample = samples
            .iter()
            .find(|s| {
                s.parent().and_then(Path::file_name) == Some(std::ffi::OsStr::new(language.id()))
            })
            .unwrap_or_else(|| panic!("{} has no sample", language.id()));
        let text = fs::read_to_string(sample).expect("read sample");
        let lines: Vec<String> = text.lines().map(str::to_owned).collect();
        let syntax = Syntax::new(Some(language), &lines);
        for line in &lines {
            produced.extend(syntax.highlight(line).into_iter().map(|t| t.kind));
        }
    }
    let mut problems = Vec::new();
    for kind in TokenKind::ALL {
        let waiting = NOT_YET_PRODUCED.contains(&kind);
        let made = produced.contains(&kind);
        if !made && !waiting {
            problems.push(format!("no sample produces {}", kind.name()));
        }
        if made && waiting {
            problems.push(format!(
                "{} is produced now: drop it from NOT_YET_PRODUCED",
                kind.name()
            ));
        }
    }
    assert!(
        problems.is_empty(),
        "{}",
        problems.join(
            "
"
        )
    );
}

/// A small seeded generator, so the random lines are the same every run.
struct Lines(u64);

impl Lines {
    fn next(&mut self) -> u64 {
        // xorshift64*
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }

    fn below(&mut self, n: usize) -> usize {
        usize::try_from(self.next() % u64::try_from(n).expect("small n")).expect("below n")
    }

    /// A line of up to 40 pieces drawn mostly from what lexers react to.
    fn line(&mut self) -> String {
        const PIECES: &[&str] = &[
            "\"", "'", "`", "\\", "/", "*", "/*", "*/", "//", "#", "--", ";", "$", "${", "{", "}",
            "(", ")", "[", "]", "<", ">", "@", "!", "%", "&", "|", "=", ":", ",", ".", "..", "0",
            "1.5", "0x1F", "e3", "_", "fn", "let", "if", "True", "None", "Type", "x", " ", "  ",
            "\t", "é", "日本", "🦀", "\u{feff}", "```", "> ", "- ", "[[",
        ];
        let pieces = self.below(40);
        (0..pieces)
            .map(|_| PIECES[self.below(PIECES.len())])
            .collect()
    }
}

#[test]
fn random_lines_give_sorted_tokens_inside_the_line() {
    let mut random = Lines(0x9e37_79b9_7f4a_7c15);
    for language in Language::all() {
        let syntax = Syntax::new(Some(language), &[]);
        for _ in 0..3000 {
            let line = random.line();
            let length = line.chars().count();
            let tokens = syntax.highlight(&line);
            let mut at = 0;
            for token in &tokens {
                assert!(
                    token.start >= at && token.end > token.start && token.end <= length,
                    "{}: {token:?} after {at} in {line:?} ({length} chars)",
                    language.id()
                );
                at = token.end;
            }
        }
        // Lines past the lexing limit are cut there.
        let long = format!("\"{}", "a \" ".repeat(MAX_LEXED_CHARS));
        let tokens = syntax.highlight(&long);
        assert!(
            tokens.iter().all(|t| t.end <= MAX_LEXED_CHARS),
            "{}",
            language.id()
        );
    }
}

/// Openers and closers of what goes on across lines, for the random texts.
const MULTI_LINE_PIECES: &[&str] = &[
    "\"\"\"",
    "'''",
    "<<EOF",
    "<<-'T'",
    "EOF",
    "T",
    "=begin",
    "=end",
    "<!--",
    "-->",
    "|",
    ">-",
    "[==[",
    "]==]",
    "--[[",
    "]]",
    "<![CDATA[",
    "]]>",
    "@\"",
    "\"@",
    "r#\"",
    "\"#",
    "<<<X",
    "X;",
    "<a b='",
    "/**",
    "*/",
    "<script>",
    "<script type=\"application/json\">",
    "</script>",
    "<style>",
    "</style>",
    "<?php",
    "<?=",
    "?>",
    "```js",
    "~~~",
    "```",
    "@{",
    "@code {",
    "@if (x)",
    "{",
    "}",
    "@*",
    "*@",
    "<li>",
    "</li>",
    "@:",
    "script/source = \"",
];

impl Lines {
    /// A text of up to 12 lines, mixing [`Lines::line`] with multi-line
    /// openers and closers at either end of a line.
    fn text(&mut self) -> Vec<String> {
        (0..1 + self.below(12))
            .map(|_| {
                let mut line = self.line();
                if self.below(2) == 0 {
                    line.insert_str(0, MULTI_LINE_PIECES[self.below(MULTI_LINE_PIECES.len())]);
                }
                if self.below(2) == 0 {
                    line.push_str(MULTI_LINE_PIECES[self.below(MULTI_LINE_PIECES.len())]);
                }
                line
            })
            .collect()
    }
}

/// The tokens of each line of `lines`, lexed in one pass from the first.
fn whole_pass(syntax: &Syntax, lines: &[String]) -> Vec<Vec<Token>> {
    let mut state = LineState::default();
    lines
        .iter()
        .map(|line| {
            let (tokens, next) = syntax.highlight_line_next(line.as_bytes(), state);
            state = next;
            tokens
        })
        .collect()
}

/// The tokens of each line of `lines`, each lexed alone from the state
/// [`LineStates`] kept for it.
fn from_kept_states(syntax: &Syntax, lines: &[String]) -> Vec<Vec<Token>> {
    let states = LineStates::compute(syntax, lines.iter().map(String::as_bytes), || false)
        .expect("not stopped");
    assert_eq!(states.line_count(), lines.len());
    lines
        .iter()
        .enumerate()
        .map(|(i, line)| syntax.highlight_line_from(line.as_bytes(), states.before(i)))
        .collect()
}

#[test]
fn lexing_from_a_kept_state_matches_lexing_from_the_start() {
    let mut random = Lines(0x2545_f491_4f6c_dd1d);
    for language in Language::all() {
        let syntax = Syntax::new(Some(language), &[]);
        for _ in 0..400 {
            let lines = random.text();
            let whole = whole_pass(&syntax, &lines);
            assert_eq!(
                whole,
                from_kept_states(&syntax, &lines),
                "{}: {lines:?}",
                language.id()
            );
            for (line, tokens) in lines.iter().zip(&whole) {
                let length = gitbello_core::diff::display_text(line.as_bytes())
                    .chars()
                    .count();
                let mut at = 0;
                for token in tokens {
                    assert!(
                        token.start >= at && token.end > token.start && token.end <= length,
                        "{}: {token:?} after {at} in {line:?} of {lines:?}",
                        language.id()
                    );
                    at = token.end;
                }
            }
        }
    }
    // The samples too, as whole files.
    for sample in samples() {
        let language = detect(&sample, None).expect("language");
        let text = fs::read_to_string(&sample).expect("read sample");
        let lines: Vec<String> = text.lines().map(str::to_owned).collect();
        let syntax = Syntax::new(Some(language), &lines);
        assert_eq!(
            whole_pass(&syntax, &lines),
            from_kept_states(&syntax, &lines),
            "{}",
            sample.display()
        );
    }
}
