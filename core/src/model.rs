use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub protocol: String,
    pub server: String,
    pub subscription_id: Option<String>,
    pub outbound: Value,
    #[serde(default)]
    pub full_config: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Subscription {
    pub id: String,
    pub name: String,
    pub url: String,
    pub updated_at: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub core_path: String,
    pub mixed_port: u16,
    pub system_proxy: bool,
    pub route_mode: String,
    pub bypass_private: bool,
    pub direct_domains: Vec<String>,
    pub blocked_domains: Vec<String>,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            core_path: String::new(),
            mixed_port: 2080,
            system_proxy: false,
            route_mode: "rules".into(),
            bypass_private: true,
            direct_domains: vec![],
            blocked_domains: vec![],
        }
    }
}
impl Settings {
    pub fn core_executable(&self, backend: &std::path::Path) -> Result<std::path::PathBuf, String> {
        if !self.core_path.is_empty() {
            return Ok(self.core_path.clone().into());
        }
        backend
            .parent()
            .map(|parent| parent.join("sing-box"))
            .ok_or_else(|| "Cannot locate the bundled proxy core".into())
    }

    pub fn migrate_core_path(&mut self) -> bool {
        if ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
            .contains(&self.core_path.as_str())
        {
            self.core_path.clear();
            return true;
        }
        false
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.mixed_port == 0 {
            return Err("Proxy port must be between 1 and 65535".into());
        }
        if !self.core_path.is_empty() && !std::path::Path::new(&self.core_path).is_absolute() {
            return Err("Choose the absolute path to your sing-box executable".into());
        }
        if !["rules", "global", "direct"].contains(&self.route_mode.as_str()) {
            return Err("Unknown routing mode".into());
        }
        for domain in self.direct_domains.iter().chain(&self.blocked_domains) {
            if domain.is_empty() || domain.contains(['/', ':', ' ', '\n']) {
                return Err(format!("Invalid domain suffix: {domain}"));
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct State {
    pub profiles: Vec<Profile>,
    pub subscriptions: Vec<Subscription>,
    pub settings: Settings,
    pub selected_id: Option<String>,
    pub next_id: u64,
}
impl State {
    pub fn id(&mut self) -> String {
        self.next_id += 1;
        self.next_id.to_string()
    }
}
