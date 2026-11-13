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

## M7.13 P7 — quieter colours

Share of a file's visible characters drawn in a colour (not plain text),
release `gitbello-cli highlight` over this repository's files (samples
excluded), before (P6 HEAD, old palette) and after. "Red/green" counts the
kinds drawn in a red or green hue; after P7 only a patch's added and
removed lines are.

```text
                     files   coloured        red/green
                             before  after   before  after
toml                    10     96%    37%      59%     0%
godot_resource          61     94%    54%      37%     0%
xml (svg)               75     90%    29%      67%     0%
yaml                     2     78%    21%      56%     0%
rust                   159     64%    47%       9%     0%
gdscript               153     67%    47%      15%     0%
python                   2     64%    53%      32%     0%
shell                    2     72%    70%      37%     0%
powershell               1     81%    75%      19%     0%
markdown                10     24%    24%      18%     0%
csv                      1     97%    97%      30%     0%
```

On the samples (`gitbello-core/tests/highlight`), red fell from 12–31% to
0 in Batch, Makefile, PHP, PowerShell, HTML, XML, LESS, SCSS and shell;
JSON went from 85% to 57% coloured, TOML 87% to 58%, YAML 77% to 52%, XML
85% to 59%, Godot resources 91% to 51%, code 2–12 points less (the function
names). Lexing time is unchanged: the data lexers push fewer tokens.

## M7.13 P6 — readable colours per background

Tables (`AppTheme.syntax_color_tables`, headless, debug gdext): the first
build of a background's table, made readable for the 39 kinds plus plain
and hunk text, took 2.7 ms (dark) and 4.8 ms (light) with 18 lightness and
14 chroma halvings, built while drawing. Now 12 and 10 halvings (lightness
within 1/4096), each distinct colour once per table, and the tables shared
by every view: 0.7 and 1.1 ms the first time, 13 µs after.

Diff view, `res://tests/perf/diff_bench.tscn` (windowed, debug gdext) on
the P1 setup: the P5b commit's GDScript (`git archive`, the same DLL) as
before and this branch as after, alternating, four runs each. Paging
redraws every row: drawing picks the row's table once per line and looks
another up only for pieces under the changed words or the selection
(looking one up per piece cost about 8 ms at p99).

```text
                               before                     after
unified fetch 300 rows, p50    1716 / 1706 / 1735 / 1709  1710 / 1695 / 1710 / 1713 us
paging frame p99               48.5 / 47.2 / 48.5 / 49.8  50.1 / 49.2 / 50.2 / 49.4 ms
```

## M7.13 P5b — mixed-language files

Lexing, release `gitbello-cli highlight-bench` as in P1. On the P5a
samples, this branch and the P5a commit (built from `git archive`) timed
alternately, three runs each: 31.2 to 31.5 µs per 100 lines against 29.3
to 29.8, about 6% slower across languages (every line now starts from a
whole `LineState` and leaves one with its embedded frames, about 20 ns).
HTML, PHP and Godot resources do more per line (37.5 to 42.5 µs against
29.1 to 33.0): script and style bodies and `.tscn` scripts are lexed in
their languages. The new samples:

```text
language      lines      lines/s   us/100 lines     us/long line   states us/100
html             42      2525025           39.6              156            46.2
php (HTML)       31      1991456           50.2              159            46.1
php              45      2623524           38.1              120            41.9
razor            36      2008536           49.8               58            67.5
razor (cshtml)   34      2385630           41.9                9            52.1
all (45)                 3283719           30.5
```

A PHP island is lexed up to each `?>` in turn until one is outside strings
and comments; lexing every island to the line's end first gave 3.5 ms on
the HTML sample's long line (many `<?= … ?>`), now 159 µs. Budget: 1 ms
per 100 lines, 5 ms per long line.

Diff view, `res://tests/perf/diff_bench.tscn` (windowed, debug gdext) on
the P1 setup: the P5a commit built from `git archive` (before) and this
branch (after), alternating, two runs each. Fetches, tiles and frames
within noise. Load read 10 to 17 ms slower in four pairs, but the two
DLLs swapped in the same project folder gave the opposite (base 116 to
133 ms, branch 105 to 110 ms, three pairs): the difference is the
folder, not the code. Lexing the 5,143-line bench file in a debug build
takes 2.6 ms either way.

