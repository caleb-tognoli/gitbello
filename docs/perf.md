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
