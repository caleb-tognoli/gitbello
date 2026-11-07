# Performance log

Graph benchmarks recorded with `cargo xtask bench-graph <repo> [--ui] --record`.
Benchmarks only read the repository. Targets are in PLAN §3.9.

## M1 summary (2026-10-24, git/git, 85,790 commits)

Machine: Windows 11, 20 threads, NVIDIA RTX 4070, 170 Hz display. git 2.53.0, Godot 4.7.1, Rust 1.99.1.

| Target (PLAN §3.9) | Result | Status |
|---|---|---|
| Full index < 2 s | 0.81 s (0.94 s with commit-graph) | met |
| First screen < 300 ms | 98–105 ms with a commit-graph file; 630–645 ms without | met only with commit-graph (see below) |
| < 150 bytes/commit in the index (excluding strings) | 58.5 bytes/commit (4.8 MiB) + 4.1 MiB strings | met |
| 60 fps scrolling, no dropped frames | Row-by-row: p99 8.6 ms, max 9–15 ms. Page per frame (fling): p99 11–12 ms, max 18–19 ms in 1–2 of 300 frames | met for normal scrolling; a 1–2 frame miss under extreme flinging |
| Idle CPU near 0% | 0.23 CPU-s over 20 s with git/git loaded (≈1.2% of one core, 0.06% of the machine) | met |

Other numbers: a 50-row slice (lanes replayed from the nearest checkpoint plus commit fields) takes 44 µs on average and 124 µs at most in core. The UI fetches 160 rows per window in 2.3 ms on average. The app's private memory is ~171 MB with git/git loaded.

**First screen without a commit-graph.** `git log --topo-order` has to walk the whole history before it prints the first commit unless `.git/objects/info/commit-graph` exists. A fresh `git clone` doesn't write one, but `git gc`, `git maintenance` and `fetch.writeCommitGraph` do. gitbello can't make git stream sooner. Options are in the M1 review.

**Lane width.** git/git's `--all` history keeps up to 164 lanes open at once: maint and seen merges of topics forked from old bases. That's the real topology. The UI draws at most `GraphView/constants/max_lanes` (24) and clips the rest.

## Raw runs

### 2026-10-24 · windows x86_64 · 20 threads Intel64 Family 6 Model 151 Stepping 2, GenuineIntel

```text
repo            git/git (fresh clone, no commit-graph)
git             2.53.0
commits         85790
first page      638.8 ms (100 rows)
full index      814.6 ms
wall            815.8 ms
max lanes       164
index memory    4.78 MiB (58.5 bytes/commit, target < 150)
string memory   4.12 MiB
50-row slice    avg 44.5 us, max 110.8 us (400 samples)

scroll benchmark (Godot 4.7.1.stable.official.a13da4feb, debug library)
rows 85790
refresh_hz 170
frames 600
dropped_frames 6
row_frame_ms_p50 6.98
row_draw_us_p50 1481
row_frame_ms_p99 8.25
row_draw_us_p99 1976
row_frame_ms_max 8.53
row_draw_us_max 5680
page_frame_ms_p50 7.01
page_draw_us_p50 3422
page_frame_ms_p99 8.97
page_draw_us_p99 6800
page_frame_ms_max 18.14
page_draw_us_max 15956
fetches 104
fetch_us_p50 2293
fetch_us_max 2970
static_memory_mb 54.8
```

### 2026-10-24 · windows x86_64 · 20 threads Intel64 Family 6 Model 151 Stepping 2, GenuineIntel

```text
repo            <temp mirror of git/git with commit-graph>
git             2.53.0
commits         85790
first page      100.0 ms (100 rows)
full index      956.6 ms
wall            956.8 ms
max lanes       164
index memory    4.78 MiB (58.5 bytes/commit, target < 150)
string memory   4.12 MiB
50-row slice    avg 44.2 us, max 209.7 us (400 samples)
```

## M4a — diffs and change lists

Debug build of `gitbello-cli` (core at opt-level 2), Windows, git 2.53.0, temp repo.
`gitbello-cli diff <root> <file> [--full]` and `GITBELLO_LOG=1 gitbello-cli status <root>`.

```text
diff, 20k-line file, 1 in 3 lines changed   26,668 lines   36 ms (git + parse)
diff, 50k-line file, every line changed     100,001 lines  63 ms with --full
same file without --full                    stops at the 2 MiB limit after 49 ms
status, 10,000 untracked files              42 ms
```

The change lists and the diff view fetch only a window around the visible rows
(`change_rows`, `diff_lines`), so list length does not change frame cost.

## M4b — diff view rendering

`godot --path godot res://tests/perf/diff_bench.tscn -- --repo=<root> --file=<path>`
(windowed, debug gdext, RTX 4070, 144 Hz display). Temp repo with a
24,000-line Rust file, 4,000 changed line pairs; syntax and changed-word
highlights on.

```text
diff load (git + parse + pairing)      69 ms
unified fetch, 300 rows                p50 1.3 ms, max 1.5 ms
side-by-side fetch, 300 rows           p50 2.7 ms, max 3.0 ms
paging through the diff, frame time    p50 6.98 ms, p99 8.29 ms, max 8.41 ms
```

Line staging round trip (core test `random_selections_stage_exactly_what_was_picked`,
30 rounds of diff + patch + `git apply --check` + apply + unstage): 11 s in total,
about 0.35 s per round including fixture commits.


