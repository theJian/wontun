use crate::model::Profile;
use base64::{
    engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD},
    Engine,
};
use percent_encoding::percent_decode_str;
use serde_json::{json, Value};
use url::Url;

fn decode(s: &str) -> Result<String, String> {
    [STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD]
        .iter()
        .find_map(|e| e.decode(s).ok())
        .and_then(|v| String::from_utf8(v).ok())
        .ok_or_else(|| "Invalid base64 content".into())
}
fn unescape(s: &str) -> String {
    percent_decode_str(s).decode_utf8_lossy().into_owned()
}
fn required(v: &Value, key: &str) -> Result<(), String> {
    if v.get(key).and_then(Value::as_str).is_none_or(str::is_empty) {
        return Err(format!("Missing {key}"));
    }
    Ok(())
}
fn profile(mut outbound: Value, full_config: bool) -> Result<Profile, String> {
    let protocol = if full_config {
        "config"
    } else {
        required(&outbound, "type")?;
        outbound["type"].as_str().unwrap()
    }
    .to_string();
    if !full_config {
        if outbound.get("server").is_some() {
            required(&outbound, "server")?;
            if outbound["server_port"]
                .as_u64()
                .is_none_or(|p| p == 0 || p > 65535)
            {
                return Err("Missing or invalid server port".into());
            }
        }
        if outbound.get("detour").is_some() {
            return Err(
                "Import dependent outbounds as a complete sing-box config with inbounds".into(),
            );
        }
    }
    let name = outbound
        .get("tag")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or(if full_config {
            "Custom configuration"
        } else {
            &protocol
        })
        .to_string();
    let server = outbound
        .get("server")
        .and_then(Value::as_str)
        .unwrap_or("Custom")
        .to_string();
    if !full_config {
        outbound["tag"] = json!("proxy");
    }
    Ok(Profile {
        id: String::new(),
        name,
        protocol,
        server,
        subscription_id: None,
        outbound,
        full_config,
    })
}

pub fn parse(input: &str) -> Result<Vec<Profile>, String> {
    let input = input.trim_start_matches('\u{feff}').trim();
    if input.is_empty() {
        return Err("Paste share links, a base64 subscription, or sing-box JSON".into());
    }
    if input.starts_with('{') || input.starts_with('[') {
        let value: Value = serde_json::from_str(input).map_err(|e| format!("Invalid JSON: {e}"))?;
        let items = if value.get("inbounds").is_some() {
            return Ok(vec![profile(value, true)?]);
        } else if let Some(items) = value.as_array() {
            items.clone()
        } else if let Some(items) = value.get("outbounds").and_then(Value::as_array) {
            items.clone()
        } else {
            vec![value]
        };
        if items.is_empty() {
            return Err("No outbounds found".into());
        }
        return items.into_iter().map(|v| profile(v, false)).collect();
    }
    let decoded;
    let text = if !input.contains("://") {
        decoded = decode(&input.split_whitespace().collect::<String>())?;
        decoded.as_str()
    } else {
        input
    };
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .enumerate()
        .map(|(i, l)| share(l).map_err(|e| format!("Line {}: {e}", i + 1)))
        .collect::<Result<Vec<_>, _>>()
        .and_then(|p| {
            if p.is_empty() {
                Err("No profiles found".into())
            } else {
                Ok(p)
            }
        })
}

