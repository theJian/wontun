use crate::model::State;
use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    os::{
        fd::AsRawFd,
        unix::fs::{OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
};

pub struct Store {
    pub directory: PathBuf,
    _lock: File,
}
impl Store {
    pub fn open(directory: PathBuf) -> Result<(Self, State), String> {
        fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))
            .map_err(|e| e.to_string())?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .open(directory.join("session.lock"))
            .map_err(|e| e.to_string())?;
        // Only one backend may own a data directory and its running core.
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err("Wontun is already using this data directory".into());
        }
        let path = directory.join("state.json");
        let state = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| format!("Cannot read state.json; restore a valid backup: {e}"))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => State::default(),
            Err(e) => return Err(e.to_string()),
        };
        Ok((
            Self {
                directory,
                _lock: lock,
            },
            state,
        ))
    }
    pub fn save(&self, state: &State) -> Result<(), String> {
        write_private(
            &self.directory.join("state.json"),
            &serde_json::to_vec_pretty(state).map_err(|e| e.to_string())?,
        )
    }
}

pub fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let temp = path.with_extension("tmp");
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&temp)
        .map_err(|e| e.to_string())?;
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|e| e.to_string())?;
    file.write_all(bytes)
        .and_then(|_| file.sync_all())
        .map_err(|e| e.to_string())?;
    fs::rename(temp, path).map_err(|e| e.to_string())?;
    if let Some(parent) = path.parent() {
        File::open(parent)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}
