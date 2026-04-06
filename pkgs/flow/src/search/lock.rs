use anyhow::Context as _;
use fs2::FileExt;
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub struct FileLock {
    file: File,
    path: PathBuf,
}

impl FileLock {
    pub fn acquire(path: &Path) -> anyhow::Result<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }

        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(path)
            .with_context(|| format!("failed to open {}", path.display()))?;
        file.lock_exclusive()
            .with_context(|| format!("failed to acquire lock {}", path.display()))?;

        Ok(Self {
            file,
            path: path.to_path_buf(),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.file);
    }
}

#[cfg(test)]
mod tests {
    use super::FileLock;

    #[test]
    fn blocks_second_acquisition_until_drop() {
        let tempdir = tempfile::tempdir().expect("tempdir created");
        let lock_path = tempdir.path().join("reindex.lock");

        let first = FileLock::acquire(&lock_path).expect("first lock acquired");
        let start = std::time::Instant::now();
        let other_path = lock_path.clone();
        let thread = std::thread::spawn(move || {
            let _second = FileLock::acquire(&other_path).expect("second lock acquired");
            start.elapsed()
        });

        std::thread::sleep(std::time::Duration::from_millis(150));
        drop(first);

        let waited = thread.join().expect("thread joins");
        assert!(waited >= std::time::Duration::from_millis(150));
    }
}
