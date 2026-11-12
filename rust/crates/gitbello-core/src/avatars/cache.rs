//! Avatars on disk, by the email's SHA-256 (`key`):
//! `<key>.<provider>.<png|jpg|webp>` for a picture (the provider that gave
//! it, so turning that provider off hides it) and `<key>.miss` when no
//! source has one, listing the providers asked and `github-remote` when a
//! repository's GitHub remote was among them. A miss is asked again after
//! [`MISS_TTL`], a picture refreshed after [`PICTURE_TTL`] (shown meanwhile).

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use super::{ImageFormat, Provider, Providers};

pub const MISS_TTL: Duration = Duration::from_secs(7 * 24 * 60 * 60);
pub const PICTURE_TTL: Duration = Duration::from_secs(30 * 24 * 60 * 60);

const MISS: &str = "miss";
const GITHUB_REMOTE: &str = "github-remote";

/// What the cache knows about one email.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Cached {
    Nothing,
    /// `stale`: older than [`PICTURE_TTL`]; show it, and look again.
    Picture {
        bytes: Vec<u8>,
        format: ImageFormat,
        provider: Provider,
        stale: bool,
    },
    /// `stale`: older than [`MISS_TTL`]; look again. `asked`: the providers
    /// that had nothing (one not asked may have a picture); `github_remote`:
    /// a GitHub remote's commits were asked too.
    Miss {
        stale: bool,
        asked: Providers,
        github_remote: bool,
    },
}

#[derive(Debug, Clone)]
pub struct AvatarCache {
    dir: PathBuf,
}

impl AvatarCache {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self { dir: dir.into() }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn read(&self, key: &str, now: SystemTime) -> Cached {
        for provider in Provider::ALL {
            for format in ImageFormat::ALL {
                let path = self.path(key, &picture_name(provider, format));
                if let Ok(bytes) = fs::read(&path) {
                    if ImageFormat::sniff(&bytes) == Some(format) {
                        return Cached::Picture {
                            bytes,
                            format,
                            provider,
                            stale: older_than(&path, now, PICTURE_TTL),
                        };
                    }
                }
            }
        }
        let miss = self.path(key, MISS);
        if let Ok(text) = fs::read_to_string(&miss) {
            let words: Vec<&str> = text.split_whitespace().collect();
            return Cached::Miss {
                stale: older_than(&miss, now, MISS_TTL),
                asked: Providers::from_names(words.iter().copied()),
                github_remote: words.contains(&GITHUB_REMOTE),
            };
        }
        Cached::Nothing
    }

    /// Keeps `bytes`, from `provider`, as `key`'s picture, replacing what
    /// was there.
    pub fn store_picture(
        &self,
        key: &str,
        bytes: &[u8],
        format: ImageFormat,
        provider: Provider,
    ) -> io::Result<()> {
        let name = picture_name(provider, format);
        self.write(key, &name, bytes)?;
        self.remove_except(key, &name);
        Ok(())
    }

    /// Notes that none of `asked` (and the GitHub remote, with
    /// `github_remote`) has a picture for `key`, dropping an old one.
    pub fn store_miss(&self, key: &str, asked: Providers, github_remote: bool) -> io::Result<()> {
        let mut words: Vec<&str> = asked.iter().map(Provider::name).collect();
        if github_remote {
            words.push(GITHUB_REMOTE);
        }
        self.write(key, MISS, words.join(" ").as_bytes())?;
        self.remove_except(key, MISS);
        Ok(())
    }

    fn write(&self, key: &str, extension: &str, bytes: &[u8]) -> io::Result<()> {
        fs::create_dir_all(&self.dir)?;
        let path = self.path(key, extension);
        // Written aside and renamed, so a reader never sees half a picture.
        let temp = self.path(key, &format!("{extension}.{}.tmp", std::process::id()));
        fs::write(&temp, bytes)?;
        fs::rename(&temp, &path).inspect_err(|_| {
            let _ = fs::remove_file(&temp);
        })
    }

    /// Removes `key`'s other entries (and pictures named without their
    /// provider, from before).
    fn remove_except(&self, key: &str, keep: &str) {
        let mut names: Vec<String> = Provider::ALL
            .iter()
            .flat_map(|p| ImageFormat::ALL.iter().map(|f| picture_name(*p, *f)))
            .collect();
        names.extend(ImageFormat::ALL.iter().map(|f| f.extension().to_string()));
        names.push(MISS.into());
        for name in names.iter().filter(|n| *n != keep) {
            let _ = fs::remove_file(self.path(key, name));
        }
    }

