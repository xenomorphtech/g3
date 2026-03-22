# G3

Structured planning loop
Turn free-form chat into durable goals and tasks.
The assistant keeps a persistent draft object, sees your existing tracker state, and only saves when the information is concrete enough.

Local OpenRouter config can be added at `.local/openrouter.json` to trial `z-ai/glm-5` without committing credentials. Set `G3_MODEL_PROVIDER=openrouter` before starting Phoenix if you want the app to use it for a test run.

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Rust Desktop Stack

An all-Rust desktop stack now lives under [`native/`](native/README.md):

```bash
cargo run --manifest-path native/Cargo.toml -p g3_backend
cargo run --manifest-path native/Cargo.toml -p g3_gui
```

The Rust GUI talks to `http://127.0.0.1:8787`, and the Rust backend now defaults to SpaceTimeDB on `http://192.168.2.1:3000` using the `g3-native-stdb3` database. You can still force local JSON storage with `--storage file`.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
