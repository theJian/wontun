use crate::model::{Profile, Settings};
use serde_json::{json, Value};

pub fn generate(profile: &Profile, settings: &Settings) -> Result<Value, String> {
    settings.validate()?;
    if profile.full_config {
        return Ok(profile.outbound.clone());
    }
    let mut rules = vec![];
    if settings.route_mode == "rules" {
        if !settings.blocked_domains.is_empty() {
            rules.push(json!({"domain_suffix":settings.blocked_domains,"action":"reject"}));
        }
        if settings.bypass_private {
            rules.push(json!({"ip_is_private":true,"action":"route","outbound":"direct"}));
        }
        if !settings.direct_domains.is_empty() {
            rules.push(json!({"domain_suffix":settings.direct_domains,"action":"route","outbound":"direct"}));
        }
    }
    let mut outbound = profile.outbound.clone();
    outbound["tag"] = json!("proxy");
    Ok(json!({
        "log":{"level":"info","timestamp":true,"disabled":false},
        "dns":{"servers":[{"type":"local","tag":"local"}]},
        "inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":settings.mixed_port,"set_system_proxy":settings.system_proxy}],
        "outbounds":[outbound,{"type":"direct","tag":"direct"}],
        "route":{"rules":rules,"final":if settings.route_mode == "direct" { "direct" } else { "proxy" },"auto_detect_interface":true,"default_domain_resolver":"local"}
    }))
}
