use crate::storage;
use crossbeam_channel::{Receiver, Sender};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, OpenOptions},
    io::{BufRead, BufReader, Seek, Write},
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub timestamp: String,
    pub kind: String,
    pub level: String,
    pub message: String,
}
impl Entry {
    pub fn new(kind: &str, level: &str, message: impl Into<String>) -> Self {
        Self {
            timestamp: chrono::Local::now()
                .format("%Y-%m-%d %H:%M:%S%.3f")
                .to_string(),
            kind: kind.into(),
            level: level.into(),
            message: message.into(),
        }
    }
    pub fn kind_label(&self) -> &str {
        match self.kind.as_str() {
            "connection" => "连接",
            "accept" => "接受对局",
            "pick" => "自动选取",
            "side" => "阵营提示",
            _ => "应用",
        }
    }
}
enum Command {
    Append(Entry),
    Page(usize, Option<usize>, Sender<Page>),
    Clear(Sender<bool>),
    Stop,
}
#[derive(Clone, Default, Debug, PartialEq)]
pub struct Page {
    pub entries: Vec<Entry>,
    pub total: usize,
    pub offset: usize,
    pub error: String,
}
#[derive(Clone)]
pub struct Journal {
    tx: Sender<Command>,
    pub error: Arc<Mutex<String>>,
    pub path: PathBuf,
}
impl Journal {
    pub fn start(root: PathBuf) -> (Self, thread::JoinHandle<()>) {
        let path = root.join("logs/activity.jsonl");
        let (tx, rx) = crossbeam_channel::unbounded();
        let error = Arc::new(Mutex::new(String::new()));
        let journal = Self {
            tx,
            error: error.clone(),
            path: path.clone(),
        };
        let handle = thread::spawn(move || run(path, rx, error));
        (journal, handle)
    }
    pub fn log(&self, kind: &str, level: &str, message: impl Into<String>) {
        let _ = self
            .tx
            .send(Command::Append(Entry::new(kind, level, message)));
    }
    pub fn page(&self, offset: usize) -> Receiver<Page> {
        self.page_at(offset, None)
    }
    pub fn page_at(&self, offset: usize, before: Option<usize>) -> Receiver<Page> {
        let (tx, rx) = crossbeam_channel::bounded(1);
        let _ = self.tx.send(Command::Page(offset, before, tx));
        rx
    }
    pub fn clear(&self) -> Receiver<bool> {
        let (tx, rx) = crossbeam_channel::bounded(1);
        let _ = self.tx.send(Command::Clear(tx));
        rx
    }
    pub fn stop(&self) {
        let _ = self.tx.send(Command::Stop);
    }
}
fn run(path: PathBuf, rx: Receiver<Command>, error: Arc<Mutex<String>>) {
    let mut pending = Vec::<Entry>::new();
    loop {
        let mut stop = false;
        match rx.recv_timeout(std::time::Duration::from_secs(2)) {
            Ok(Command::Append(e)) => pending.push(e),
            Ok(Command::Page(offset, before, reply)) => {
                let mut page = Page {
                    offset,
                    ..Default::default()
                };
                // Scan on the journal worker, never the automation or UI thread.
                // Retain only the requested page, even for multi-year logs.
                if let Ok(file) = fs::File::open(&path) {
                    let mut reader = BufReader::new(file);
                    page.total = (&mut reader)
                        .lines()
                        .map_while(Result::ok)
                        .filter(|line| serde_json::from_str::<Entry>(line).is_ok())
                        .count();
                    page.total = page.total.min(before.unwrap_or(usize::MAX));
                    let end = page.total.saturating_sub(offset);
                    let begin = end.saturating_sub(20);
                    if reader.rewind().is_ok() {
                        page.entries = reader
                            .lines()
                            .map_while(Result::ok)
                            .filter_map(|line| serde_json::from_str::<Entry>(&line).ok())
                            .skip(begin)
                            .take(end - begin)
                            .collect();
                        page.entries.reverse();
                    }
                }
                page.error = error.lock().unwrap().clone();
                let _ = reply.send(page);
            }
            Ok(Command::Clear(reply)) => {
                let ok = storage::atomic_write(&path, b"").is_ok();
                if ok {
                    pending.clear();
                    error.lock().unwrap().clear();
                }
                let _ = reply.send(ok);
            }
            Ok(Command::Stop) | Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                stop = true
            }
            Err(_) => {}
        }
        if !pending.is_empty() {
            let result = (|| -> std::io::Result<()> {
                fs::create_dir_all(path.parent().unwrap())?;
                let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
                let original = file.metadata()?.len();
                let mut bytes = Vec::new();
                for e in &pending {
                    serde_json::to_writer(&mut bytes, e)?;
                    bytes.push(b'\n');
                }
                if let Err(e) = file.write_all(&bytes).and_then(|_| file.sync_data()) {
                    let _ = file.set_len(original);
                    return Err(e);
                }
                Ok(())
            })();
            if result.is_ok() {
                pending.clear();
                error.lock().unwrap().clear();
            } else {
                *error.lock().unwrap() = "日志尚未保存，将在后台重试。".into();
            }
        }
        if stop {
            break;
        }
    }
}
