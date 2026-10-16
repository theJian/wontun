use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::json;
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    os::unix::fs::{MetadataExt, PermissionsExt},
    process::{Command, Stdio},
};
use wontun_core::{config, import, model::Settings, App};

#[test]
fn share_formats_preserve_credentials_tls_and_transport() {
    let profiles = import::parse("vless://1234@example.com:443?security=reality&pbk=public&sid=abcd&type=ws&path=%2Fproxy&host=cdn.example.com&fp=chrome#Tokyo%20One\ntrojan://secret%3Avalue@proxy.example:443?sni=example.com#Trojan").unwrap();
    assert_eq!(profiles[0].name, "Tokyo One");
    assert_eq!(
        profiles[0].outbound["tls"]["reality"]["public_key"],
        "public"
    );
    assert_eq!(profiles[0].outbound["transport"]["path"], "/proxy");
    assert_eq!(profiles[1].outbound["password"], "secret:value");
    assert_eq!(profiles[1].outbound["tls"]["enabled"], true);
    let ss = format!(
        "ss://{}@example.com:8388#SS",
        STANDARD.encode("aes-256-gcm:p:a:ss")
    );
    assert_eq!(
        import::parse(&ss).unwrap()[0].outbound["password"],
        "p:a:ss"
    );
    let legacy = format!(
        "ss://{}#Old",
        STANDARD.encode("aes-256-gcm:secret@example.com:8388")
    );
    assert_eq!(import::parse(&legacy).unwrap()[0].server, "example.com");
    assert_eq!(
        import::parse("socks5://u:p@[::1]:1080#IPv6").unwrap()[0].server,
        "::1"
    );
    let vmess = STANDARD.encode(json!({"v":"2","ps":"VMess","add":"example.com","port":"443","id":"uuid","aid":"0","net":"ws","tls":"tls","path":"/ws"}).to_string());
    let profile = &import::parse(&format!("vmess://{vmess}")).unwrap()[0];
    assert_eq!(profile.outbound["server_port"], 443);
    assert_eq!(profile.outbound["transport"]["type"], "ws");
}

