//! Test adapter: obtain the real driver's startup clock commands without BLE.
use std::io::{self, Read};
use thermometer_protocol::{ClockTime, DriverInput, OvyOt35, SessionMode, ThermometerDriver};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;
    let clock: ClockTime = serde_json::from_str(&input)?;
    let mut driver = OvyOt35::new(SessionMode::StayConnected);
    let mut output = driver.handle(DriverInput::Start { clock: Some(clock) });
    // Connect, clock write and blink ACK: simulate successful results only to
    // extract commands. The Python tester checks each actual write separately.
    let mut commands = Vec::new();
    for _ in 0..3 {
        if !output.events.is_empty() || output.commands.len() != 1 {
            return Err(format!("Unexpected driver output: {output:?}").into());
        }
        let command = output.commands.remove(0);
        let id = command.id;
        commands.push(command);
        output = driver.handle(DriverInput::CommandResult {
            command_id: id,
            data: vec![],
            error: None,
        });
    }
    println!("{}", serde_json::to_string(&commands[1..])?);
    Ok(())
}
