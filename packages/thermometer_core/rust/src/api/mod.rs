//! Versioned JSON envelope keeps transport DTOs independent of bridge codegen.
use std::{
    collections::HashMap,
    sync::{Mutex, OnceLock},
};
use thermometer_protocol::{create_driver, DriverInput, SessionMode, ThermometerDriver};

struct Registry {
    next: u32,
    sessions: HashMap<u32, Box<dyn ThermometerDriver>>,
}
fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        Mutex::new(Registry {
            next: 1,
            sessions: HashMap::new(),
        })
    })
}

pub fn create_session(model: String, mode: String) -> Result<u32, String> {
    let mode: SessionMode =
        serde_json::from_value(serde_json::Value::String(mode)).map_err(|e| e.to_string())?;
    let driver = create_driver(&model, mode)?;
    let mut registry = registry().lock().map_err(|_| "Session registry poisoned")?;
    let id = registry.next;
    registry.next = id.checked_add(1).ok_or("Session identifier exhausted")?;
    registry.sessions.insert(id, driver);
    Ok(id)
}

pub fn dispatch(session_id: u32, input: String) -> Result<String, String> {
    let input: DriverInput = serde_json::from_str(&input).map_err(|e| e.to_string())?;
    let mut registry = registry().lock().map_err(|_| "Session registry poisoned")?;
    let driver = registry
        .sessions
        .get_mut(&session_id)
        .ok_or("Unknown or disposed session")?;
    serde_json::to_string(&driver.handle(input)).map_err(|e| e.to_string())
}

pub fn dispose_session(session_id: u32) -> Result<(), String> {
    registry()
        .lock()
        .map_err(|_| "Session registry poisoned")?
        .sessions
        .remove(&session_id);
    Ok(())
}