```text
                               before            after
unified fetch 300 rows, p50    1711 / 1727 us    1688 / 1696 us
side by side fetch, p50        3967 / 3817 us    3831 / 3925 us
minimap tile unified, p50       533 /  544 us     542 /  559 us
minimap tile split, p50         751 /  747 us     760 /  794 us
paging frame p99               60.8 / 49.8 ms    51.6 / 51.0 ms
```

## M7.13 P5a — line states

Lexing, release `gitbello-cli highlight-bench` as in P1: 30.3 µs per 100
lines over the 42 samples, which grew multi-line cases (P4: 28.8). The new
`states us/100` column times `LineStates::of_text`, the whole-file pass the
states job makes: 13.7 to 63.8 µs per 100 lines, about what lexing costs.
A 10,027-line Rust file (the sample repeated) takes 3.5 ms. Budget: states
ready within 100 ms of the diff for files up to 10,000 lines.

Diff view, `res://tests/perf/diff_bench.tscn` (windowed, debug gdext) on
the P1 setup: the P5 plan commit built from `git archive` (before) and this
branch (after), alternating, two runs each. `states_ms` is new: from the
selection to the states landing (a `git cat-file` of the old side, the
working file and both passes, debug build), about 40 ms after the diff.

```text
                               before            after
load                            91.0 / 105.8 ms   106.0 / 104.8 ms
states ready                       -              144.7 / 145.8 ms
unified fetch 300 rows, p50    1837 / 1692 us    1692 / 1690 us
side by side fetch, p50        3865 / 3819 us    3828 / 3816 us
minimap tile unified, p50       533 /  535 us     524 /  530 us
minimap tile split, p50         743 /  715 us     756 /  745 us
paging frame p99               47.2 / 47.3 ms    46.3 / 47.8 ms
```

## M7.13 P4 — more scripting languages

Lexing, release `gitbello-cli highlight-bench` as in P1. The six new
samples:

```text
language      lines      lines/s   us/100 lines     us/long line
batch            32      2533149           39.5               51
dart             53      3962321           25.2                7
lua              36      3912193           25.6                8
php              43      3314321           30.2               53
ruby             56      4189578           23.9               71
zig              53      4049666           24.7                6
all (42)                 3476774           28.8
```

