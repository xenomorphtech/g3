defmodule G3.Tracker.Workspace do
  @moduledoc false

  use GenServer

  alias G3.Tracker.Draft

  def start_link(opts \\ []) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, opts)
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  def reset(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  def upsert_draft(kind, fields, server \\ __MODULE__) do
    GenServer.call(server, {:upsert_draft, kind, fields})
  end

  def clear_draft(server \\ __MODULE__) do
    GenServer.call(server, :clear_draft)
  end

  def save_draft(server \\ __MODULE__) do
    GenServer.call(server, :save_draft)
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, config_path())
    state = %{path: path, snapshot: load_snapshot(path)}
    persist!(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, state.snapshot, state}
  end

  def handle_call(:reset, _from, state) do
    next_state = %{state | snapshot: Draft.default_state()}
    persist!(next_state)
    {:reply, next_state.snapshot, next_state}
  end

  def handle_call({:upsert_draft, kind, fields}, _from, state) do
    next_snapshot =
      state.snapshot["active_draft"]
      |> Draft.merge(kind, fields)
      |> then(fn draft -> Map.put(state.snapshot, "active_draft", draft) end)
      |> touch_snapshot()

    next_state = %{state | snapshot: next_snapshot}
    persist!(next_state)
    {:reply, next_state.snapshot, next_state}
  end

  def handle_call(:clear_draft, _from, state) do
    next_snapshot =
      state.snapshot
      |> Map.put("active_draft", nil)
      |> touch_snapshot()

    next_state = %{state | snapshot: next_snapshot}
    persist!(next_state)
    {:reply, next_state.snapshot, next_state}
  end

  def handle_call(:save_draft, _from, state) do
    case save_current_draft(state.snapshot) do
      {:ok, snapshot} ->
        next_state = %{state | snapshot: snapshot}
        persist!(next_state)
        {:reply, {:ok, snapshot}, next_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp save_current_draft(%{"active_draft" => nil}) do
    {:error, :no_active_draft}
  end

  defp save_current_draft(%{"active_draft" => draft} = snapshot) do
    completion = Draft.completion(draft)

    if completion.ready? do
      bucket = if draft["kind"] == "goal", do: "goals", else: "tasks"
      item = Draft.persisted_item(draft, item_id(draft["kind"]))

      next_snapshot =
        snapshot
        |> Map.update!(bucket, fn items -> [item | items] end)
        |> Map.put("active_draft", nil)
        |> touch_snapshot()

      {:ok, next_snapshot}
    else
      {:error, {:draft_incomplete, completion.missing}}
    end
  end

  defp item_id(kind) do
    prefix = if kind == "goal", do: "goal", else: "task"
    unique = System.unique_integer([:positive, :monotonic])
    "#{prefix}-#{unique}"
  end

  defp load_snapshot(path) do
    with {:ok, encoded} <- File.read(path),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- is_map(decoded) do
      Map.merge(Draft.default_state(), decoded)
    else
      _ -> Draft.default_state()
    end
  end

  defp persist!(%{path: path, snapshot: snapshot}) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(snapshot, pretty: true) <> "\n")
  end

  defp touch_snapshot(snapshot) do
    Map.put(snapshot, "updated_at", Draft.timestamp())
  end

  defp config_path do
    Application.fetch_env!(:g3, __MODULE__)[:path]
  end
end
