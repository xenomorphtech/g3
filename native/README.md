# Rust Stack

This directory contains an all-Rust version of Goal Studio:

- `g3_backend`: a local HTTP backend that now uses SpaceTimeDB on `192.168.2.1:3000` by default.
- `g3_gui`: a native desktop client built with `eframe`/`egui`.
- `g3_core`: shared tracker models, persistence, assistant logic, and session behavior.
- `g3_spacetimedb`: the Rust SpaceTimeDB module that owns the remote schema and reducers.

## Run it

From the repository root:

```bash
cargo run --manifest-path native/Cargo.toml -p g3_backend
```

In a second terminal:

```bash
cargo run --manifest-path native/Cargo.toml -p g3_gui
```

The backend listens on `http://127.0.0.1:8787` by default.

## Files

- SpaceTimeDB module project: `g3_spacetimedb/`
- Optional Gemini config: `.local/gemini.json`

## Storage

The Rust backend defaults to:

- SpaceTimeDB host: `http://192.168.2.1:3000`
- SpaceTimeDB database: `g3-native-stdb3`

If you want the old local JSON mode instead:

```bash
cargo run --manifest-path native/Cargo.toml -p g3_backend -- --storage file
```

If `.local/gemini.json` is present, the backend will try Gemini first and fall back to the built-in rule-based assistant when Gemini is unavailable.
