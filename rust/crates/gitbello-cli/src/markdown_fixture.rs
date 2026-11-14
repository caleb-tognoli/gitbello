//! The Markdown repository `fixture --markdown` adds: `markdown`, for the
//! smoke test and screenshots of the diff's Preview mode.
//!
//! Two commits: `README.md` with every kind of block, then an edit of it
//! (a reworded sentence, a ticked task, a table row changed, a code line
//! changed, a paragraph added). The working tree edits it again (a heading
//! renamed, a quote reworded, a list item added, a paragraph removed) and
//! adds the untracked `docs/guide.md`; `notes.txt` changes too (no preview).
//! Every version ends with a section that draws `docs/logo.png` (a square
//! the second commit recolours), a missing picture and a web one, and links
//! to the guide and to its own heading.

use std::fs;
use std::path::Path;

use anyhow::Result;

use crate::fixture::Git;
use crate::image_fixture::png;

const FIRST: &str = r#"# gitbello

A fast Git client for **many repositories** and worktrees.

## Features

- Browse history with a *graph*
- Stage lines and hunks
  - with the keyboard
- [ ] Markdown preview
- [x] Image diffs

> Keep large data in Rust; Godot asks
> for the rows it shows.

| Platform | Status |
|:---------|-------:|
| Windows  | ready  |
| Linux    | beta   |

```rust
fn main() {
    println!("hello");
}
```

Old paragraph that the working copy removes.

---

See the [plan](docs/PLAN.md) and https://example.com for more.

## Logo

![The logo](docs/logo.png) ![Missing](docs/missing.png) ![Web](https://example.com/a.png)

Read the [guide](docs/guide.md) or go back to [the logo](#logo).
"#;

const SECOND: &str = r#"# gitbello

A fast, open-source Git client for **many repositories** and worktrees.

## Features

- Browse history with a *graph*
- Stage lines and hunks
  - with the keyboard
- [x] Markdown preview
- [x] Image diffs

> Keep large data in Rust; Godot asks
> for the rows it shows.

| Platform | Status |
|:---------|-------:|
| Windows  | ready  |
| Linux    | ready  |

```rust
fn main() {
    println!("hello, world");
}
```

Old paragraph that the working copy removes.

Releases are built for every platform from one tag.

---

See the [plan](docs/PLAN.md) and https://example.com for more.

## Logo

![The logo](docs/logo.png) ![Missing](docs/missing.png) ![Web](https://example.com/a.png)

Read the [guide](docs/guide.md) or go back to [the logo](#logo).
"#;

const WORKING: &str = r#"# gitbello

A fast, open-source Git client for **many repositories** and worktrees.

## What it does

- Browse history with a *graph*
- Stage lines and hunks
  - with the keyboard
- [x] Markdown preview
- [x] Image diffs
- Compare branches side by side

> Keep large data in Rust; Godot only asks
> for the rows it draws.

| Platform | Status |
|:---------|-------:|
| Windows  | ready  |
| Linux    | ready  |

```rust
fn main() {
    println!("hello, world");
}
```

Releases are built for every platform from one tag.

---

See the [plan](docs/PLAN.md) and https://example.com for more.

## Logo

![The logo](docs/logo.png) ![Missing](docs/missing.png) ![Web](https://example.com/a.png)

Read the [guide](docs/guide.md) or go back to [the logo](#logo).
"#;

const GUIDE: &str = "# Guide\n\n1. Open a repository\n2. Pick a file\n\nThat is all.\n";

pub fn build(git: &Git<'_>, dir: &Path) -> Result<()> {
    let repo = dir.join("markdown");
    fs::create_dir_all(repo.join("docs"))?;
    git.run(&repo, &["init", "--quiet", "--initial-branch=main"], None)?;
    git.run(&repo, &["config", "core.autocrlf", "false"], None)?;
    let put = |file: &str, content: &str| fs::write(repo.join(file), content);
    put("README.md", FIRST)?;
    put("notes.txt", "one\ntwo\n")?;
    fs::write(repo.join("docs/logo.png"), logo([66, 135, 245, 255]))?;
    git.run(&repo, &["add", "--all"], None)?;
    git.run(
        &repo,
        &["commit", "--quiet", "-F", "-"],
        Some("Add the readme"),
    )?;
    put("README.md", SECOND)?;
    fs::write(repo.join("docs/logo.png"), logo([245, 130, 48, 255]))?;
    git.run(&repo, &["add", "--all"], None)?;
    git.run(
        &repo,
        &["commit", "--quiet", "-F", "-"],
        Some("Update the readme"),
    )?;
    put("README.md", WORKING)?;
    put("notes.txt", "one\nthree\n")?;
    put("docs/guide.md", GUIDE)?;
    Ok(())
}

/// A 48×48 rounded square in `color` with a light ring.
fn logo(color: [u8; 4]) -> Vec<u8> {
    png(48, 48, |x, y| {
        let (dx, dy) = (x.abs_diff(24), y.abs_diff(24));
        let d = dx * dx + dy * dy;
        if dx > 22 || dy > 22 {
            [0, 0, 0, 0]
        } else if (100..=196).contains(&d) {
            [250, 250, 250, 255]
        } else {
            color
        }
    })
}
