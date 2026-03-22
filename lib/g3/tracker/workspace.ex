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

  def start_draft(kind, fields, server \\ __MODULE__) do
    GenServer.call(server, {:start_draft, kind, fields})
  end

  def clear_draft(server \\ __MODULE__) do
    GenServer.call(server, :clear_draft)
  end

  def activate_draft(kind, id, server \\ __MODULE__) do
    GenServer.call(server, {:activate_draft, kind, id})
  end

  def set_object_status(kind, id, status, server \\ __MODULE__) do
    GenServer.call(server, {:set_object_status, kind, id, status})
  end

  def reorder_goals(ids, server \\ __MODULE__) when is_list(ids) do
    GenServer.call(server, {:reorder_goals, ids})
  end

  def save_draft(server \\ __MODULE__) do
    GenServer.call(server, :save_draft)
  end

  def save_draft_as(status, server \\ __MODULE__) do
    GenServer.call(server, {:save_draft_as, status})
  end

  def put_object_conversation(kind, id, conversation, server \\ __MODULE__) do
    GenServer.call(server, {:put_object_conversation, kind, id, conversation})
  end

  def put_object_summary(kind, id, summary, server \\ __MODULE__) do
    GenServer.call(server, {:put_object_summary, kind, id, summary})
  end

  def clear_object_conversation(kind, id, server \\ __MODULE__) do
    GenServer.call(server, {:clear_object_conversation, kind, id})
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, config_path())

    snapshot =
      path
      |> load_snapshot()
      |> private_snapshot()

    state = %{path: path, snapshot: snapshot}
    persist!(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, public_snapshot(state.snapshot), state}
  end

  def handle_call(:reset, _from, state) do
    next_state = %{state | snapshot: private_snapshot(Draft.default_state())}
    persist!(next_state)
    {:reply, public_snapshot(next_state.snapshot), next_state}
  end

  def handle_call({:upsert_draft, kind, fields}, _from, state) do
    next_snapshot =
      state.snapshot
      |> Draft.upsert_snapshot(kind, fields)
      |> private_snapshot()
      |> touch_snapshot()

    next_state = %{state | snapshot: next_snapshot}
    persist!(next_state)
    {:reply, public_snapshot(next_state.snapshot), next_state}
  end

  def handle_call({:start_draft, kind, fields}, _from, state) do
    next_snapshot =
      state.snapshot
      |> Draft.start_new_snapshot(kind, fields)
      |> private_snapshot()
      |> touch_snapshot()

    next_state = %{state | snapshot: next_snapshot}
    persist!(next_state)
    {:reply, public_snapshot(next_state.snapshot), next_state}
  end

  def handle_call(:clear_draft, _from, state) do
    next_snapshot =
      state.snapshot
      |> Draft.clear_snapshot()
      |> private_snapshot()
      |> touch_snapshot()

    next_state = %{state | snapshot: next_snapshot}
    persist!(next_state)
    {:reply, public_snapshot(next_state.snapshot), next_state}
  end

  def handle_call({:activate_draft, kind, id}, _from, state) do
    next_snapshot =
      state.snapshot
      |> Draft.activate_snapshot(kind, id)
      |> private_snapshot()
      |> touch_snapshot()

    next_state = %{state | snapshot: next_snapshot}
    persist!(next_state)
    {:reply, public_snapshot(next_state.snapshot), next_state}
  end

  def handle_call({:set_object_status, kind, id, status}, _from, state) do
    next_snapshot =
      state.snapshot
      |> Draft.update_item_status(kind, id, status)
      |> private_snapshot()
      |> touch_snapshot()

    next_state = %{state | snapshot: next_snapshot}
    persist!(next_state)
    {:reply, public_snapshot(next_state.snapshot), next_state}
  end

  def handle_call({:reorder_goals, ids}, _from, state) do
    next_snapshot =
      state.snapshot
      |> Draft.reorder_snapshot("goal", Enum.filter(ids, &is_binary/1))
      |> private_snapshot()
      |> touch_snapshot()

    next_state = %{state | snapshot: next_snapshot}
    persist!(next_state)
    {:reply, public_snapshot(next_state.snapshot), next_state}
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

  def handle_call({:save_draft_as, status}, _from, state) do
    case save_current_draft(state.snapshot, status) do
      {:ok, snapshot} ->
        next_state = %{state | snapshot: snapshot}
        persist!(next_state)
        {:reply, {:ok, snapshot}, next_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:put_object_conversation, kind, id, conversation}, _from, state) do
    next_snapshot =
      state.snapshot
      |> Draft.update_item_metadata(kind, id, %{"origin_conversation" => conversation})
      |> touch_snapshot()

    next_state = %{state | snapshot: next_snapshot}
    persist!(next_state)
    {:reply, public_snapshot(next_state.snapshot), next_state}
  end

  def handle_call({:put_object_summary, kind, id, summary}, _from, state) do
    next_snapshot =
      state.snapshot
      |> Draft.update_item_metadata(kind, id, %{"origin_summary" => summary})
      |> touch_snapshot()

    next_state = %{state | snapshot: next_snapshot}
    persist!(next_state)
    {:reply, public_snapshot(next_state.snapshot), next_state}
  end

  def handle_call({:clear_object_conversation, kind, id}, _from, state) do
    next_snapshot =
      state.snapshot
      |> Draft.update_item_metadata(kind, id, %{
        "origin_conversation" => nil,
        "origin_summary" => nil
      })
      |> touch_snapshot()

    next_state = %{state | snapshot: next_snapshot}
    persist!(next_state)
    {:reply, public_snapshot(next_state.snapshot), next_state}
  end

  defp save_current_draft(snapshot) do
    case Draft.current_draft(snapshot) do
      nil ->
        {:error, :no_active_draft}

      draft ->
        save_current_draft(snapshot, draft, nil)
    end
  end

  defp save_current_draft(snapshot, status_override) when is_binary(status_override) do
    case Draft.current_draft(snapshot) do
      nil ->
        {:error, :no_active_draft}

      draft ->
        save_current_draft(snapshot, draft, status_override)
    end
  end

  defp save_current_draft(_snapshot, nil) do
    {:error, :no_active_draft}
  end

  defp save_current_draft(snapshot, draft, status_override) do
    completion = Draft.completion(draft)

    if completion.ready? do
      item = Draft.persisted_item(draft, item_id(draft["kind"]), status_override)

      next_snapshot =
        snapshot
        |> Draft.replace_current_draft(item)
        |> private_snapshot()
        |> touch_snapshot()

      {:ok, next_snapshot}
    else
      {:error, {:draft_incomplete, completion.missing}}
    end
  end

  defp item_id(kind) do
    prefix =
      case kind do
        "goal" -> "goal"
        "task" -> "task"
        "fact" -> "fact"
      end

    unique = System.unique_integer([:positive, :monotonic])
    "#{prefix}-#{unique}"
  end

  defp load_snapshot(path) do
    with {:ok, encoded} <- File.read(path),
         {:ok, decoded} <- Jason.decode(encoded),
         true <- is_map(decoded) do
      Draft.normalize_snapshot(decoded)
    else
      _ -> Draft.normalize_snapshot(Draft.default_state())
    end
  end

  defp persist!(%{path: path, snapshot: snapshot}) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(private_snapshot(snapshot), pretty: true) <> "\n")
  end

  defp touch_snapshot(snapshot) do
    Map.put(snapshot, "updated_at", Draft.timestamp())
  end

  defp private_snapshot(snapshot) do
    Map.drop(snapshot, ["active_draft"])
  end

  defp public_snapshot(snapshot) do
    Draft.public_snapshot(snapshot)
  end

  defp config_path do
    Application.fetch_env!(:g3, __MODULE__)[:path]
  end
end