fn share(link: &str) -> Result<Profile, String> {
    if let Some(body) = link.strip_prefix("vmess://") {
        return vmess(body);
    }
    let normalized;
    let link = if let Some(body) = link
        .strip_prefix("ss://")
        .filter(|s| !s.split('#').next().unwrap_or("").contains('@'))
    {
        let (body, fragment) = body.split_once('#').unwrap_or((body, ""));
        normalized = format!("ss://{}#{}", decode(body)?, fragment);
        normalized.as_str()
    } else {
        link
    };
    let url = Url::parse(link).map_err(|_| "Invalid share URL".to_string())?;
    let scheme = match url.scheme() {
        "ss" => "shadowsocks",
        "socks5" | "socks4" => "socks",
        "https" => "http",
        "hy2" => "hysteria2",
        s => s,
    };
    if ![
        "shadowsocks",
        "socks",
        "http",
        "vless",
        "trojan",
        "hysteria2",
        "tuic",
        "anytls",
    ]
    .contains(&scheme)
    {
        return Err(format!(
            "Unsupported share scheme {}; use sing-box JSON instead",
            url.scheme()
        ));
    }
    let host = url
        .host_str()
        .ok_or("Missing server")?
        .trim_matches(['[', ']']);
    let port = url
        .port()
        .or_else(|| url.port_or_known_default())
        .unwrap_or(match scheme {
            "socks" => 1080,
            _ => 443,
        });
    if port == 0 {
        return Err("Invalid server port".into());
    }
    let query: std::collections::HashMap<_, _> = url
        .query_pairs()
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    let get = |key: &str| query.get(key).map(String::as_str).unwrap_or("");
    let mut o = json!({"type":scheme, "server":host,"server_port":port,"tag":url.fragment().map(unescape).unwrap_or_else(|| host.to_string())});
    let username = unescape(url.username());
    let password = url.password().map(unescape).unwrap_or_default();
    match scheme {
        "shadowsocks" => {
            let credentials = if password.is_empty() {
                decode(&username)?
            } else {
                format!("{username}:{password}")
            };
            let (method, password) = credentials
                .split_once(':')
                .ok_or("Missing Shadowsocks method/password")?;
            if method.is_empty() || password.is_empty() {
                return Err("Missing Shadowsocks credentials".into());
            }
            o["method"] = json!(method);
            o["password"] = json!(password);
            if !get("plugin").is_empty() {
                let (plugin, opts) = get("plugin").split_once(';').unwrap_or((get("plugin"), ""));
                o["plugin"] = json!(plugin);
                o["plugin_opts"] = json!(opts);
            }
        }
        "socks" | "http" => {
            if !username.is_empty() {
                o["username"] = json!(username);
                o["password"] = json!(password);
            }
            if scheme == "socks" {
                o["version"] = json!(if url.scheme() == "socks4" { "4" } else { "5" });
            }
        }
        "vless" | "tuic" => {
            if username.is_empty() {
                return Err("Missing UUID".into());
            }
            o["uuid"] = json!(username);
            if scheme == "tuic" {
                o["password"] = json!(password);
                o["congestion_control"] = json!(if get("congestion_control").is_empty() {
                    "cubic"
                } else {
                    get("congestion_control")
                });
            }
            if !get("flow").is_empty() {
                o["flow"] = json!(get("flow"));
            }
        }
        _ => {
            if username.is_empty() {
                return Err("Missing password".into());
            }
            o["password"] = json!(if password.is_empty() {
                username
            } else {
                format!("{username}:{password}")
            });
        }
    }
    let security = get("security");
    if security == "tls"
        || security == "reality"
        || ["trojan", "hysteria2", "tuic", "anytls"].contains(&scheme)
        || url.scheme() == "https"
    {
        let mut tls = json!({"enabled":true,"server_name":if get("sni").is_empty() { host } else { get("sni") }});
        if get("allowInsecure") == "1" || get("insecure") == "1" {
            tls["insecure"] = json!(true);
        }
        if !get("alpn").is_empty() {
            tls["alpn"] = json!(get("alpn").split(',').collect::<Vec<_>>());
        }
        if !get("fp").is_empty() {
            tls["utls"] = json!({"enabled":true,"fingerprint":get("fp")});
        }
        if security == "reality" {
            if get("pbk").is_empty() {
                return Err("Reality requires a public key (pbk)".into());
            }
            tls["reality"] = json!({"enabled":true,"public_key":get("pbk"),"short_id":get("sid")});
        }
        o["tls"] = tls;
    }
    match get("type") {
        "" | "tcp" => {}
        "ws" => {
            o["transport"] = json!({"type":"ws","path":get("path"),"headers":{"Host":get("host")}});
        }
        "grpc" => {
            o["transport"] = json!({"type":"grpc","service_name":get("serviceName")});
        }
        "http" | "h2" => {
            o["transport"] = json!({"type":"http","host":get("host").split(',').filter(|s| !s.is_empty()).collect::<Vec<_>>(),"path":get("path")});
        }
        other => {
            return Err(format!(
                "Unsupported transport {other}; import its sing-box JSON"
            ))
        }
    }
    if !get("obfs").is_empty() {
        o["obfs"] = json!({"type":get("obfs"),"password":get("obfs-password")});
    }
    profile(o, false)
}

fn vmess(body: &str) -> Result<Profile, String> {
    let v: Value = serde_json::from_str(&decode(body)?).map_err(|_| "Invalid VMess JSON")?;
    for k in ["add", "id"] {
        required(&v, k)?;
    }
    let port = v["port"]
        .as_u64()
        .or_else(|| v["port"].as_str()?.parse().ok())
        .ok_or("Missing VMess port")?;
    let mut o = json!({"type":"vmess","tag":v["ps"].as_str().unwrap_or("VMess"),"server":v["add"],"server_port":port,"uuid":v["id"],"security":v["scy"].as_str().unwrap_or("auto"),"alter_id":v["aid"].as_u64().or_else(|| v["aid"].as_str()?.parse().ok()).unwrap_or(0)});
    if v["tls"].as_str() == Some("tls") {
        o["tls"] = json!({"enabled":true,"server_name":v["sni"].as_str().filter(|s| !s.is_empty()).unwrap_or(v["add"].as_str().unwrap())});
    }
    match v["net"].as_str().unwrap_or("tcp") {
        "tcp" | "" => {}
        "ws" => {
            o["transport"] = json!({"type":"ws","path":v["path"].as_str().unwrap_or("/"),"headers":{"Host":v["host"].as_str().unwrap_or("")}});
        }
        "grpc" => {
            o["transport"] = json!({"type":"grpc","service_name":v["path"].as_str().unwrap_or("")});
        }
        other => return Err(format!("Unsupported VMess transport {other}")),
    }
    profile(o, false)
}
