use crate::model::{Champion, Preferences};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::Write,
    path::{Component, Path, PathBuf},
};

pub fn data_dir() -> PathBuf {
    std::env::var_os("CATENGAR_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("LOCALAPPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(std::env::temp_dir)
                .join("LoLRengar")
        })
}
pub fn read_bounded(path: &Path, limit: u64) -> Result<Vec<u8>> {
    use std::io::Read;
    let file = fs::File::open(path)?;
    let mut bytes = vec![];
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        bail!("文件超出大小限制");
    }
    Ok(bytes)
}
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path.parent().context("missing parent")?;
    fs::create_dir_all(parent)?;
    let temp = parent.join(format!(".catengar-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        #[cfg(windows)]
        unsafe {
            use windows::{
                Win32::Storage::FileSystem::{
                    MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
                },
                core::HSTRING,
            };
            MoveFileExW(
                &HSTRING::from(temp.as_os_str()),
                &HSTRING::from(path.as_os_str()),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            )?;
        }
        #[cfg(not(windows))]
        fs::rename(&temp, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}
pub fn load_preferences(root: &Path) -> Result<Preferences> {
    let path = root.join("settings.json");
    if !path.exists() {
        return Ok(Preferences::default());
    }
    let mut p: Preferences = serde_json::from_slice(&read_bounded(&path, 64 * 1024)?)?;
    if p.version != 1 {
        bail!("不支持的设置版本");
    }
    p.normalize();
    Ok(p)
}
pub fn save_preferences(root: &Path, p: &Preferences) -> Result<()> {
    atomic_write(&root.join("settings.json"), &serde_json::to_vec_pretty(p)?)
}
pub fn valid_portrait(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 1024
        && !path.contains([':', '\\', '\0'])
        && path.starts_with("cache/")
        && Path::new(path)
            .components()
            .all(|c| matches!(c, Component::Normal(_)))
}
#[derive(Serialize, Deserialize)]
struct PriorityCache {
    version: u32,
    champions: Vec<Champion>,
}
pub fn load_priorities(root: &Path, p: &Preferences) -> Result<Vec<Champion>> {
    let path = root.join("priority-champions.json");
    if !path.exists() {
        return Ok(vec![]);
    }
    let wire: PriorityCache = serde_json::from_slice(&read_bounded(&path, 128 * 1024)?)?;
    if wire.version != 1 {
        bail!("不支持的英雄缓存版本");
    }
    Ok(p.priority
        .iter()
        .filter_map(|id| {
            wire.champions
                .iter()
                .find(|c| c.id == *id && c.valid())
                .cloned()
        })
        .map(|mut c| {
            c.portrait = c.portrait.replace('\\', "/");
            if !valid_portrait(&c.portrait) || !root.join(&c.portrait).is_file() {
                c.portrait.clear();
            }
            c
        })
        .collect())
}
pub fn save_priorities(root: &Path, p: &Preferences, champions: &[Champion]) -> Result<()> {
    let champions = p
        .priority
        .iter()
        .filter_map(|id| champions.iter().find(|c| c.id == *id && c.valid()).cloned())
        .collect();
    let bytes = serde_json::to_vec(&PriorityCache {
        version: 1,
        champions,
    })?;
    let path = root.join("priority-champions.json");
    if fs::read(&path).ok().as_deref() != Some(&bytes) {
        atomic_write(&path, &bytes)?;
    }
    Ok(())
}
