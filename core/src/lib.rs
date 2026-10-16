pub mod config;
pub mod import;
pub mod model;
pub mod runtime;
pub mod store;

use model::{State, Subscription};
use serde_json::{json, Value};
use std::{
    io::Read,
    path::PathBuf,
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

pub struct App {
    pub state: State,
    store: store::Store,
    runtime: runtime::Runtime,
}
impl App {
    pub fn open(directory: PathBuf) -> Result<Self, String> {
        let (store, mut state) = store::Store::open(directory.clone())?;
        if state.settings.migrate_core_path() {
            store.save(&state)?;
        }
        Ok(Self {
            state,
            store,
            runtime: runtime::Runtime::new(&directory),
        })
    }
    fn commit(&mut self, next: State) -> Result<(), String> {
        self.store.save(&next)?;
        self.state = next;
        Ok(())
    }
    fn editable(&mut self) -> Result<(), String> {
        if self.runtime.running() {
            Err("Disconnect before editing profiles, subscriptions, or settings".into())
        } else {
            Ok(())
        }
    }
    pub fn handle(&mut self, request: &Value) -> Result<Value, String> {
        self.handle_with_fetch(request, fetch)
    }
    fn handle_with_fetch(
        &mut self,
        request: &Value,
        download: impl FnOnce(&str) -> Result<String, String>,
    ) -> Result<Value, String> {
        let command = string(request, "command")?;
        match command {
            "snapshot" => {}
            "import" => {
                self.editable()?;
                let profiles = import::parse(string(request, "content")?)?;
                let mut next = self.state.clone();
                for mut profile in profiles {
                    if next.profiles.iter().any(|p| {
                        p.subscription_id.is_none()
                            && p.outbound == profile.outbound
                            && p.full_config == profile.full_config
                            && p.name == profile.name
                    }) {
                        continue;
                    }
                    profile.id = next.id();
                    if next.selected_id.is_none() {
                        next.selected_id = Some(profile.id.clone());
                    }
                    next.profiles.push(profile);
                }
                self.commit(next)?;
            }
            "select" => {
                let id = string(request, "id")?;
                if !self.state.profiles.iter().any(|p| p.id == id) {
                    return Err("Profile no longer exists".into());
                }
                let mut next = self.state.clone();
                next.selected_id = Some(id.into());
                self.commit(next)?;
            }
            "delete_profile" => {
                self.editable()?;
                let id = string(request, "id")?;
                let mut next = self.state.clone();
                next.profiles.retain(|p| p.id != id);
                repair_selection(&mut next);
                self.commit(next)?;
            }
            "save_profile" => {
                self.editable()?;
                let id = string(request, "id")?;
                let mut parsed = import::parse(string(request, "content")?)?;
                if parsed.len() != 1 {
                    return Err("The editor accepts exactly one outbound or complete config".into());
                }
                let mut profile = parsed.remove(0);
                let name = string(request, "name")?.trim();
                if name.is_empty() {
                    return Err("Give this profile a name".into());
                }
                let mut next = self.state.clone();
                let original = next
                    .profiles
                    .iter_mut()
                    .find(|p| p.id == id)
                    .ok_or("Profile no longer exists")?;
                profile.id = original.id.clone();
                profile.subscription_id = original.subscription_id.clone();
                profile.name = name.into();
                *original = profile;
                self.commit(next)?;
            }
            "settings" => {
                self.editable()?;
                let settings: model::Settings = serde_json::from_value(request["settings"].clone())
                    .map_err(|e| e.to_string())?;
                settings.validate()?;
                let mut next = self.state.clone();
                next.settings = settings;
                self.commit(next)?;
            }
            "add_subscription" | "refresh_subscription" => {
                self.editable()?;
                let mut next = self.state.clone();
                let (id, name, url) = if command == "add_subscription" {
                    let name = string(request, "name")?.trim().to_string();
                    if name.is_empty() {
                        return Err("Give this subscription a name".into());
                    }
                    (next.id(), name, string(request, "url")?.to_string())
                } else {
                    let sub = next
                        .subscriptions
                        .iter()
                        .find(|s| Some(s.id.as_str()) == request["id"].as_str())
                        .ok_or("Subscription no longer exists")?;
                    (sub.id.clone(), sub.name.clone(), sub.url.clone())
                };
                let content = download(&url)?;
                let profiles = import::parse(&content)?;
                // Parse first: a failed refresh must leave the previous subscription intact.
                let mut old: Vec<_> = next
                    .profiles
                    .iter()
                    .filter(|p| p.subscription_id.as_deref() == Some(&id))
                    .cloned()
                    .collect();
                next.profiles
                    .retain(|p| p.subscription_id.as_deref() != Some(&id));
                for mut profile in profiles {
                    profile.id = old
                        .iter()
                        .position(|p| p.outbound == profile.outbound && p.name == profile.name)
                        .map(|index| old.remove(index).id)
                        .unwrap_or_else(|| next.id());
                    profile.subscription_id = Some(id.clone());
                    next.profiles.push(profile);
                }
                next.subscriptions.retain(|s| s.id != id);
                next.subscriptions.push(Subscription {
                    id,
                    name,
                    url,
                    updated_at: SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs(),
                });
                repair_selection(&mut next);
                self.commit(next)?;
            }
            "delete_subscription" => {
                self.editable()?;
                let id = string(request, "id")?;
                let mut next = self.state.clone();
                next.subscriptions.retain(|s| s.id != id);
                next.profiles
                    .retain(|p| p.subscription_id.as_deref() != Some(id));
                repair_selection(&mut next);
                self.commit(next)?;
            }
            "preview" => {
                let p = self
                    .state
                    .profiles
                    .iter()
                    .find(|p| Some(&p.id) == self.state.selected_id.as_ref())
                    .ok_or("Select a profile first")?;
                return Ok(
                    json!({"config":serde_json::to_string_pretty(&config::generate(p, &self.state.settings)?).map_err(|e| e.to_string())?}),
                );
            }
            "start" => {
                let p = self
                    .state
                    .profiles
                    .iter()
                    .find(|p| Some(&p.id) == self.state.selected_id.as_ref())
                    .ok_or("Import and select a profile first")?;
                let config = config::generate(p, &self.state.settings)?;
                let backend = std::env::current_exe().map_err(|e| e.to_string())?;
                let executable = self.state.settings.core_executable(&backend)?;
                if let Err(error) = self.runtime.start(&executable, &config, &p.id) {
                    self.runtime.log(&error);
                    return Err(error);
                }
            }
            "stop" | "shutdown" => self.runtime.stop(),
            _ => return Err(format!("Unknown command: {command}")),
        }
        Ok(json!({"state":self.state,"status":self.runtime.status()}))
    }
}
fn repair_selection(state: &mut State) {
    if !state
        .profiles
        .iter()
        .any(|p| Some(&p.id) == state.selected_id.as_ref())
    {
        state.selected_id = state.profiles.first().map(|p| p.id.clone());
    }
}
fn string<'a>(value: &'a Value, key: &str) -> Result<&'a str, String> {
    value[key]
        .as_str()
        .ok_or_else(|| format!("Missing string field: {key}"))
}
fn fetch(url: &str) -> Result<String, String> {
    let parsed = url::Url::parse(url).map_err(|_| "Invalid subscription URL")?;
    if parsed.scheme() != "https"
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return Err("Subscriptions require an HTTPS URL without embedded credentials".into());
    }
    let mut child = Command::new("/usr/bin/curl")
        .args([
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--max-redirs",
            "5",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--connect-timeout",
            "10",
            "--max-time",
            "30",
            "--max-filesize",
            "8388608",
            "--user-agent",
            "Wontun/0.1",
            "--url",
            url,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("Cannot launch curl: {e}"))?;
    let mut bytes = Vec::new();
    let read = child
        .stdout
        .take()
        .unwrap()
        .take(8 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes);
    if bytes.len() > 8 * 1024 * 1024 || read.is_err() {
        let _ = child.kill();
        let _ = child.wait();
        return Err("Subscription exceeds the 8 MiB limit or could not be read".into());
    }
    if !child.wait().map_err(|e| e.to_string())?.success() {
        return Err(
            "Subscription download failed. Check the HTTPS URL and network connection.".into(),
        );
    }
    String::from_utf8(bytes).map_err(|_| "Subscription is not UTF-8".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn subscription_refresh_preserves_selection_and_rolls_back_failures() {
        let dir = tempfile::tempdir().unwrap();
        let mut app = App::open(dir.path().into()).unwrap();
        let add = json!({"command":"add_subscription","name":"Collection","url":"https://example.com/token"});
        let initial = "socks5://one.example:1080#One\ntrojan://secret@two.example:443#Two";
        app.handle_with_fetch(&add, |_| Ok(initial.into())).unwrap();
        let sub = app.state.subscriptions[0].id.clone();
        let first = app.state.profiles[0].id.clone();
        let second = app.state.profiles[1].id.clone();
        app.handle(&json!({"command":"select","id":second}))
            .unwrap();
        let refresh = json!({"command":"refresh_subscription","id":sub});
        let updated = "trojan://secret@two.example:443#Two\nsocks5://three.example:1080#Three";
        app.handle_with_fetch(&refresh, |_| Ok(updated.into()))
            .unwrap();
        assert_eq!(app.state.selected_id.as_ref(), Some(&second));
        assert!(!app.state.profiles.iter().any(|p| p.id == first));
        assert_eq!(app.state.profiles.len(), 2);
        let before = fs_state(&app);
        assert!(app
            .handle_with_fetch(&refresh, |_| Err("network unavailable".into()))
            .is_err());
        assert_eq!(fs_state(&app), before);
        assert!(app
            .handle_with_fetch(&refresh, |_| Ok(
                "socks5://good.example:1080\ninvalid://bad".into()
            ))
            .is_err());
        assert_eq!(fs_state(&app), before);
        app.handle(&json!({"command":"delete_subscription","id":sub}))
            .unwrap();
        assert!(app.state.profiles.is_empty());
        assert!(app.state.subscriptions.is_empty());
        assert!(app.state.selected_id.is_none());
    }

    #[test]
    fn repeated_subscription_entries_keep_unique_ids() {
        let dir = tempfile::tempdir().unwrap();
        let mut app = App::open(dir.path().into()).unwrap();
        let content = "socks5://same.example:1080#Same\nsocks5://same.example:1080#Same";
        app.handle_with_fetch(&json!({"command":"add_subscription","name":"Repeated","url":"https://example.com/sub"}), |_| Ok(content.into())).unwrap();
        let ids: Vec<_> = app.state.profiles.iter().map(|p| p.id.clone()).collect();
        let id = app.state.subscriptions[0].id.clone();
        app.handle_with_fetch(&json!({"command":"refresh_subscription","id":id}), |_| {
            Ok(content.into())
        })
        .unwrap();
        assert_eq!(
            app.state
                .profiles
                .iter()
                .map(|p| p.id.clone())
                .collect::<Vec<_>>(),
            ids
        );
        assert_ne!(app.state.profiles[0].id, app.state.profiles[1].id);
    }

    fn fs_state(app: &App) -> Vec<u8> {
        std::fs::read(app.store.directory.join("state.json")).unwrap()
    }
}
