use crate::auth::Credentials;
use anyhow::{Context, Result, bail};
use base64::Engine;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::Read,
    net::{SocketAddr, TcpStream},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};
use tungstenite::{Message, client::IntoClientRequest};

pub const PHASE: &str = "/lol-gameflow/v1/gameflow-phase";
pub const GAME: &str = "/lol-gameflow/v1/session";
pub const READY: &str = "/lol-matchmaking/v1/ready-check";
pub const SESSION: &str = "/lol-champ-select/v1/session";
pub const PICKABLE: &str = "/lol-champ-select/v1/pickable-champion-ids";
pub const PROFILE: &str = "/lol-summoner/v1/current-summoner";
const SLOTS: [&str; 6] = [PHASE, GAME, READY, SESSION, PICKABLE, PROFILE];
#[derive(Clone, Debug, PartialEq)]
pub struct Response {
    pub status: u16,
    pub data: Value,
}
impl Response {
    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }
}
pub trait Api {
    fn get(&mut self, path: &str, fresh: bool) -> Result<Response>;
    /// None means a newer event invalidated the decision before submission.
    fn write(
        &mut self,
        method: &str,
        path: &str,
        body: Option<Value>,
        revision: u64,
    ) -> Result<Option<Response>>;
    fn revision(&self) -> u64;
    fn guard(&self, _observed: &[(&str, &Value)]) -> Option<u64> {
        Some(self.revision())
    }
}
#[derive(Default)]
pub struct Cache {
    pub revision: u64,
    values: HashMap<String, Response>,
}
impl Cache {
    pub fn apply(&mut self, path: &str, response: Response) {
        if !SLOTS.contains(&path) {
            return;
        }
        if path == PHASE && self.values.get(PHASE).map(|v| &v.data) != Some(&response.data) {
            for slot in [GAME, READY, SESSION, PICKABLE] {
                self.values.remove(slot);
            }
        }
        self.revision = self.revision.wrapping_add(1);
        self.values.insert(path.into(), response);
    }
    pub fn reconcile(&mut self, path: &str, response: Response, revision: u64) -> Response {
        if self.revision == revision {
            self.apply(path, response.clone());
            return response;
        }
        self.values.get(path).cloned().unwrap_or(Response {
            status: 409,
            data: Value::Null,
        })
    }
    fn clear(&mut self) {
        self.revision = self.revision.wrapping_add(1);
        self.values.clear();
    }
}
pub struct Client {
    credentials: Credentials,
    http: reqwest::blocking::Client,
    cache: Arc<Mutex<Cache>>,
    pub websocket: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    ws: Option<thread::JoinHandle<()>>,
    pub wake: crossbeam_channel::Receiver<()>,
    pub expired: Arc<AtomicBool>,
}
fn authorization(c: &Credentials) -> String {
    format!(
        "Basic {}",
        base64::engine::general_purpose::STANDARD.encode(format!("riot:{}", c.token))
    )
}
pub fn valid_endpoint(path: &str) -> bool {
    path.starts_with('/') && !path.starts_with("//") && !path.contains(['\\', ':', '\r', '\n', '#'])
}
impl Client {
    pub fn new(credentials: Credentials) -> Result<Self> {
        Self::with_events(credentials, true)
    }
    pub fn resources(credentials: Credentials) -> Result<Self> {
        Self::with_events(credentials, false)
    }
    fn with_events(credentials: Credentials, listen: bool) -> Result<Self> {
        if !credentials.valid() {
            bail!("InvalidCredentials");
        }
        let mut headers = reqwest::header::HeaderMap::new();
        let mut auth = reqwest::header::HeaderValue::from_str(&authorization(&credentials))?;
        auth.set_sensitive(true);
        headers.insert(reqwest::header::AUTHORIZATION, auth);
        let http = reqwest::blocking::Client::builder()
            .danger_accept_invalid_certs(true)
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .default_headers(headers)
            .connect_timeout(Duration::from_secs(1))
            .timeout(Duration::from_millis(2500))
            .build()?;
        let cache = Arc::new(Mutex::new(Cache::default()));
        let websocket = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let expired = Arc::new(AtomicBool::new(false));
        let (tx, wake) = crossbeam_channel::bounded(1);
        let (c, ws_cache, alive, stop2, expired2) = (
            credentials.clone(),
            cache.clone(),
            websocket.clone(),
            stop.clone(),
            expired.clone(),
        );
        let ws = listen.then(|| {
            thread::spawn(move || {
                while !stop2.load(Ordering::Acquire) {
                    let _ = stream(&c, &ws_cache, &alive, &stop2, &expired2, &tx);
                    alive.store(false, Ordering::Release);
                    let _ = tx.try_send(());
                    for _ in 0..100 {
                        if stop2.load(Ordering::Acquire) {
                            return;
                        }
                        thread::sleep(Duration::from_millis(100));
                    }
                }
            })
        });
        Ok(Self {
            credentials,
            http,
            cache,
            websocket,
            stop,
            ws,
            wake,
            expired,
        })
    }
    pub fn identity(&self) -> &Credentials {
        &self.credentials
    }
    pub fn bytes(&self, path: &str, limit: u64) -> Result<(u16, Vec<u8>)> {
        if !valid_endpoint(path) {
            bail!("InvalidEndpoint");
        }
        let response = self
            .http
            .get(format!("https://127.0.0.1:{}{path}", self.credentials.port))
            .send()
            .map_err(|_| anyhow::anyhow!("LCU 网络请求失败"))?;
        let status = response.status().as_u16();
        if status == 401 || status == 403 {
            self.expired.store(true, Ordering::Release);
            bail!("AuthenticationExpired");
        }
        let mut body = vec![];
        response
            .take(limit + 1)
            .read_to_end(&mut body)
            .context("LCU 响应读取失败")?;
        if body.len() as u64 > limit {
            bail!("ResponseTooLarge");
        }
        Ok((status, body))
    }
    fn read_rest(&self, path: &str) -> Result<Response> {
        let (status, bytes) = self.bytes(path, 8 * 1024 * 1024)?;
        let data = if bytes.is_empty() || !(200..300).contains(&status) {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).context("LCU 返回了无效数据")?
        };
        Ok(Response { status, data })
    }
}
impl Api for Client {
    fn get(&mut self, path: &str, fresh: bool) -> Result<Response> {
        let live = self.websocket.load(Ordering::Acquire) && SLOTS.contains(&path);
        if live
            && !fresh
            && let Some(v) = self.cache.lock().unwrap().values.get(path)
        {
            return Ok(v.clone());
        }
        let revision = self.revision();
        let response = self.read_rest(path)?;
        if live {
            Ok(self
                .cache
                .lock()
                .unwrap()
                .reconcile(path, response, revision))
        } else {
            Ok(response)
        }
    }
    fn write(
        &mut self,
        method: &str,
        path: &str,
        body: Option<Value>,
        revision: u64,
    ) -> Result<Option<Response>> {
        if self.expired.load(Ordering::Acquire) {
            bail!("AuthenticationExpired");
        }
        if !valid_endpoint(path) {
            bail!("InvalidEndpoint");
        }
        if self.revision() != revision {
            return Ok(None);
        }
        let method = reqwest::Method::from_bytes(method.as_bytes())?;
        let mut request = self.http.request(
            method,
            format!("https://127.0.0.1:{}{path}", self.credentials.port),
        );
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request
            .send()
            .map_err(|_| anyhow::anyhow!("LCU 写入中断，结果未确认"))?;
        let status = response.status().as_u16();
        if status == 401 || status == 403 {
            self.expired.store(true, Ordering::Release);
            bail!("AuthenticationExpired");
        }
        Ok(Some(Response {
            status,
            data: Value::Null,
        }))
    }
    fn revision(&self) -> u64 {
        self.cache.lock().unwrap().revision
    }
    fn guard(&self, observed: &[(&str, &Value)]) -> Option<u64> {
        let cache = self.cache.lock().unwrap();
        if self.websocket.load(Ordering::Acquire)
            && observed.iter().any(|(path, data)| {
                cache
                    .values
                    .get(*path)
                    .is_none_or(|r| !r.ok() || &r.data != *data)
            })
        {
            return None;
        }
        Some(cache.revision)
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(ws) = self.ws.take() {
            let _ = ws.join();
        }
    }
}
fn stream(
    c: &Credentials,
    cache: &Mutex<Cache>,
    alive: &AtomicBool,
    stop: &AtomicBool,
    expired: &AtomicBool,
    wake: &crossbeam_channel::Sender<()>,
) -> Result<()> {
    let tcp = TcpStream::connect_timeout(
        &SocketAddr::from(([127, 0, 0, 1], c.port)),
        Duration::from_secs(1),
    )?;
    tcp.set_read_timeout(Some(Duration::from_secs(3)))?;
    tcp.set_write_timeout(Some(Duration::from_secs(3)))?;
    let tls = native_tls::TlsConnector::builder()
        .danger_accept_invalid_certs(true)
        .danger_accept_invalid_hostnames(true)
        .build()?;
    let mut request = format!("wss://127.0.0.1:{}/", c.port).into_client_request()?;
    request
        .headers_mut()
        .insert("Authorization", authorization(c).parse()?);
    let (mut ws, _) = tungstenite::client_tls_with_config(
        request,
        tcp,
        Some(
            tungstenite::protocol::WebSocketConfig::default()
                .max_message_size(Some(8 * 1024 * 1024)),
        ),
        Some(tungstenite::Connector::NativeTls(tls)),
    )
    .map_err(|_| anyhow::anyhow!("WebSocketUnavailable"))?;
    ws.send(Message::Text(
        json!([5, "OnJsonApiEvent"]).to_string().into(),
    ))?;
    if let tungstenite::stream::MaybeTlsStream::NativeTls(s) = ws.get_mut() {
        s.get_mut()
            .set_read_timeout(Some(Duration::from_millis(100)))?;
    }
    cache.lock().unwrap().clear();
    alive.store(true, Ordering::Release);
    let _ = wake.try_send(());
    while !stop.load(Ordering::Acquire) && !expired.load(Ordering::Acquire) {
        match ws.read() {
            Ok(Message::Text(text)) => {
                if let Ok(v) = serde_json::from_str::<Value>(&text) {
                    if v[0] != 8 {
                        continue;
                    }
                    let event = &v[2];
                    let Some(path) = event["uri"].as_str() else {
                        continue;
                    };
                    if SLOTS.contains(&path) {
                        cache.lock().unwrap().apply(
                            path,
                            Response {
                                status: if event["eventType"] == "Delete" {
                                    404
                                } else {
                                    200
                                },
                                data: event["data"].clone(),
                            },
                        );
                        let _ = wake.try_send(());
                    }
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(_) => {}
            Err(tungstenite::Error::Io(e))
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(_) => break,
        }
    }
    Ok(())
}
