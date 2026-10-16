use serde::Serialize;
use std::{
    collections::VecDeque,
    fs,
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{Arc, Mutex},
    thread,
    time::{Duration, Instant},
};

#[derive(Clone, Serialize)]
pub struct Log {
    pub id: u64,
    pub message: String,
}
type Logs = Arc<Mutex<(u64, VecDeque<Log>)>>;
pub struct Runtime {
    child: Option<Child>,
    active_id: Option<String>,
    started: Option<Instant>,
    logs: Logs,
    config_path: PathBuf,
}
#[derive(Serialize)]
pub struct Status {
    pub running: bool,
    pub active_id: Option<String>,
    pub uptime: u64,
    pub logs: Vec<Log>,
}
impl Runtime {
    pub fn new(directory: &Path) -> Self {
        Self {
            child: None,
            active_id: None,
            started: None,
            logs: Arc::new(Mutex::new((0, VecDeque::new()))),
            config_path: directory.join("runtime.json"),
        }
    }
    pub fn log(&self, message: &str) {
        append(&self.logs, message.to_string());
    }
    pub fn running(&mut self) -> bool {
        if let Some(child) = self.child.as_mut() {
            match child.try_wait() {
                Ok(None) => return true,
                Ok(Some(status)) => self.log(&format!("Core exited: {status}")),
                Err(e) => self.log(&format!("Cannot inspect core: {e}")),
            }
            self.child = None;
            self.active_id = None;
            self.started = None;
            let _ = fs::remove_file(&self.config_path);
        }
        false
    }
    pub fn status(&mut self) -> Status {
        let running = self.running();
        Status {
            running,
            active_id: self.active_id.clone(),
            uptime: self.started.map(|i| i.elapsed().as_secs()).unwrap_or(0),
            logs: self.logs.lock().unwrap().1.iter().cloned().collect(),
        }
    }
    pub fn start(
        &mut self,
        executable: &Path,
        config: &serde_json::Value,
        id: &str,
    ) -> Result<(), String> {
        if self.running() {
            return Err("Disconnect before switching profiles or settings".into());
        }
        crate::store::write_private(
            &self.config_path,
            &serde_json::to_vec_pretty(config).map_err(|e| e.to_string())?,
        )?;
        let result = self.launch(executable, id);
        if result.is_err() {
            let _ = fs::remove_file(&self.config_path);
        }
        result
    }
    fn launch(&mut self, executable: &Path, id: &str) -> Result<(), String> {
        if !executable.is_file() {
            return Err("The proxy core is missing. Reinstall Wontun or reset the custom core override in Settings.".into());
        }
        let mut check = Command::new(executable)
            .args(["check", "-c"])
            .arg(&self.config_path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| e.to_string())?;
        let stdout = capture(check.stdout.take().unwrap());
        let stderr = capture(check.stderr.take().unwrap());
        let deadline = Instant::now() + Duration::from_secs(15);
        let status = loop {
            match check.try_wait().map_err(|e| e.to_string())? {
                Some(s) => break s,
                None if Instant::now() >= deadline => {
                    let _ = check.kill();
                    let _ = check.wait();
                    return Err("sing-box configuration check timed out".into());
                }
                None => thread::sleep(Duration::from_millis(25)),
            }
        };
        let detail = format!(
            "{}{}",
            stdout.join().unwrap_or_default(),
            stderr.join().unwrap_or_default()
        );
        if !status.success() {
            return Err(format!("sing-box rejected the configuration: {detail}"));
        }
        let mut child = Command::new(executable)
            .args(["run", "-c"])
            .arg(&self.config_path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| e.to_string())?;
        read_logs(child.stdout.take().unwrap(), self.logs.clone());
        read_logs(child.stderr.take().unwrap(), self.logs.clone());
        self.child = Some(child);
        self.active_id = Some(id.into());
        self.started = Some(Instant::now());
        thread::sleep(Duration::from_millis(250));
        if !self.running() {
            return Err("Core exited during startup. See Logs for details.".into());
        }
        self.log("Core process started. See core output for listener status.");
        Ok(())
    }
    pub fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            // SIGTERM lets sing-box restore system proxy settings on a normal stop.
            unsafe {
                libc::kill(child.id() as i32, libc::SIGTERM);
            }
            let deadline = Instant::now() + Duration::from_secs(3);
            loop {
                match child.try_wait() {
                    Ok(Some(_)) => break,
                    _ if Instant::now() >= deadline => {
                        let _ = child.kill();
                        let _ = child.wait();
                        self.log("Core required a forced stop; check system proxy settings.");
                        break;
                    }
                    _ => thread::sleep(Duration::from_millis(20)),
                }
            }
            self.log("Core stopped");
        }
        self.active_id = None;
        self.started = None;
        let _ = fs::remove_file(&self.config_path);
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        self.stop();
    }
}
fn append(logs: &Logs, message: String) {
    let mut guard = logs.lock().unwrap();
    guard.0 += 1;
    let id = guard.0;
    guard.1.push_back(Log {
        id,
        message: message.chars().take(4096).collect(),
    });
    while guard.1.len() > 500 {
        guard.1.pop_front();
    }
}
fn read_logs(reader: impl Read + Send + 'static, logs: Logs) {
    thread::spawn(move || {
        let mut reader = BufReader::new(reader);
        loop {
            let mut bytes = Vec::new();
            match reader.by_ref().take(4096).read_until(b'\n', &mut bytes) {
                Ok(0) | Err(_) => break,
                _ => append(
                    &logs,
                    String::from_utf8_lossy(&bytes).trim_end().to_string(),
                ),
            }
        }
    });
}
fn capture(reader: impl Read + Send + 'static) -> thread::JoinHandle<String> {
    thread::spawn(move || {
        let mut text = Vec::new();
        let mut reader = reader;
        let _ = reader.by_ref().take(65536).read_to_end(&mut text);
        let _ = std::io::copy(&mut reader, &mut std::io::sink());
        String::from_utf8_lossy(&text).into_owned()
    })
}
