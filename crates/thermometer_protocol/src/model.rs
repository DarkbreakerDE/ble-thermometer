use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionMode {
    TransferAndDisconnect,
    StayConnected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Disconnected,
    Connecting,
    Receiving,
    Ready,
    ChangingSettings,
    SynchronizingClock,
    Disconnecting,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Characteristic {
    pub service_id: String,
    pub characteristic_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BleCommand {
    pub id: u32,
    #[serde(flatten)]
    pub operation: BleOperation,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum BleOperation {
    Connect {
        characteristics: Vec<Characteristic>,
    },
    Read {
        characteristic: Characteristic,
    },
    Write {
        characteristic: Characteristic,
        data: Vec<u8>,
    },
    Subscribe {
        characteristic: Characteristic,
    },
    Disconnect,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TemperatureUnit {
    Celsius,
    Fahrenheit,
}

/// These are the current settings at transfer time, never historical settings.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThermometerSettings {
    pub unit: TemperatureUnit,
    pub sound: bool,
    pub vibration: bool,
    pub raw_flags: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DesiredSettings {
    pub unit: TemperatureUnit,
    pub sound: bool,
    pub vibration: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MeasurementTime {
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
}

/// Local civil time supplied by the caller; no timezone is encoded on the wire.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClockTime {
    pub local_time: MeasurementTime,
    /// Microseconds within the second, not within the millisecond.
    pub microsecond: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Measurement {
    pub temperature: f64,
    pub mantissa: i32,
    pub exponent: i8,
    pub unit: TemperatureUnit,
    pub time: MeasurementTime,
    pub temperature_type: u8,
    pub raw: Vec<u8>,
    pub current_settings: ThermometerSettings,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MeasurementTransfer {
    pub measurements: Vec<Measurement>,
    pub current_settings: ThermometerSettings,
    pub battery_percent: u8,
    pub reported_count: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DriverErrorKind {
    Busy,
    Unsupported,
    InvalidState,
    InvalidArgument,
    Protocol,
    Transport,
    Timeout,
    Disconnected,
    SettingsMismatch,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DriverEvent {
    /// The time write and blink ACK succeeded; device clock readback is unverified.
    ClockSynchronized {
        requested_time: ClockTime,
        blink_confirmed: bool,
    },
    TransferCompleted {
        transfer: MeasurementTransfer,
    },
    SettingsChanged {
        settings: ThermometerSettings,
        changed: bool,
        blink_confirmed: bool,
    },
    Error {
        kind: DriverErrorKind,
        message: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DriverOutput {
    pub state: SessionState,
    pub commands: Vec<BleCommand>,
    pub events: Vec<DriverEvent>,
    /// Flutter supplies a transfer inactivity timer; no time is read in Rust.
    pub waiting_for_transfer: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum DriverInput {
    Start {
        clock: Option<ClockTime>,
    },
    CommandResult {
        command_id: u32,
        #[serde(default)]
        data: Vec<u8>,
        error: Option<String>,
    },
    Notification {
        characteristic: Characteristic,
        data: Vec<u8>,
    },
    Disconnected {
        reason: String,
    },
    CommandTimeout {
        command_id: u32,
    },
    TransferTimeout,
    Fetch,
    SetSettings {
        settings: DesiredSettings,
    },
    SyncClock {
        time: ClockTime,
    },
    Close,
    /// Unsupported protocol operations are explicit, never guessed writes.
    StartMeasurement,
    FetchMeasurementByIndex {
        index: u32,
    },
}