## M7.5 — Home

`gitbello-cli home-bench <folder> [--depth N] [--max N]` (read-only) scans a
folder the way Scan folder… does, then reads up to 50 summaries through the
runtime as Home does (`SUMMARY_JOBS` = 2 at a time). Release build, git
2.53.0.windows.3, Windows, 2026-10-31:

```text
50 fixture repositories (plus their 50 bare origins), depth 1
scan     100 repositories (50 not bare) in 304.4 ms
summary  50 of 50 in 2031 ms, first after 78 ms, 81 ms each

C:\caleb\dev, depth 3 (real repositories, gitbello's own included)
scan     14 repositories (13 not bare) in 3.1 ms
summary  13 of 13 in 872 ms, first after 93 ms, 134 ms each
```

Home only asks for the rows and cards on screen, a screenful at a time, and
each status arrives on its own, so the first rows fill in within ~100 ms.

## M6.5 P5 — history search

`gitbello-cli graph-bench <repo>` (read-only) searches the loaded index the way
one search job does. git/git, 85,790 commits, git 2.53.0, release build (the
debug build is within 15%, its longest chunk 0.53 ms):

```text
search fix       10381 matches in 4.7 ms
search Junio     31564 matches in 4.2 ms
search zzzqqqxx  0 matches in 3.6 ms
search ed47fdf7  1 matches in 6.8 ms     (hash prefix, plus subjects and authors)
search chunk    max 0.30 ms per 4096 rows (read lock held)
```

A whole search fits in a frame, and loading or the UI's slice reads wait at
most one chunk for the read lock.

## M7.6 — diff minimap

`godot --path godot res://tests/perf/diff_bench.tscn -- --repo=<root> --file=<path> [--no-minimap]`
(windowed, debug gdext). Temp repo with a 50,000-line Rust file, every line
changed: a 100,001-row diff (loaded with `--full`). Tiles are 256 rows at
94 × 2 px a row, rendered by core into RGBA bytes; the overview has 800
buckets.

```text
minimap tile, unified          p50 0.65 ms, max 0.77 ms
minimap tile, side by side     p50 1.05 ms, max 1.09 ms
overview, unified              1.7 ms
overview, side by side         0.9 ms
paging, frame time             p50 41.0 ms with the minimap, 39.6 ms without
```

A tile is rendered once and kept (12 at most), so scrolling only draws
textures; the minimap adds about 1.4 ms a frame while paging through this
worst case, whose 40 ms frames come from fetching and drawing 30 fully
changed, highlighted rows a page.

M7.6 P3 step B (same file and command, windowed): tiles now draw the
changed words of paired lines, and the strip and its positions map the
whole file.

```text
minimap tile, unified          p50 0.83 ms, max 0.96 ms
minimap tile, side by side     p50 1.38 ms, max 1.60 ms
overview, unified              1.7 ms
overview, side by side         0.9 ms
paging, frame time             p50 43.4 ms with the minimap, 43.3 ms without
```

Word ranges cost about 0.2 to 0.3 ms a tile. They are computed only for
tiles: computing them for every row of the overview took it to 66 ms.

## M7.8 P2 — image diffs

`res://tests/perf/image_bench.tscn -- --repo=<root> --file=big.png,photo.jpg`
(windowed, Windows 11, Compatibility renderer) on a throwaway repo where both
files are modified: `big.png` 4096×4096 (15.1 MiB, both sides) and
`photo.jpg` 4600×3200 (19.6 MiB, just under the 20 MiB preview limit, both
sides). The release and debug gdext builds give the same times: the diff
job is bound by git.

```text
                          4096² PNG    19.6 MiB JPG
diff job (git + bytes)    311 ms       484 ms
first picture             568 ms       715 ms
longest frame meanwhile   16.0 ms      16.4 ms   (idle: 8.5 ms)
show_info (bytes copied)  13.0 ms      15.0 ms
again, from the cache     308 ms       481 ms    (longest frame 8.5 ms)
```

The diff job is `git diff` (235–270 ms for a 20 MB binary: git hashes the
working file) and `git cat-file` of the old blob (about 130 ms), so the
300 ms target to the first picture is missed for files this large;
decoding both sides on worker threads adds about 250 ms. The main thread
target is met: an image larger than 2048 px shows a 2048 px preview with
mipmaps made on the worker, one texture uploads a frame, and the full image
uploads only when zoomed in past the preview (uploading a full 4096² texture
took 31–39 ms, and both sides landed in one frame: 85–119 ms before).

## M7.10 — co-authors in the graph load

2026-11-07, git/git (fresh clone, 86,059 commits, 238 `Co-authored-by`
trailers), git 2.53.0, release `gitbello-cli graph-bench`, three runs each.
The log format gains `%(trailers:key=Co-authored-by,valueonly,unfold,separator=%x1e)`.

```text
                before            after
first page      623 to 677 ms     658 to 665 ms (one cold outlier: 1065 ms)
full index      795 to 861 ms     998 to 1003 ms
index memory    58.5 bytes/commit 58.5 bytes/commit
string memory   4.13 MiB          4.14 MiB
```

The extra ~190 ms is git's: `git log` alone takes 833 to 1011 ms with the
old format, 980 to 1033 ms with the trailers and 1077 to 1167 ms with the
whole body (`%b`). Co-authors are stored only for the rows that have them
(three `u32` vectors), so the index does not grow per commit.