#[test]
fn subscriptions_and_json_are_all_or_nothing() {
    let text = "socks5://a.example:1080#One\ntrojan://secret@b.example:443#Two";
    assert_eq!(import::parse(&STANDARD.encode(text)).unwrap().len(), 2);
    assert!(import::parse("socks5://a.example:1080\ninvalid://x").is_err());
    assert!(import::parse(r#"{"outbounds":[]}"#).is_err());
    assert!(import::parse("vless://uuid@x:443?type=xhttp").is_err());
    assert!(import::parse(r#"{"type":"socks","server":"a","server_port":0}"#).is_err());
    assert!(
        import::parse(r#"{"type":"socks","server":"a","server_port":1,"detour":"another"}"#)
            .is_err()
    );
    let full = json!({"inbounds":[],"outbounds":[{"type":"direct","tag":"custom"}],"route":{"final":"custom"}});
    let p = import::parse(&full.to_string()).unwrap().remove(0);
    assert!(p.full_config);
    assert_eq!(config::generate(&p, &Settings::default()).unwrap(), full);
}

#[test]
fn routing_obeys_modes_and_block_precedence() {
    let profile = import::parse("socks5://example.com:1080")
        .unwrap()
        .remove(0);
    let mut settings = Settings {
        direct_domains: vec!["example.com".into()],
        blocked_domains: vec!["ads.example.com".into()],
        ..Default::default()
    };
    let config = config::generate(&profile, &settings).unwrap();
    assert_eq!(config["inbounds"][0]["listen"], "127.0.0.1");
    assert_eq!(config["route"]["rules"][0]["action"], "reject");
    assert_eq!(config["route"]["rules"][2]["outbound"], "direct");
    settings.route_mode = "global".into();
    assert_eq!(
        config::generate(&profile, &settings).unwrap()["route"]["rules"],
        json!([])
    );
    settings.route_mode = "direct".into();
    assert_eq!(
        config::generate(&profile, &settings).unwrap()["route"]["final"],
        "direct"
    );
    settings.mixed_port = 0;
    assert!(config::generate(&profile, &settings).is_err());
}

#[test]
fn state_is_private_atomic_and_survives_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let mut app = App::open(dir.path().into()).unwrap();
    assert!(App::open(dir.path().into()).is_err());
    app.handle(&json!({"command":"import","content":"socks5://example.com:1080#Local"}))
        .unwrap();
    let id = app.state.selected_id.clone().unwrap();
    assert_eq!(app.state.profiles.len(), 1);
    assert!(app
        .handle(&json!({"command":"import","content":"socks5://good.example:1080\nbad://input"}))
        .is_err());
    assert_eq!(app.state.profiles.len(), 1);
    let state = fs::read(dir.path().join("state.json")).unwrap();
    assert_eq!(
        fs::metadata(dir.path().join("state.json")).unwrap().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(dir.path()).unwrap().permissions().mode() & 0o777,
        0o700
    );
    // A failed refresh/download cannot alter the saved state.
    assert!(app
        .handle(&json!({"command":"add_subscription","name":"Test","url":"http://example.com"}))
        .is_err());
    assert_eq!(fs::read(dir.path().join("state.json")).unwrap(), state);
    drop(app);
    let mut app = App::open(dir.path().into()).unwrap();
    assert_eq!(app.state.selected_id.as_ref(), Some(&id));
    app.handle(&json!({"command":"delete_profile","id":id}))
        .unwrap();
    assert!(app.state.selected_id.is_none());
}

fn fake_core(dir: &std::path::Path, body: &str) -> String {
    let path = dir.join("fake-sing-box");
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    path.to_str().unwrap().into()
}

#[test]
fn core_lifecycle_reports_logs_exit_and_cleans_credentials() {
    let dir = tempfile::tempdir().unwrap();
    let path = fake_core(dir.path(), "if [ \"$1\" = check ]; then exit 0; fi\necho 'fake core started'\ntrap 'exit 0' TERM\nwhile :; do sleep 0.1; done");
    let mut app = App::open(dir.path().join("data")).unwrap();
    app.handle(&json!({"command":"import","content":"socks5://example.com:1080"}))
        .unwrap();
    let settings = Settings {
        core_path: path,
        ..Default::default()
    };
    app.handle(&json!({"command":"settings","settings":settings}))
        .unwrap();
    let running = app.handle(&json!({"command":"start"})).unwrap();
    assert_eq!(running["status"]["running"], true);
    assert!(running["status"]["logs"]
        .as_array()
        .unwrap()
        .iter()
        .any(|l| l["message"] == "fake core started"));
    assert!(app
        .handle(&json!({"command":"delete_profile","id":app.state.profiles[0].id}))
        .is_err());
    assert!(dir.path().join("data/runtime.json").exists());
    let stopped = app.handle(&json!({"command":"stop"})).unwrap();
    assert_eq!(stopped["status"]["running"], false);
    assert!(!dir.path().join("data/runtime.json").exists());
}

#[test]
fn failed_configuration_never_reports_running() {
    let dir = tempfile::tempdir().unwrap();
    let path = fake_core(dir.path(), "echo 'bad configuration' >&2\nexit 1");
    let mut app = App::open(dir.path().join("data")).unwrap();
    app.handle(&json!({"command":"import","content":"socks5://example.com:1080"}))
        .unwrap();
    app.handle(&json!({"command":"settings","settings":Settings { core_path: path, ..Default::default() }})).unwrap();
    let error = app.handle(&json!({"command":"start"})).unwrap_err();
    assert!(error.contains("bad configuration"));
    assert_eq!(
        app.handle(&json!({"command":"snapshot"})).unwrap()["status"]["running"],
        false
    );
    assert!(!dir.path().join("data/runtime.json").exists());
}

#[test]
fn json_lines_protocol_recovers_from_bad_requests_and_stops_on_eof() {
    let dir = tempfile::tempdir().unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_wontun-core"))
        .args(["--data-dir", dir.path().to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(stdin, "not-json").unwrap();
    writeln!(
        stdin,
        "{}",
        json!({"command":"import","content":"socks5://example.com:1080#Pipe"})
    )
    .unwrap();
    drop(stdin);
    let lines: Vec<_> = BufReader::new(child.stdout.take().unwrap())
        .lines()
        .map(|l| serde_json::from_str::<serde_json::Value>(&l.unwrap()).unwrap())
        .collect();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0]["ok"], false);
    assert_eq!(lines[1]["result"]["state"]["profiles"][0]["name"], "Pipe");
    assert!(child.wait().unwrap().success());
}

#[test]
fn bundled_core_resolves_after_relocation_and_custom_override_is_explicit() {
    let mut settings = Settings::default();
    settings.validate().unwrap();
    for parent in [
        "/Applications/Wontun.app/Contents/MacOS",
        "/tmp/Moved Wontun.app/Contents/MacOS",
    ] {
        let backend = std::path::Path::new(parent).join("wontun-core");
        assert_eq!(
            settings.core_executable(&backend).unwrap(),
            std::path::Path::new(parent).join("sing-box")
        );
    }
    settings.core_path = "/tmp/custom-sing-box".into();
    assert_eq!(
        settings
            .core_executable(std::path::Path::new("/tmp/other/wontun-core"))
            .unwrap(),
        std::path::Path::new("/tmp/custom-sing-box")
    );
    settings.core_path = "relative-core".into();
    assert!(settings.validate().is_err());
}

#[test]
fn old_homebrew_default_migrates_without_losing_profiles_or_routes() {
    for legacy in ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"] {
        let dir = tempfile::tempdir().unwrap();
        let mut app = App::open(dir.path().into()).unwrap();
        app.handle(&json!({"command":"import","content":"socks5://example.com:1080#Keep"}))
            .unwrap();
        let settings = Settings {
            core_path: legacy.into(),
            mixed_port: 9999,
            direct_domains: vec!["example.com".into()],
            ..Default::default()
        };
        app.handle(&json!({"command":"settings","settings":settings}))
            .unwrap();
        let selected = app.state.selected_id.clone();
        drop(app);
        let app = App::open(dir.path().into()).unwrap();
        assert!(app.state.settings.core_path.is_empty());
        assert_eq!(app.state.settings.mixed_port, 9999);
        assert_eq!(app.state.settings.direct_domains, ["example.com"]);
        assert_eq!(app.state.selected_id, selected);
        assert_eq!(app.state.profiles[0].name, "Keep");
        let saved: serde_json::Value =
            serde_json::from_slice(&fs::read(dir.path().join("state.json")).unwrap()).unwrap();
        assert_eq!(saved["settings"]["core_path"], "");
    }
}
