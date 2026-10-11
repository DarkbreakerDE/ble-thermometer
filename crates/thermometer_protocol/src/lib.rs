//! Transport-free, event-driven thermometer protocols.
//! No BLE stack, platform API, timers, or threads are used by a driver.
pub mod model;
pub mod ovy;

pub use model::*;
pub use ovy::OvyOt35;

pub trait ThermometerDriver: Send {
    fn model(&self) -> &'static str;
    fn handle(&mut self, input: DriverInput) -> DriverOutput;
}

pub fn create_driver(model: &str, mode: SessionMode) -> Result<Box<dyn ThermometerDriver>, String> {
    match model {
        "ovy_ot35" => Ok(Box::new(OvyOt35::new(mode))),
        _ => Err(format!("Unsupported thermometer model: {model}")),
    }
}
