use thermometer_protocol::{
    ovy::{characteristic, decode_measurement, decode_settings},
    *,
};

fn packet() -> Vec<u8> {
    vec![6, 0x74, 0x0e, 0, 0xfe, 0xe8, 7, 2, 29, 12, 34, 56, 6]
}
fn result(driver: &mut OvyOt35, command: &BleCommand, data: &[u8]) -> DriverOutput {
    driver.handle(DriverInput::CommandResult {
        command_id: command.id,
        data: data.to_vec(),
        error: None,
    })
}
fn value(driver: &mut OvyOt35, short: &str, data: &[u8]) -> DriverOutput {
    driver.handle(DriverInput::Notification {
        characteristic: characteristic(short),
        data: data.to_vec(),
    })
}
fn receiving(mode: SessionMode) -> (OvyOt35, BleCommand) {
    let mut d = OvyOt35::new(mode);
    let o = d.handle(DriverInput::Start);
    let o = result(&mut d, &o.commands[0], &[]);
    let o = result(&mut d, &o.commands[0], &[0, 3]);
    let o = result(&mut d, &o.commands[0], &[80]);
    let o = result(&mut d, &o.commands[0], &[]);
    (d, o.commands[0].clone())
}
fn ready() -> OvyOt35 {
    let (mut d, c) = receiving(SessionMode::StayConnected);
    result(&mut d, &c, &[]);
    value(&mut d, "fff1", &packet());
    let o = value(&mut d, "fff2", &[1]);
    assert_eq!(o.state, SessionState::Ready);
    d
}
fn desired() -> DesiredSettings {
    DesiredSettings {
        unit: TemperatureUnit::Fahrenheit,
        sound: false,
        vibration: true,
    }
}

