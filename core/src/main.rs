use serde_json::{json, Value};
use std::{
    io::{self, BufRead, Read, Write},
    path::PathBuf,
};
fn main() {
    if let Err(e) = serve() {
        eprintln!("Wontun: {e}");
        std::process::exit(1);
    }
}
fn serve() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let directory = match (args.next().as_deref(), args.next(), args.next()) {
        (Some("--data-dir"), Some(path), None) => PathBuf::from(path),
        _ => return Err("Usage: wontun-core --data-dir PATH".into()),
    };
    let mut app = wontun_core::App::open(directory)?;
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    loop {
        let mut line = Vec::new();
        let length = input
            .by_ref()
            .take(8 * 1024 * 1024 + 1)
            .read_until(b'\n', &mut line)
            .map_err(|e| e.to_string())?;
        if length == 0 {
            break;
        }
        if length > 8 * 1024 * 1024 {
            return Err("Request exceeds 8 MiB".into());
        }
        let request: Result<Value, _> = serde_json::from_slice(&line);
        let shutdown = request
            .as_ref()
            .ok()
            .is_some_and(|v| v["command"] == "shutdown");
        let response = match request
            .map_err(|e| e.to_string())
            .and_then(|v| app.handle(&v))
        {
            Ok(value) => json!({"ok":true,"result":value}),
            Err(error) => json!({"ok":false,"error":error}),
        };
        serde_json::to_writer(&mut output, &response).map_err(|e| e.to_string())?;
        output
            .write_all(b"\n")
            .and_then(|_| output.flush())
            .map_err(|e| e.to_string())?;
        if shutdown {
            break;
        }
    }
    Ok(())
}
