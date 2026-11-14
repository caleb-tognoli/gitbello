class_name ShortHash
extends RefCounted
## The short form of a commit hash, the same length everywhere it is shown.
## Keep `LENGTH` equal to `SHORT_HASH_LEN` in `gitbello-core/src/graph/index.rs`.

const LENGTH: int = 7


## `oid` cut to `LENGTH` characters (unchanged when it is shorter).
static func of(oid: String) -> String:
	return oid.left(LENGTH)