#[test]
fn decode_calendar_decimal_and_unknown_settings_bits() {
    let settings = decode_settings(&[0, 7]).unwrap();
    assert_eq!(settings.raw_flags, 7);
    let m = decode_measurement(&packet(), &settings).unwrap();
    assert_eq!(m.temperature, 37.0);
    assert_eq!(m.time.day, 29);
    assert_eq!(m.exponent, -2);
    assert_eq!(m.current_settings, settings);
    let mut p = packet();
    p[1..4].copy_from_slice(&[0xff, 0xff, 0xff]);
    assert_eq!(
        decode_measurement(&p, &settings).unwrap().temperature,
        -0.01
    );
}
#[test]
fn reject_bad_layout_time_unit_and_special_float() {
    let settings = decode_settings(&[0, 3]).unwrap();
    assert!(decode_settings(&[2, 3]).is_err());
    assert!(decode_settings(&[0]).is_err());
    for raw in [0x7ffffe_u32, 0x7fffff, 0x800000, 0x800001, 0x800002] {
        let mut p = packet();
        p[1..4].copy_from_slice(&raw.to_le_bytes()[..3]);
        assert!(decode_measurement(&p, &settings).is_err());
    }
    for (offset, byte) in [(0, 8), (8, 30), (9, 24), (10, 60), (11, 60)] {
        let mut p = packet();
        p[offset] = byte;
        assert!(decode_measurement(&p, &settings).is_err());
    }
    let mut p = packet();
    p[0] = 7;
    assert!(decode_measurement(&p, &settings).is_err());
    assert!(decode_measurement(&p[..12], &settings).is_err());
}
#[test]
fn early_indications_are_buffered_until_subscription_result() {
    let (mut d, c) = receiving(SessionMode::StayConnected);
    value(&mut d, "fff1", &packet());
    let o = value(&mut d, "fff2", &[1]);
    assert!(o.events.is_empty());
    let o = result(&mut d, &c, &[]);
    assert_eq!(o.state, SessionState::Ready);
    match &o.events[0] {
        DriverEvent::TransferCompleted { transfer } => {
            assert_eq!(transfer.measurements.len(), 1);
            assert_eq!(transfer.battery_percent, 80);
            assert_eq!(transfer.current_settings.raw_flags, 3);
        }
        _ => panic!(),
    }
}
#[test]
fn transfer_mode_disconnects_after_complete_batch() {
    let (mut d, c) = receiving(SessionMode::TransferAndDisconnect);
    result(&mut d, &c, &[]);
    value(&mut d, "fff1", &packet());
    let o = value(&mut d, "fff2", &[1]);
    assert_eq!(o.state, SessionState::Disconnecting);
    assert_eq!(o.commands[0].operation, BleOperation::Disconnect);
    let o = result(&mut d, &o.commands[0], &[]);
    assert_eq!(o.state, SessionState::Disconnected);
}
#[test]
fn refetch_refreshes_metadata_and_uses_proven_control_02() {
    let mut d = ready();
    let o = d.handle(DriverInput::Fetch);
    let o = result(&mut d, &o.commands[0], &[1, 3]);
    let o = result(&mut d, &o.commands[0], &[30]);
    assert_eq!(
        o.commands[0].operation,
        BleOperation::Write {
            characteristic: characteristic("fff3"),
            data: vec![2]
        }
    );
    let mut p = packet();
    p[0] = 7;
    p[1..4].copy_from_slice(&[0x28, 0x26, 0]); // 97.68 F, synthetic
    value(&mut d, "fff1", &p);
    value(&mut d, "fff2", &[1]);
    let o = result(&mut d, &o.commands[0], &[]);
    assert_eq!(o.state, SessionState::Ready);
    match &o.events[0] {
        DriverEvent::TransferCompleted { transfer } => {
            assert_eq!(transfer.current_settings.unit, TemperatureUnit::Fahrenheit);
            assert_eq!(transfer.battery_percent, 30);
        }
        _ => panic!(),
    }
}
#[test]
fn changed_settings_read_back_before_blink_ack() {
    let mut d = ready();
    let o = d.handle(DriverInput::SetSettings {
        settings: desired(),
    });
    let o = result(&mut d, &o.commands[0], &[0, 3]);
    assert_eq!(
        o.commands[0].operation,
        BleOperation::Write {
            characteristic: characteristic("fff4"),
            data: vec![1, 1]
        }
    );
    let o = result(&mut d, &o.commands[0], &[]);
    assert_eq!(
        o.commands[0].operation,
        BleOperation::Read {
            characteristic: characteristic("fff4")
        }
    );
    let o = result(&mut d, &o.commands[0], &[1, 1]);
    assert_eq!(
        o.commands[0].operation,
        BleOperation::Write {
            characteristic: characteristic("fff3"),
            data: vec![1]
        }
    );
    let o = result(&mut d, &o.commands[0], &[]);
    assert!(matches!(
        o.events[0],
        DriverEvent::SettingsChanged {
            changed: true,
            blink_confirmed: true,
            ..
        }
    ));
}
#[test]
fn unchanged_settings_do_not_write_or_blink() {
    let mut d = ready();
    let o = d.handle(DriverInput::SetSettings {
        settings: desired(),
    });
    let o = result(&mut d, &o.commands[0], &[1, 1]);
    assert!(o.commands.is_empty());
    assert!(matches!(
        o.events[0],
        DriverEvent::SettingsChanged {
            changed: false,
            blink_confirmed: false,
            ..
        }
    ));
}
#[test]
fn unknown_bits_are_not_overwritten() {
    let mut d = ready();
    let o = d.handle(DriverInput::SetSettings {
        settings: desired(),
    });
    let o = result(&mut d, &o.commands[0], &[0, 4]);
    assert!(o.commands.is_empty());
    assert_eq!(o.state, SessionState::Ready);
    assert!(matches!(
        o.events[0],
        DriverEvent::Error {
            kind: DriverErrorKind::Unsupported,
            ..
        }
    ));
}
#[test]
fn readback_mismatch_disconnects_without_ack() {
    let mut d = ready();
    let o = d.handle(DriverInput::SetSettings {
        settings: desired(),
    });
    let o = result(&mut d, &o.commands[0], &[0, 3]);
    let o = result(&mut d, &o.commands[0], &[]);
    let o = result(&mut d, &o.commands[0], &[0, 3]);
    assert_eq!(o.commands[0].operation, BleOperation::Disconnect);
    assert!(matches!(
        o.events[0],
        DriverEvent::Error {
            kind: DriverErrorKind::SettingsMismatch,
            ..
        }
    ));
}
#[test]
fn malformed_packet_and_incomplete_batch_fail() {
    let (mut d, c) = receiving(SessionMode::StayConnected);
    result(&mut d, &c, &[]);
    let o = value(&mut d, "fff1", &[6]);
    assert_eq!(o.commands[0].operation, BleOperation::Disconnect);
    let (mut d, c) = receiving(SessionMode::StayConnected);
    result(&mut d, &c, &[]);
    value(&mut d, "fff2", &[1]);
    let o = d.handle(DriverInput::TransferTimeout);
    assert!(matches!(
        o.events[0],
        DriverEvent::Error {
            kind: DriverErrorKind::Timeout,
            ..
        }
    ));
}
#[test]
fn empty_batch_and_overfull_batch() {
    let (mut d, c) = receiving(SessionMode::StayConnected);
    result(&mut d, &c, &[]);
    assert_eq!(value(&mut d, "fff2", &[0]).state, SessionState::Ready);
    let (mut d, c) = receiving(SessionMode::StayConnected);
    result(&mut d, &c, &[]);
    value(&mut d, "fff1", &packet());
    let o = value(&mut d, "fff2", &[0]);
    assert!(matches!(
        o.events[0],
        DriverEvent::Error {
            kind: DriverErrorKind::Protocol,
            ..
        }
    ));
}
#[test]
fn disconnected_and_stale_completion_never_advance() {
    let mut d = OvyOt35::new(SessionMode::StayConnected);
    let o = d.handle(DriverInput::Start);
    let c = o.commands[0].clone();
    let o = d.handle(DriverInput::Disconnected {
        reason: "link lost".into(),
    });
    assert_eq!(o.state, SessionState::Disconnecting);
    let cleanup = o.commands[0].clone();
    assert!(result(&mut d, &c, &[]).commands.is_empty());
    assert_eq!(result(&mut d, &cleanup, &[]).state, SessionState::Failed);
    let o = d.handle(DriverInput::Start);
    let id = o.commands[0].id;
    let o = d.handle(DriverInput::CommandTimeout { command_id: id });
    assert_eq!(o.commands[0].operation, BleOperation::Disconnect);
    assert!(result(&mut d, &c, &[]).commands.is_empty());
}
#[test]
fn unsupported_operations_do_not_guess_commands() {
    let mut d = ready();
    for input in [
        DriverInput::StartMeasurement,
        DriverInput::FetchMeasurementByIndex { index: 1 },
    ] {
        let o = d.handle(input);
        assert!(o.commands.is_empty());
        assert!(matches!(
            o.events[0],
            DriverEvent::Error {
                kind: DriverErrorKind::Unsupported,
                ..
            }
        ));
    }
    assert!(create_driver("unknown", SessionMode::StayConnected).is_err());
}
