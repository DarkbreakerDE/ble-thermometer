use crate::{model::*, ThermometerDriver};

pub fn characteristic(short: &str) -> Characteristic {
    let service = if short == "2a19" { "180f" } else { "fff0" };
    Characteristic {
        service_id: format!("0000{service}-0000-1000-8000-00805f9b34fb"),
        characteristic_id: format!("0000{short}-0000-1000-8000-00805f9b34fb"),
    }
}

pub fn decode_settings(data: &[u8]) -> Result<ThermometerSettings, String> {
    if data.len() != 2 {
        return Err("FFF4 settings must contain exactly two bytes".into());
    }
    let unit = match data[0] {
        0 => TemperatureUnit::Celsius,
        1 => TemperatureUnit::Fahrenheit,
        _ => return Err("Unknown temperature unit in FFF4".into()),
    };
    Ok(ThermometerSettings {
        unit,
        sound: data[1] & 2 != 0,
        vibration: data[1] & 1 != 0,
        raw_flags: data[1],
    })
}

fn encode_settings(settings: &DesiredSettings) -> Vec<u8> {
    vec![
        if settings.unit == TemperatureUnit::Celsius {
            0
        } else {
            1
        },
        u8::from(settings.vibration) | (u8::from(settings.sound) << 1),
    ]
}