The machine ran slower than in P3: the P3 build, timed the same day on its
36 samples, gave 29.2 µs per 100 lines (26.4 in P3's run); this branch
gave 28.8, 29.2 and 29.9 over three runs. Budget: 1 ms per 100 lines,
5 ms per long line.

Diff view, `res://tests/perf/diff_bench.tscn` (windowed, debug gdext) on
the P1 setup: the P3 commit built from `git archive` (before) and this
branch (after), alternating, two runs each. Within noise.

```text
                               before            after
unified fetch 300 rows, p50    1694 / 1769 us    1692 / 1740 us
side by side fetch, p50        3776 / 3769 us    3718 / 3777 us
minimap tile unified, p50       527 /  525 us     517 /  539 us
minimap tile split, p50         728 /  733 us     733 /  724 us
paging frame p99               48.3 / 48.1 ms    48.2 / 48.3 ms
```

## M7.13 P3 — web and data languages

Lexing, release `gitbello-cli highlight-bench` as in P1: 26.4 µs per 100
lines over the 36 samples (P2: 27.0 over 24). Budget: 1 ms per 100 lines,
5 ms per long line.

```text
language      lines      lines/s   us/100 lines     us/long line
css              33      3771644           26.5               98
csv               6      4321210           23.1               46
diff             19      6779661           14.8                7
dotenv           10      5056890           19.8               41
gitattributes     9      4302103           23.2               91
html             21      2529968           39.5               83
ignore           10      8074283           12.4               25
less             25      4208754           23.8               62
scss             35      4507405           22.2               91
sql              23      2637312           37.9               63
tsv               5      7905138           12.7               12
xml              17      3415712           29.3               26
all (36)                 3783370           26.4
```

Lines are now lexed raw, with their tabs (TSV delimiters, Makefile
recipes), and tokens mapped to the displayed columns. Diff view,
`res://tests/perf/diff_bench.tscn` (windowed, debug gdext) on the P1 setup
(5,142-line Rust file, 5,878 rows): the P2 commit built from `git archive`
(before) and this branch (after), alternating, two runs each.

```text
                               before            after
unified fetch 300 rows, p50    1668 / 1652 us    1657 / 1633 us
side by side fetch, p50        3810 / 3761 us    3770 / 3748 us
minimap tile unified, p50       511 /  500 us     528 /  527 us
minimap tile split, p50         718 /  678 us     714 /  723 us
paging frame p99               49.2 / 48.0 ms    49.9 / 47.8 ms
```

A first version copied each line into a new `String` before lexing; the
fetches were 5% and the tiles 4 to 7% slower. Lexing the borrowed text
brought the fetches back level; the tiles stay 1 to 5% slower (they also
validate each line's UTF-8 twice).

## M7.13 P2 — more languages

Lexing, release `gitbello-cli highlight-bench` as in P1. The Spec lexer looks
words up in tables built once per language (an FNV hash map, and which ASCII
characters can open a comment, string or attribute), which more than pays
for the new rules: 27.0 µs per 100 lines over all samples (P1: 27.9 over 11
languages). Budget: 1 ms per 100 lines, 5 ms per long line.

```text
language      lines      lines/s   us/100 lines     us/long line
c                27      3864319           25.9               67
cpp              32      3664682           27.3               15
csharp           28      2934857           34.1               16
dockerfile       22      3278933           30.5               14
gdscript         30      3905487           25.6                6
glsl             31      3938759           25.4               73
go               31      5132025           19.5               64
godot_resource   28      4683057           21.4               41
godot_shader     25      2243158           44.6               98
ini              19      4706465           21.2               10
java             29      3636820           27.5               32
javascript       27      3463315           28.9               56
json             13      3335899           30.0              110
kotlin           35      3946775           25.3               58
makefile         27      4528302           22.1               23
markdown         25      8080155           12.4                9
powershell       29      3123990           32.0               44
python           35      2916545           34.3               79
rust             33      2875817           34.8                6
shell            29      3888703           25.7               86
swift            27      3597841           27.8                6
toml             18      5902607           16.9                5
typescript       35      3478261           28.7               55
yaml             26      4994237           20.0               41
all                      3706144           27.0
```

Diff view, `res://tests/perf/diff_bench.tscn` (windowed, debug gdext) on the
P1 setup (a 5,142-line Rust file, every seventh line edited, 5,878 rows):
the P1 commit built from `git archive` (before) and this branch (after),
alternating, two runs each. Budget: no regression over 10%.

```text
                               before            after
unified fetch 300 rows, p50    1694 / 1643 us    1647 / 1662 us
side by side fetch, p50        3754 / 3778 us    3746 / 3876 us
minimap tile unified, p50       528 /  518 us     500 /  509 us
minimap tile split, p50         736 /  730 us     703 /  682 us
overview (800 buckets)          0.1 ms            0.1 ms
paging frame, p50 / p99        6.96 / 43 ms      7.00 / 48 ms
```

Before the tables, with the word lists scanned and a `String` allocated per
word, the tiles were 8% (unified) and 11% (split) slower than P1.

## M7.13 P1 — syntax highlighting

Lexing, release `gitbello-cli highlight-bench` over the core samples
(200 rounds; the long line is the sample's code lines joined up to the
10,000-character lexing limit). Budget: 1 ms per 100 lines, 5 ms per long line.

```text
language      lines      lines/s   us/100 lines     us/long line
c                27      2617928           38.2              139
gdscript         30      3497726           28.6              109
go               31      3822441           26.2              124
javascript       27      2743624           36.4              148
json             12      5692600           17.6               66
markdown         23     10233593            9.8                6
python           34      3077202           32.5              123
rust             32      2403485           41.6               94
shell            29      4421743           22.6               99
toml             18      5164252           19.4                7
yaml             26      5183930           19.3               78
all                      3584741           27.9
```

Diff view, `res://tests/perf/diff_bench.tscn` (windowed, debug gdext) on a
temp repo with a 5,142-line Rust file, every seventh line edited (5,569
rows), two runs each of `main` (before) and this branch (after). Budget: no
regression over 10%.

```text
                               before            after
unified fetch 300 rows, p50    1713 / 1914 us    1718 / 1764 us
side by side fetch, p50        3820 / 3987 us    4031 / 3812 us
minimap tile unified, p50       537 /  575 us     589 /  561 us
minimap tile split, p50         763 /  778 us     819 /  794 us
overview (800 buckets)          0.2 ms            0.2 ms
paging frame, p50 / p99        6.97 / 47 ms      6.97 / 46 ms
```

The differences are within run-to-run noise (tiles +3 to 5%, fetches
either way).

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

## M8a — file history

2026-11-10, git/git (82,797 commits), git 2.43.0, Linux, 4 cores, release
`gitbello-cli file-history <root> <file> --time`, warm, three runs each.
"First row" is the time from the request to the first commit a view could
show; "full list" is every pass done (one pass per name the file had).

```text
file              commits  passes  first row     full list
Makefile          3,285    1       13 to 34 ms   1.50 to 1.68 s
builtin/log.c     863      2       11 to 15 ms   1.70 to 1.81 s
t/t4202-log.sh    177      1       45 to 52 ms   1.33 to 1.38 s
README.md         55       2       47 to 52 ms   0.97 to 1.00 s
```

The 100 ms target to the first rows is met; the full list is git's walk of
the whole history, once per pass. For reference, on the same clone:
`git log -- Makefile` takes about 0.8 s and
`git log -- builtin/log.c builtin-log.c` about 0.75 s without diffs; the
raw entries, the line counts and rename detection (`--raw --numstat -M`)
make up most of the rest, and the second pass of a renamed file costs
another walk.

- **`--follow`.** `git log --follow -- builtin/log.c` lists 611 commits in
  2.9 s. The path-limited log over both names lists 863, the same commits
  as `git log -- builtin/log.c builtin-log.c`: the 252 others were made
  under the old name on branches merged after the rename.
- **Merges.** `--diff-merges=first-parent` on `git log` turns history
  simplification off: `Makefile` lists 21,072 commits instead of 3,285, in
  2.2 s instead of 0.8 s. The log is read without merge diffs and
  `git diff-tree --stdin` reads the merges it lists, a batch per chunk.
- **Cold.** After dropping the page cache, `Makefile`'s full list took
  1.92 s (`git log --raw --numstat -M -- Makefile` alone: 2.09 s).
- **One outlier.** A run started right after `cargo xtask check` took
  2.2 s to the first row and 32.7 s to the full list of `Makefile`. It did
  not come back in the runs above, cold or warm; the machine was most
  likely still busy, but the cause was not measured.

## M8b — blame

2026-11-11, git/git (82,797 commits), git 2.43.0, Linux, 4 cores, release
`gitbello-cli blame <root> <file> --rev HEAD --time`, warm, three runs each.
"Text" is the time from the request to the file's lines (what the view
shows first), "first block" to the first lines git names a commit for, and
"blame" to the last.

```text
file              lines   commits  text       first block   blame
Makefile          4,144   956      3 to 5 ms  12 to 13 ms   1.49 to 1.51 s
builtin/log.c     2,858   395      3 ms       13 ms         0.84 s
README.md         75      19       2 to 3 ms  16 to 17 ms   0.40 to 0.46 s
```

The text and the first names are on screen well inside the 100 ms target;
the rest is git's walk, streamed into the gutter as it goes
(`git blame --incremental` of `Makefile` alone: 1.5 s, the same as
`--porcelain`).

- **Options.** `Makefile` with `-w -M` (Ignore whitespace and Detect moved
  lines): 2.03 to 2.09 s, 1,000 commits named instead of 956.
- **Working copy.** `Makefile` without `--rev` (the file on disk, no
  uncommitted lines): the text in under 1 ms, the first block in 8 to
  10 ms, the blame in 1.22 to 1.41 s.
- **One outlier.** The first run after `cargo build --release` took 1.8 s
  to the text, 2.8 s to the first block and 24.4 s to the end. It did not
  come back in the eleven runs that followed; as M8a's, the machine was
  most likely still busy, and the cause was not measured.