    fn path(&self, key: &str, extension: &str) -> PathBuf {
        self.dir.join(format!("{key}.{extension}"))
    }
}

fn picture_name(provider: Provider, format: ImageFormat) -> String {
    format!("{}.{}", provider.name(), format.extension())
}

fn older_than(path: &Path, now: SystemTime, ttl: Duration) -> bool {
    // A time after `now` (written meanwhile, or a clock set back) is fresh.
    fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
        .is_none_or(|modified| now.duration_since(modified).unwrap_or_default() > ttl)
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\nrest";
    const JPEG: &[u8] = b"\xff\xd8\xffrest";

    fn cache(name: &str) -> AvatarCache {
        let dir =
            std::env::temp_dir().join(format!("gitbello avatars ü {name} {}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        AvatarCache::new(dir)
    }

    fn names(cache: &AvatarCache) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(cache.dir())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }

    #[test]
    fn pictures_and_misses_replace_each_other() {
        let cache = cache("replace");
        let now = SystemTime::now();
        assert_eq!(cache.read("k", now), Cached::Nothing);

        let asked = Providers::ALL.with(Provider::Gitlab, false);
        cache.store_miss("k", asked, false).unwrap();
        assert_eq!(
            cache.read("k", now),
            Cached::Miss {
                stale: false,
                asked,
                github_remote: false
            }
        );

        cache
            .store_picture("k", PNG, ImageFormat::Png, Provider::Gravatar)
            .unwrap();
        assert_eq!(
            cache.read("k", now),
            Cached::Picture {
                bytes: PNG.to_vec(),
                format: ImageFormat::Png,
                provider: Provider::Gravatar,
                stale: false
            }
        );

        // A picture from before providers were in the name goes too.
        fs::write(cache.dir().join("k.png"), PNG).unwrap();
        cache
            .store_picture("k", JPEG, ImageFormat::Jpeg, Provider::Github)
            .unwrap();
        assert_eq!(names(&cache), vec!["k.github.jpg".to_string()]);

        cache.store_miss("k", Providers::ALL, true).unwrap();
        assert_eq!(
            cache.read("k", now),
            Cached::Miss {
                stale: false,
                asked: Providers::ALL,
                github_remote: true
            }
        );
        assert_eq!(
            fs::read_to_string(cache.dir().join("k.miss")).unwrap(),
            "github gitlab gravatar libravatar github-remote"
        );
        assert_eq!(names(&cache), vec!["k.miss".to_string()]);
        fs::remove_dir_all(cache.dir()).unwrap();
    }

    #[test]
    fn entries_go_stale_after_their_ttl() {
        let cache = cache("stale");
        cache.store_miss("miss", Providers::NONE, false).unwrap();
        cache
            .store_picture("pic", PNG, ImageFormat::Png, Provider::Libravatar)
            .unwrap();
        let later = SystemTime::now() + MISS_TTL + Duration::from_secs(60);
        assert_eq!(
            cache.read("miss", later),
            Cached::Miss {
                stale: true,
                asked: Providers::NONE,
                github_remote: false
            }
        );
        assert!(matches!(
            cache.read("pic", later),
            Cached::Picture { stale: false, .. }
        ));
        let much_later = SystemTime::now() + PICTURE_TTL + Duration::from_secs(60);
        assert!(matches!(
            cache.read("pic", much_later),
            Cached::Picture { stale: true, .. }
        ));
        fs::remove_dir_all(cache.dir()).unwrap();
    }

    #[test]
    fn a_damaged_or_unnamed_picture_counts_as_nothing() {
        let cache = cache("damaged");
        fs::create_dir_all(cache.dir()).unwrap();
        fs::write(cache.dir().join("k.gravatar.png"), b"not a png").unwrap();
        fs::write(cache.dir().join("old.png"), PNG).unwrap();
        assert_eq!(cache.read("k", SystemTime::now()), Cached::Nothing);
        assert_eq!(cache.read("old", SystemTime::now()), Cached::Nothing);
        fs::remove_dir_all(cache.dir()).unwrap();
    }
}