pub fn decode_measurement(
    data: &[u8],
    settings: &ThermometerSettings,
) -> Result<Measurement, String> {
    if data.len() != 13 || !matches!(data[0], 0x06 | 0x07) {
        return Err("Unsupported FFF1 layout: expected 13 bytes and flags 06/07".into());
    }
    let raw_mantissa = u32::from(data[1]) | (u32::from(data[2]) << 8) | (u32::from(data[3]) << 16);
    if matches!(raw_mantissa, 0x7ffffe..=0x800002) {
        return Err("Invalid/special IEEE 11073 temperature value".into());
    }
    let mantissa = ((raw_mantissa << 8) as i32) >> 8;
    let exponent = data[4] as i8;
    let temperature = f64::from(mantissa) * 10_f64.powi(i32::from(exponent));
    if !temperature.is_finite() {
        return Err("Non-finite temperature".into());
    }
    let time = MeasurementTime {
        year: u16::from_le_bytes([data[5], data[6]]),
        month: data[7],
        day: data[8],
        hour: data[9],
        minute: data[10],
        second: data[11],
    };
    let leap = time.year.is_multiple_of(4)
        && (!time.year.is_multiple_of(100) || time.year.is_multiple_of(400));
    let days = match time.month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => 0,
    };
    if time.year == 0
        || time.year > 9999
        || time.day == 0
        || time.day > days
        || time.hour > 23
        || time.minute > 59
        || time.second > 59
    {
        return Err("Invalid measurement calendar timestamp".into());
    }
    let unit = if data[0] & 1 == 0 {
        TemperatureUnit::Celsius
    } else {
        TemperatureUnit::Fahrenheit
    };
    if unit != settings.unit {
        return Err("Measurement unit differs from transfer settings snapshot".into());
    }
    Ok(Measurement {
        temperature,
        mantissa,
        exponent,
        unit,
        time,
        temperature_type: data[12],
        raw: data.to_vec(),
        current_settings: settings.clone(),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    Connect,
    TransferSettings,
    Battery,
    SubscribeMeasurements,
    SubscribeCount,
    Refetch,
    BaselineSettings,
    WriteSettings,
    VerifySettings,
    Blink,
    Disconnect,
}

pub struct OvyOt35 {
    mode: SessionMode,
    state: SessionState,
    next_id: u32,
    pending: Option<(u32, Step)>,
    settings: Option<ThermometerSettings>,
    battery: Option<u8>,
    desired: Option<DesiredSettings>,
    measurements: Vec<Measurement>,
    count: Option<u8>,
    subscribed: bool,
    failure: bool,
}

impl OvyOt35 {
    pub fn new(mode: SessionMode) -> Self {
        Self {
            mode,
            state: SessionState::Disconnected,
            next_id: 1,
            pending: None,
            settings: None,
            battery: None,
            desired: None,
            measurements: vec![],
            count: None,
            subscribed: false,
            failure: false,
        }
    }

    fn emit(&mut self, step: Step, operation: BleOperation, out: &mut DriverOutput) {
        let id = self.next_id;
        self.next_id = self
            .next_id
            .checked_add(1)
            .expect("command identifier exhausted");
        self.pending = Some((id, step));
        out.commands.push(BleCommand { id, operation });
    }

    fn read(&mut self, step: Step, short: &str, out: &mut DriverOutput) {
        self.emit(
            step,
            BleOperation::Read {
                characteristic: characteristic(short),
            },
            out,
        );
    }

    fn write(&mut self, step: Step, short: &str, data: Vec<u8>, out: &mut DriverOutput) {
        self.emit(
            step,
            BleOperation::Write {
                characteristic: characteristic(short),
                data,
            },
            out,
        );
    }

    fn error(out: &mut DriverOutput, kind: DriverErrorKind, message: impl Into<String>) {
        out.events.push(DriverEvent::Error {
            kind,
            message: message.into(),
        });
    }

    fn fail(&mut self, kind: DriverErrorKind, message: impl Into<String>, out: &mut DriverOutput) {
        Self::error(out, kind, message);
        self.failure = true;
        self.measurements.clear();
        self.count = None;
        self.desired = None;
        if self.state == SessionState::Disconnected {
            self.state = SessionState::Failed;
            self.pending = None;
        } else {
            self.state = SessionState::Disconnecting;
            self.emit(Step::Disconnect, BleOperation::Disconnect, out);
        }
    }

    fn begin_transfer(&mut self, out: &mut DriverOutput) {
        self.measurements.clear();
        self.count = None;
        self.state = SessionState::Receiving;
        self.read(Step::TransferSettings, "fff4", out);
    }

    fn finish_transfer(&mut self, out: &mut DriverOutput) {
        if self.state != SessionState::Receiving || self.pending.is_some() {
            return;
        }
        let Some(count) = self.count else {
            return;
        };
        if self.measurements.len() < usize::from(count) {
            return;
        }
        if self.measurements.len() != usize::from(count) {
            self.fail(DriverErrorKind::Protocol, "Measurement count mismatch", out);
            return;
        }
        let Some(settings) = self.settings.clone() else {
            self.fail(DriverErrorKind::Protocol, "Missing transfer settings", out);
            return;
        };
        let Some(battery_percent) = self.battery else {
            self.fail(DriverErrorKind::Protocol, "Missing battery value", out);
            return;
        };
        out.events.push(DriverEvent::TransferCompleted {
            transfer: MeasurementTransfer {
                measurements: std::mem::take(&mut self.measurements),
                current_settings: settings,
                battery_percent,
                reported_count: count,
            },
        });
        self.count = None;
        if self.mode == SessionMode::TransferAndDisconnect {
            self.state = SessionState::Disconnecting;
            self.emit(Step::Disconnect, BleOperation::Disconnect, out);
        } else {
            self.state = SessionState::Ready;
        }
    }

    fn result(&mut self, id: u32, data: Vec<u8>, error: Option<String>, out: &mut DriverOutput) {
        let Some((pending_id, step)) = self.pending else {
            return;
        };
        if pending_id != id {
            return;
        } // timed-out/cancelled operation, never advance the FSM
        self.pending = None;
        if let Some(message) = error {
            if step == Step::Disconnect {
                Self::error(out, DriverErrorKind::Transport, message);
                self.state = SessionState::Failed;
                self.subscribed = false;
            } else {
                let message = if step == Step::Blink {
                    format!("Settings were applied and verified, but blink acknowledgement failed: {message}")
                } else {
                    message
                };
                self.fail(DriverErrorKind::Transport, message, out);
            }
            return;
        }
        match step {
            Step::Connect => self.begin_transfer(out),
            Step::TransferSettings => match decode_settings(&data) {
                Ok(settings) => {
                    self.settings = Some(settings);
                    self.read(Step::Battery, "2a19", out);
                }
                Err(e) => self.fail(DriverErrorKind::Protocol, e, out),
            },
            Step::Battery => {
                if data.len() != 1 || data[0] > 100 {
                    self.fail(DriverErrorKind::Protocol, "Invalid battery packet", out);
                    return;
                }
                self.battery = Some(data[0]);
                if self.subscribed {
                    self.write(Step::Refetch, "fff3", vec![0x02], out);
                } else {
                    self.emit(
                        Step::SubscribeMeasurements,
                        BleOperation::Subscribe {
                            characteristic: characteristic("fff1"),
                        },
                        out,
                    );
                }
            }
            Step::SubscribeMeasurements => self.emit(
                Step::SubscribeCount,
                BleOperation::Subscribe {
                    characteristic: characteristic("fff2"),
                },
                out,
            ),
            Step::SubscribeCount => {
                self.subscribed = true;
                self.finish_transfer(out);
            }
            Step::Refetch => self.finish_transfer(out),
            Step::BaselineSettings => {
                let current = match decode_settings(&data) {
                    Ok(s) => s,
                    Err(e) => {
                        self.fail(DriverErrorKind::Protocol, e, out);
                        return;
                    }
                };
                if current.raw_flags & !0x03 != 0 {
                    self.desired = None;
                    self.settings = Some(current);
                    self.state = SessionState::Ready;
                    Self::error(
                        out,
                        DriverErrorKind::Unsupported,
                        "Unknown settings bits are present; refusing to overwrite them",
                    );
                    return;
                }
                let desired = self.desired.as_ref().expect("settings change has a target");
                let encoded = encode_settings(desired);
                self.settings = Some(current);
                if data == encoded {
                    self.desired = None;
                    self.state = SessionState::Ready;
                    out.events.push(DriverEvent::SettingsChanged {
                        settings: self.settings.clone().unwrap(),
                        changed: false,
                        blink_confirmed: false,
                    });
                } else {
                    self.write(Step::WriteSettings, "fff4", encoded, out);
                }
            }
            Step::WriteSettings => self.read(Step::VerifySettings, "fff4", out),
            Step::VerifySettings => {
                let expected =
                    encode_settings(self.desired.as_ref().expect("settings change has a target"));
                if data != expected {
                    self.fail(
                        DriverErrorKind::SettingsMismatch,
                        "Settings readback differs from requested values; no blink sent",
                        out,
                    );
                    return;
                }
                self.settings = decode_settings(&data).ok();
                self.write(Step::Blink, "fff3", vec![0x01], out);
            }
            Step::Blink => {
                self.desired = None;
                self.state = SessionState::Ready;
                out.events.push(DriverEvent::SettingsChanged {
                    settings: self.settings.clone().unwrap(),
                    changed: true,
                    blink_confirmed: true,
                });
            }
            Step::Disconnect => {
                self.subscribed = false;
                self.state = if self.failure {
                    SessionState::Failed
                } else {
                    SessionState::Disconnected
                };
            }
        }
    }
}

impl ThermometerDriver for OvyOt35 {
    fn model(&self) -> &'static str {
        "ovy_ot35"
    }

    fn handle(&mut self, input: DriverInput) -> DriverOutput {
        let mut out = DriverOutput {
            state: self.state,
            commands: vec![],
            events: vec![],
            waiting_for_transfer: false,
        };
        match input {
            DriverInput::Start => {
                if !matches!(
                    self.state,
                    SessionState::Disconnected | SessionState::Failed
                ) {
                    Self::error(&mut out, DriverErrorKind::Busy, "Session is already active");
                } else {
                    self.failure = false;
                    self.subscribed = false;
                    self.settings = None;
                    self.battery = None;
                    self.measurements.clear();
                    self.count = None;
                    self.desired = None;
                    self.state = SessionState::Connecting;
                    self.emit(
                        Step::Connect,
                        BleOperation::Connect {
                            characteristics: vec![
                                characteristic("fff1"),
                                characteristic("fff2"),
                                characteristic("fff3"),
                                characteristic("fff4"),
                                characteristic("2a19"),
                            ],
                        },
                        &mut out,
                    );
                }
            }
            DriverInput::CommandResult {
                command_id,
                data,
                error,
            } => self.result(command_id, data, error, &mut out),
            DriverInput::Notification {
                characteristic: c,
                data,
            } => {
                if self.state == SessionState::Receiving
                    && self.settings.is_some()
                    && self.battery.is_some()
                {
                    if c == characteristic("fff1") {
                        match decode_measurement(&data, self.settings.as_ref().unwrap()) {
                            Ok(m) => {
                                self.measurements.push(m);
                                if self.measurements.len() > 255 {
                                    self.fail(
                                        DriverErrorKind::Protocol,
                                        "Transfer exceeds observed one-byte count capacity",
                                        &mut out,
                                    );
                                }
                            }
                            Err(e) => self.fail(DriverErrorKind::Protocol, e, &mut out),
                        }
                    } else if c == characteristic("fff2") {
                        if data.len() == 1 {
                            self.count = Some(data[0]);
                        } else {
                            self.fail(
                                DriverErrorKind::Protocol,
                                "FFF2 count must contain one byte",
                                &mut out,
                            );
                        }
                    }
                    self.finish_transfer(&mut out);
                }
            }
            DriverInput::Fetch => {
                if self.state == SessionState::Ready && self.mode == SessionMode::StayConnected {
                    self.begin_transfer(&mut out);
                } else {
                    Self::error(
                        &mut out,
                        DriverErrorKind::Busy,
                        "Fetch requires an idle stay-connected session",
                    );
                }
            }
            DriverInput::SetSettings { settings } => {
                if self.state == SessionState::Ready && self.mode == SessionMode::StayConnected {
                    self.desired = Some(settings);
                    self.state = SessionState::ChangingSettings;
                    self.read(Step::BaselineSettings, "fff4", &mut out);
                } else {
                    Self::error(
                        &mut out,
                        DriverErrorKind::Busy,
                        "Settings changes require an idle stay-connected session",
                    );
                }
            }
            DriverInput::CommandTimeout { command_id } => {
                if self.pending.map(|p| p.0) == Some(command_id) {
                    if self.pending.map(|p| p.1) == Some(Step::Disconnect) {
                        self.pending = None;
                        self.subscribed = false;
                        self.state = SessionState::Failed;
                        Self::error(&mut out, DriverErrorKind::Timeout, "Disconnect timed out");
                    } else {
                        self.fail(DriverErrorKind::Timeout, "BLE command timed out", &mut out);
                    }
                }
            }
            DriverInput::TransferTimeout => {
                if self.state == SessionState::Receiving {
                    self.fail(
                        DriverErrorKind::Timeout,
                        "Incomplete measurement transfer",
                        &mut out,
                    );
                }
            }
            DriverInput::Disconnected { reason } => {
                let expected = self.state == SessionState::Disconnecting;
                let active = !matches!(
                    self.state,
                    SessionState::Disconnected | SessionState::Failed
                );
                if !expected
                    && self.state != SessionState::Disconnected
                    && self.state != SessionState::Failed
                {
                    Self::error(&mut out, DriverErrorKind::Disconnected, reason);
                    self.failure = true;
                }
                self.pending = None;
                self.subscribed = false;
                self.measurements.clear();
                self.count = None;
                self.desired = None;
                self.state = if self.failure {
                    SessionState::Failed
                } else {
                    SessionState::Disconnected
                };
                if active && !expected {
                    // Release the OS connection stream and subscriptions before reuse.
                    self.state = SessionState::Disconnecting;
                    self.emit(Step::Disconnect, BleOperation::Disconnect, &mut out);
                }
            }
            DriverInput::Close => {
                self.measurements.clear();
                self.count = None;
                self.desired = None;
                if !matches!(
                    self.state,
                    SessionState::Disconnected | SessionState::Failed | SessionState::Disconnecting
                ) {
                    self.state = SessionState::Disconnecting;
                    self.emit(Step::Disconnect, BleOperation::Disconnect, &mut out);
                }
            }
            DriverInput::StartMeasurement | DriverInput::FetchMeasurementByIndex { .. } => {
                Self::error(
                    &mut out,
                    DriverErrorKind::Unsupported,
                    "No verified OT35 command exists for this operation",
                );
            }
        }
        out.state = self.state;
        out.waiting_for_transfer = self.state == SessionState::Receiving;
        out
    }
}
