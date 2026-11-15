# Syntax highlighting

Hand-written lexers in core (no crate), cheap to extend: a language is one file plus one registry line, a token kind is one enum entry plus optional palette colours. Highlighting runs everywhere code is drawn: diff rows (Changes, History, Shelves, Compare, File history), the blame, the conflict resolver and the minimap.

Not offered: user configuration of any kind (mappings, custom languages, colours), a toggle or per-file language override, bold/italic, `.gitattributes` `linguist-language`, glob or prefix names (`Dockerfile.dev`), Vue/Svelte/Astro/ERB/Jinja and other template languages, CMake, Perl, a CSV table mode.

## Core layout

`gitbello-core/src/highlight/`:
- `mod.rs`: `Token`, `LineState`, `FileHints`, `Syntax { language, hints }` (`Syntax::new`, `highlight_line(bytes)`, `highlight_line_from(bytes, state)`).
- `lexer.rs`: `trait Lexer: Sync { fn lex(&self, cx: &mut Cx) }`. `Cx` holds the line's chars, the hints and the state, and offers `push(start, end, kind)` (drops empty tokens and cuts overlaps, so tokens stay sorted and disjoint), `starts_with`, `at_line_start`, `state`/`set_state`, the shared scanners, `embed(language, start, end)`, `embed_with(lexer, …)` for a lexer that is not a registered language, `embed_open(tag, lexer, start, end, resume)` / `embed_open_mapped` for embedded code that continues on the next line, `nested()`, `token_count`/`truncate`, and `plain_strings_since(mark)`.
- `scan.rs`: identifiers (Unicode), numbers (hex/octal/binary prefixes, `_` and `'` separators, signed exponents, suffixes like `u8`, `f32`, `L`, `n`; a `.` belongs to a number only before a digit, so `0..10` keeps its range operator), strings with escapes and prefixes, comments.
- `generic.rs`: the declarative `Spec` lexer: control keywords, constants, builtin types, `name(` as a function, `definitions` (the word after `fn`/`def`/`class`… as function or type), ALL_CAPS constants, `macros` (`name!`), `attributes` (`#[…]`, `[[…]]`), `line_attributes` (C# `[…]`), `doc_blocks`, `regex_literals`, `case_insensitive`, `constructors` (Dart), `keys`, `Str` rules (escape `None`/`With`/`Doubled`, interpolations embedding a language, doubled braces, `$name`, Rust-style hashed raw strings, `lines` for multi-line strings), a per-language `hook` and `resume`. `SpecLexer` builds its word tables once per language. `generic::outside_code` walks code past strings and comments.
- `languages/`: one file per language or family, each a `LanguageDef { id, name, extensions, file_names, shebangs, lexer }`; `languages::ALL` is the registry. `Language` is a `Copy` handle (`id()`, `name()`).
- `detect.rs`: `detect(path, first_line)`: exact file name (case-insensitive), then extension, then the shebang (`#!/usr/bin/env -S python3`, `#!/bin/bash`, versions stripped). Binary or unreadable → plain.
- `hints.rs`: `FileHints`, settings derived once per file (the CSV delimiter: the candidate `,` `;` tab `|`, outside quotes, that splits the most of the first 200 lines into the same number of fields, ties in that order; `.tsv`/`.tab` always tab).
- `kind.rs`: `TokenKind`.
- `states.rs`: `LineStates`, `DiffStates`.

Detection runs in the diff job (`JobOutput::Diff.syntax`) and is stored on `DiffState`/`ConflictState` with the hints: the first line comes from the diff when a hunk starts at line 1, else from the working file's first 256 bytes, else from the blob's (`Backend::blob_head`, which defaults to `None` so test backends need nothing).

Only the first 10,000 characters of a line are lexed (minified files); the rest is plain. Lines are lexed with their tabs; tokens map to display columns (tab width 4).

## Token kinds

Each kind has a stable name and a parent it falls back to (`TokenKind::ALL`, `COUNT`, `id`, `name`, `parent`; parents come before children), so a new kind needs no GDScript change. Base kinds: `keyword`, `type`, `function`, `variable`, `constant`, `string`, `number`, `comment`, `key`, `tag`, `attribute`, `operator`, `punctuation`, `annotation`, `markup.heading`, `markup.emphasis`, `markup.link`, `diff.added`, `diff.removed`, `diff.header`, `column.0` … `column.7`. Derived kinds (parent in brackets): `keyword.control` (keyword), `macro` (function), `comment.doc` (comment), `string.escape` (string), `string.interpolation` (string.escape), `regex` (string), `markup.code` (string), `markup.quote` (comment), `markup.list` (punctuation). A kind can resolve to plain text: `function`, `operator` and `punctuation` do in both palettes.

## Line states

`LineState` is small and `Copy`: a stack of four `(language, state)` frames; a lexer packs what it needs into its 16 bits (a Rust raw string's `#` count, a Lua level, a Razor brace depth, a heredoc terminator's 12-bit hash). Embedding pushes a frame, so a `<script>` block inside PHP inside HTML fits.

- A text is lexed once from its first line; `LineStates` keeps only the lines that do not start in the start state (`(line, LineState)` pairs, a binary search to look up), so a file without open constructs costs nothing. `DiffStates` holds both sides by line number (a removed line by its old number, others by the new one); `ConflictFile::line_states` walks the resolver's file (theirs and the base from the state before the block, after it from the end of ours). `MiniLine` carries its line's state.
- The states come from a `read line states` job (interactive, after the diff job, per slot by generation; the conflict's by content hash). It reads the old blob (and hands it to the gaps, so it is not read twice) and the working file for working-copy kinds or the new blob otherwise. A new side shorter than the diff's last hunk is dropped. Until the job lands rows draw each line from the start state; a reload keeps the previous states meanwhile. `diff_info.states` is `none`, `loading`, `ready` or `skipped` (over 16 MB, a failed read, a binary side).
- Multi-line constructs: block comments (C family, Rust, Go, Swift, Kotlin, Java, C#, Dart, JS/TS, CSS/SCSS/LESS, GLSL, Godot shader, SQL, PHP), Lua `--[[ ]]`, Ruby `=begin`/`=end`, PowerShell `<# #>`, HTML/XML `<!-- -->` and CDATA; multi-line strings (Python and GDScript triple quotes, JS/TS template literals, Rust strings and raw strings, Go raw strings, C# verbatim and raw strings, Java/Kotlin/Swift/Dart `"""`, TOML, Lua `[[ ]]`, SQL quotes); heredocs (shell with `<<-`, Ruby, PHP heredocs and nowdocs); YAML block scalars (by indentation); tags whose attributes span lines; CSV quoted fields.
- Mixed files: HTML `<script>` (JavaScript; JSON for a `json` type; other types plain) and `<style>` across lines; PHP files start as HTML and `<?php`, `<?=` and `<? ` switch to PHP until a `?>` outside strings and block comments; Razor (`.razor`, `.cshtml`; HTML host, `@* *@`, directives, `@{ }` / `@code` / `@functions` / statement bodies as C# code blocks whose `<tag>` lines are markup until the element closes, `@:` lines, implicit and explicit expressions, component attributes); Markdown fenced code in the fence's language by id, alias (`js`, `ts`, `py`, `sh`, `cs`, `rb`, `yml`, `ps1`, `bat`, `cshtml`, …) or extension; Godot resources' `script/source = "…"` as GDScript with escapes undone; Dockerfile `RUN`/`CMD`/`ENTRYPOINT` shell forms and Makefile recipes as Shell.
- Interpolation within a line: JS/TS `${…}`, Python f-strings, shell `$(…)`/`${…}`/`$var`, Kotlin/Dart `$x`/`${…}`, C# `$"{…}"`, Ruby `#{…}`, PHP `"$x"`, Swift `\(…)`, Rust format placeholders in `name!(` string arguments; HTML `style="…"` as CSS declarations and `on…="…"` as JS.

## Languages

43 in `languages::ALL` (ids): `rust`, `gdscript`, `python`, `javascript`, `typescript`, `c`, `cpp` (`.h` is C++), `csharp`, `java`, `kotlin`, `swift`, `go` (also `go.mod`), `dart`, `zig`, `glsl` (GLSL and HLSL), `godot_shader`, `godot_resource` (`.tscn .tres .godot .import .gdextension`), `json` (comments accepted, keys as `key`), `toml`, `yaml`, `ini`, `dotenv`, `csv`, `tsv`, `sql`, `xml` (also `.svg`, `.csproj`, `.xaml`, `.plist`, `.resx`, …), `html`, `css`, `scss`, `less`, `markdown`, `shell`, `powershell`, `batch`, `lua`, `ruby`, `php`, `razor`, `dockerfile`, `makefile`, `ignore` (`.gitignore`, `.dockerignore`, …), `gitattributes`, `diff` (`.diff .patch .rej`). Each file in `gitbello-core/src/highlight/languages/` lists its extensions, file names and shebangs.

To add a language: one file in `languages/`, a line in `languages::ALL` and a `tests/highlight/<id>/sample.<ext>`.

## Colours

- `app_theme.gd` defines `syntax_<name>` colours (dots become underscores) for the base kinds in the dark and light palettes. `DiffView` and `DiffMinimap` build their colour table from `RepoSession.syntax_kinds()`, walking the parent chain once when the theme changes (`AppTheme.syntax_colors`); the minimap's `MinimapPalette.syntax` is a list indexed by kind id.
- **Quiet palette:** strings sand, variables and tags orange, numbers, constants and attribute names rose-magenta, macros and headings blue, doc comments the comment grey; keywords, types, keys, annotations and escapes their own hues. No red or green outside `diff.added`/`diff.removed` (patch files), since green and red collide with the added/removed line colours and are the pair red-green colour blindness confuses. Function names (definitions and calls) are plain text. CSV/TSV columns cycle blue, orange, purple, sand, cyan, rose, yellow, then plain.
- **Data values plain:** in TOML, YAML, JSON, INI, `.env`, Godot resources and XML attribute values, string values are plain text (`Cx::plain_strings_since`), so data files are not a wall of one colour; keys, section headers, tags, attribute names, numbers, booleans and null keep their colours. Code files, HTML attributes and Markdown keep coloured strings.
- **Readable on every background:** `AppTheme.readable(color, background, target = 4.5)` keeps a colour that reaches the target; otherwise it keeps its OKLCH hue and as much chroma as sRGB holds, and moves its lightness towards white or black by a binary search to the least that reaches it. `AppTheme.diff_backgrounds(control)` names the 16 backgrounds the view draws text on (unchanged, added, removed, added and removed words, ours, theirs, base, and the selection over each); `syntax_color_tables(control)` gives each its table. `DiffView` caches a table per background colour it meets, splits each syntax segment at the changed-word and selection edges and draws each piece from its background's table. Unchanged lines keep the theme's colours. The minimap keeps its own colours.
- **Changed-word tint:** `AppTheme.word_tint_percent` (40), chosen from `word_tint_sheet` so changed words keep their hues in both themes.
- Line numbers, the hunk expanders and the conflict cards keep their own colours.

## Tests and tools

- **Samples:** `gitbello-core/tests/highlight/<language id>/sample.<ext>` per language, lexed as whole files, with `sample.<ext>.tokens` next to it: each source line followed by caret lines (`   ^^^^ function`), regenerated by `cargo xtask bless-highlight` and reviewed in the diff. The test fails on any change, when a registered language has no sample, or when a kind is produced by no sample.
- **Properties:** for every language, thousands of seeded random lines (mixing in script, style, PHP, fence and Razor openers): tokens sorted, non-overlapping, inside the line, no panic; states stay inside their frames; lexing from a kept state gives the same tokens as lexing from the start.
- **Detection:** names, extensions and shebangs (`env -S`, versions, CRLF, BOM), paths with spaces and non-ASCII characters, and runtime tests on temp repos (`tests/syntax_detection.rs`, `tests/line_states.rs`).
- **Smoke:** `syntax_smoke.gd` checks every kind and plain text on every background in both themes, also with chosen added/removed colours at the extremes Settings allows (`KNOWN_SHORT` stays empty).
- **Tools:** `gitbello-cli highlight <file> [--language <id>]`, `gitbello-cli highlight-bench [<dir>]`, `gitbello-cli fixture <dir> --syntax`, and the `syntax_sheet` and `word_tint_sheet` scenes (AGENTS.md).
- Budget: ≤ 1 ms per 100 lines of typical code, ≤ 5 ms for a 10,000-character line, states within 100 ms of the diff for files up to 10,000 lines; measured numbers in [perf.md](perf.md).

## Known rough edges

- CSS `color:red` without a space and `;`, or a bare value continuation line, reads as a selector; LESS `.@{name}-icon` loses `.` and `-icon`; Postgres `$$` strings are plain; `html` in `<!DOCTYPE html>` shows as an attribute.
- Ruby `a ? b :c` reads `:c` as a symbol; a `"` string in Ruby, PHP and the shell runs on when its closer is missing (as an editor shows it).
- HTML's state across a PHP island is lost at a line's end; Razor's explicit `@( … )` and attribute values do not go on across lines; `@<p>…</p>` templates and generic `@Foo<T>()` calls are not read; a `do { … }` block's `while` is read only on the line of its `}`.
- Kotlin constructors read as functions; C# PascalCase constants and properties as types; PowerShell `$env:NAME` in strings colours only `$env`.
