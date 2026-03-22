defmodule G3.Tracker.Draft do
  @moduledoc false

  @kinds ~w(goal task fact)
  @shared_fields ~w(title summary details status)
  @goal_fields ~w(success_criteria target_date parent_goal_title)
  @task_fields ~w(due_date priority parent_goal_title)
  @fact_fields ~w(project_title)
  @metadata_fields ~w(origin_conversation origin_summary)
  @allowed_fields @shared_fields ++ @goal_fields ++ @task_fields ++ @fact_fields
  @blank_draft_fields Enum.map(@allowed_fields ++ @metadata_fields, &{&1, nil}) |> Map.new()
  @drafting_status "being_drafted"

  def empty(kind) when kind in @kinds do
    Map.merge(@blank_draft_fields, %{
      "id" => "draft-current",
      "kind" => kind,
      "status" => @drafting_status,
      "updated_at" => timestamp()
    })
  end

  def merge(nil, kind, fields) when kind in @kinds do
    empty(kind)
    |> merge_fields(fields)
    |> touch()
  end

  def merge(%{"kind" => kind} = draft, kind, fields) do
    draft
    |> merge_fields(fields)
    |> touch()
  end

  def merge(%{} = _draft, kind, fields) when kind in @kinds do
    empty(kind)
    |> merge_fields(fields)
    |> touch()
  end

  def merge(%{} = draft, nil, fields) do
    draft
    |> merge_fields(fields)
    |> touch()
  end

  def merge(nil, _kind, _fields), do: nil

  def completion(nil) do
    %{ready?: false, missing: ["Start by telling me whether this is a task or a goal."]}
  end

  def completion(%{"kind" => "task"} = draft) do
    missing =
      []
      |> maybe_missing(draft["title"], "A task needs a clear action title.")

    %{ready?: missing == [], missing: missing}
  end

  def completion(%{"kind" => "goal"} = draft) do
    missing =
      []
      |> maybe_missing(draft["title"], "A goal needs a clear title.")
      |> maybe_missing(draft["success_criteria"], "A goal needs a measurable success criteria.")

    %{ready?: missing == [], missing: missing}
  end

  def completion(%{"kind" => "fact"} = draft) do
    missing =
      []
      |> maybe_missing(draft["title"], "A fact needs a clear title.")
      |> maybe_missing(draft["project_title"], "A fact should be linked to a project.")

    %{ready?: missing == [], missing: missing}
  end

  def completion(_draft), do: %{ready?: false, missing: ["This draft is missing its item type."]}

  def normalize_fields(fields) when is_map(fields) do
    fields
    |> Enum.reduce(%{}, fn
      {key, value}, acc when key in @allowed_fields ->
        case normalize_value(value) do
          nil -> acc
          normalized -> Map.put(acc, key, normalized)
        end

      _entry, acc ->
        acc
    end)
  end

  def normalize_fields(_fields), do: %{}

  def persisted_item(draft, id, status_override \\ nil)

  def persisted_item(%{"kind" => "goal"} = draft, id, status_override) do
    draft
    |> Map.take([
      "title",
      "summary",
      "details",
      "success_criteria",
      "target_date",
      "parent_goal_title",
      "status",
      "origin_conversation",
      "origin_summary"
    ])
    |> Map.merge(%{
      "id" => id,
      "kind" => "goal",
      "status" => persisted_status("goal", status_override || draft["status"]),
      "inserted_at" => timestamp(),
      "updated_at" => timestamp()
    })
  end

  def persisted_item(%{"kind" => "task"} = draft, id, status_override) do
    draft
    |> Map.take([
      "title",
      "summary",
      "details",
      "due_date",
      "priority",
      "parent_goal_title",
      "status",
      "origin_conversation",
      "origin_summary"
    ])
    |> Map.merge(%{
      "id" => id,
      "kind" => "task",
      "status" => persisted_status("task", status_override || draft["status"]),
      "inserted_at" => timestamp(),
      "updated_at" => timestamp()
    })
  end

  def persisted_item(%{"kind" => "fact"} = draft, id, status_override) do
    draft
    |> Map.take([
      "title",
      "summary",
      "details",
      "project_title",
      "status",
      "origin_conversation",
      "origin_summary"
    ])
    |> Map.merge(%{
      "id" => id,
      "kind" => "fact",
      "status" => persisted_status("fact", status_override || draft["status"]),
      "inserted_at" => timestamp(),
      "updated_at" => timestamp()
    })
  end

  def default_state do
    %{
      "goals" => [],
      "tasks" => [],
      "facts" => [],
      "updated_at" => timestamp()
    }
  end

  def normalize_snapshot(snapshot) when is_map(snapshot) do
    base =
      default_state()
      |> Map.merge(Map.take(snapshot, ["goals", "tasks", "facts", "updated_at"]))
      |> normalize_buckets()
      |> ensure_unique_ids()

    base =
      case {current_draft(base), Map.get(snapshot, "active_draft")} do
        {nil, %{} = legacy_draft} ->
          insert_drafting_item(base, legacy_draft)

        _ ->
          base
      end

    public_snapshot(base)
  end

  def current_draft(snapshot) when is_map(snapshot) do
    ((snapshot["goals"] || []) ++ (snapshot["tasks"] || []) ++ (snapshot["facts"] || []))
    |> Enum.find(fn item -> drafting_item?(item) and item["id"] == "draft-current" end)
  end

  def public_snapshot(snapshot) when is_map(snapshot) do
    Map.put(snapshot, "active_draft", current_draft(snapshot))
  end

  def upsert_snapshot(snapshot, kind, fields) when kind in @kinds do
    current = current_draft(snapshot)

    cond do
      is_nil(current) ->
        snapshot
        |> insert_drafting_item(merge(nil, kind, fields))

      current["kind"] != kind ->
        snapshot
        |> archive_current_draft()
        |> insert_drafting_item(merge(nil, kind, fields))

      true ->
        update_item(snapshot, current["kind"], current["id"], fn _item ->
          merge(current, kind, fields)
        end)
    end
  end

  def upsert_snapshot(snapshot, _kind, _fields), do: snapshot

  def start_new_snapshot(snapshot, kind, fields) when kind in @kinds do
    snapshot
    |> archive_current_draft()
    |> insert_drafting_item(merge(nil, kind, fields))
  end

  def start_new_snapshot(snapshot, _kind, _fields), do: snapshot

  def clear_snapshot(snapshot) when is_map(snapshot) do
    remove_current_draft(snapshot)
  end

  def replace_current_draft(snapshot, draft) when is_map(snapshot) and is_map(draft) do
    snapshot
    |> remove_current_draft()
    |> insert_item(draft)
  end

  def update_item_status(snapshot, kind, id, status)
      when is_map(snapshot) and kind in @kinds and is_binary(id) and is_binary(status) do
    if valid_status?(kind, status) do
      update_item(snapshot, kind, id, fn item ->
        item
        |> Map.put("status", status)
        |> Map.put("updated_at", timestamp())
      end)
    else
      snapshot
    end
  end

  def update_item_status(snapshot, _kind, _id, _status), do: snapshot

  def reorder_snapshot(snapshot, kind, ids)
      when is_map(snapshot) and kind in ["goal", "task"] and is_list(ids) do
    bucket = bucket_key(kind)
    Map.update!(snapshot, bucket, &reorder_bucket(&1, ids))
  end

  def reorder_snapshot(snapshot, _kind, _ids), do: snapshot

  def activate_snapshot(snapshot, kind, id)
      when is_map(snapshot) and kind in @kinds and is_binary(id) do
    case find_item(snapshot, kind, id) do
      %{"id" => "draft-current"} = current ->
        update_item(snapshot, current["kind"], current["id"], &touch/1)

      %{} = item ->
        if item["status"] == @drafting_status do
          snapshot
          |> archive_current_draft()
          |> update_item(kind, id, fn target ->
            target
            |> Map.put("id", "draft-current")
            |> touch()
          end)
        else
          snapshot
        end

      _ ->
        snapshot
    end
  end

  def activate_snapshot(snapshot, _kind, _id), do: snapshot

  def update_item_metadata(snapshot, kind, id, attrs)
      when is_map(snapshot) and kind in @kinds and is_binary(id) and is_map(attrs) do
    update_item(snapshot, kind, id, fn item ->
      item
      |> Map.merge(Map.take(attrs, @metadata_fields))
      |> Map.put("updated_at", timestamp())
    end)
  end

  def update_item_metadata(snapshot, _kind, _id, _attrs), do: snapshot

  def drafting_item?(%{"status" => @drafting_status}), do: true
  def drafting_item?(_item), do: false

  def timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp merge_fields(draft, fields) do
    normalized_fields =
      fields
      |> normalize_string_keys()
      |> normalize_fields()

    Map.merge(draft, normalized_fields)
  end

  defp maybe_missing(list, value, message) do
    if blank?(value), do: list ++ [message], else: list
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp normalize_string_keys(fields) do
    Enum.reduce(fields, %{}, fn
      {key, value}, acc when is_binary(key) -> Map.put(acc, key, value)
      _entry, acc -> acc
    end)
  end

  defp normalize_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_value(value) when is_boolean(value) or is_number(value), do: value
  defp normalize_value(nil), do: nil
  defp normalize_value(_value), do: nil

  defp normalize_buckets(snapshot) do
    snapshot
    |> Map.update("goals", [], &normalize_bucket(&1, "goal"))
    |> Map.update("tasks", [], &normalize_bucket(&1, "task"))
    |> Map.update("facts", [], &normalize_bucket(&1, "fact"))
  end

  defp ensure_unique_ids(snapshot) do
    {goals, {seen_ids, current_draft_seen?}} =
      uniquify_bucket(snapshot["goals"] || [], MapSet.new(), false)

    {tasks, {seen_ids, current_draft_seen?}} =
      uniquify_bucket(snapshot["tasks"] || [], seen_ids, current_draft_seen?)

    {facts, {_seen_ids, _current_draft_seen?}} =
      uniquify_bucket(snapshot["facts"] || [], seen_ids, current_draft_seen?)

    snapshot
    |> Map.put("goals", goals)
    |> Map.put("tasks", tasks)
    |> Map.put("facts", facts)
  end

  defp uniquify_bucket(items, seen_ids, current_draft_seen?) do
    Enum.map_reduce(items, {seen_ids, current_draft_seen?}, fn item, {seen_ids, current_seen?} ->
      {item, seen_ids, current_seen?} = uniquify_item_id(item, seen_ids, current_seen?)
      {item, {seen_ids, current_seen?}}
    end)
  end

  defp uniquify_item_id(item, seen_ids, current_draft_seen?) do
    id = item["id"]

    cond do
      id == "draft-current" and not current_draft_seen? ->
        {item, MapSet.put(seen_ids, id), true}

      id == "draft-current" ->
        next_id = draft_item_id(item["kind"])
        {Map.put(item, "id", next_id), MapSet.put(seen_ids, next_id), current_draft_seen?}

      not is_binary(id) or MapSet.member?(seen_ids, id) ->
        next_id = unique_item_id(item["kind"], item["status"])
        {Map.put(item, "id", next_id), MapSet.put(seen_ids, next_id), current_draft_seen?}

      true ->
        {item, MapSet.put(seen_ids, id), current_draft_seen?}
    end
  end

  defp normalize_bucket(items, kind) when is_list(items) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item ->
      item
      |> Map.put("kind", kind)
      |> normalize_item_status(kind)
    end)
  end

  defp normalize_bucket(_items, _kind), do: []

  defp normalize_item_status(%{"status" => @drafting_status} = item, _kind) do
    item
    |> Map.put("id", Map.get(item, "id") || "draft-current")
    |> Map.put("updated_at", Map.get(item, "updated_at", timestamp()))
    |> Map.put_new("origin_conversation", nil)
    |> Map.put_new("origin_summary", nil)
  end

  defp normalize_item_status(item, kind) do
    item
    |> Map.put("status", Map.get(item, "status") || persisted_status(kind))
    |> Map.put("updated_at", Map.get(item, "updated_at", timestamp()))
    |> Map.put_new("origin_conversation", nil)
    |> Map.put_new("origin_summary", nil)
  end

  defp persisted_status(kind), do: persisted_status(kind, nil)

  defp persisted_status(kind, status) do
    if valid_status?(kind, status) and status != @drafting_status do
      status
    else
      default_persisted_status(kind)
    end
  end

  defp default_persisted_status("goal"), do: "draft"
  defp default_persisted_status("task"), do: "planned"
  defp default_persisted_status("fact"), do: "known"

  defp valid_status?("goal", status), do: status in ["being_drafted", "draft", "achieved"]
  defp valid_status?("task", status), do: status in ["being_drafted", "planned", "completed"]
  defp valid_status?("fact", status), do: status in ["known"]
  defp valid_status?(_kind, _status), do: false

  defp remove_current_draft(snapshot) do
    snapshot
    |> Map.update!("goals", &Enum.reject(&1, fn item -> item["id"] == "draft-current" end))
    |> Map.update!("tasks", &Enum.reject(&1, fn item -> item["id"] == "draft-current" end))
    |> Map.update!("facts", &Enum.reject(&1, fn item -> item["id"] == "draft-current" end))
  end

  defp archive_current_draft(snapshot) do
    case current_draft(snapshot) do
      nil ->
        snapshot

      current ->
        update_item(snapshot, current["kind"], current["id"], fn item ->
          Map.put(item, "id", draft_item_id(current["kind"]))
        end)
    end
  end

  defp insert_drafting_item(snapshot, draft) do
    draft =
      draft
      |> Map.put("status", @drafting_status)
      |> Map.put("id", "draft-current")
      |> Map.put("updated_at", timestamp())

    insert_item(snapshot, draft)
  end

  defp insert_item(snapshot, item) do
    bucket = bucket_key(item["kind"])
    Map.update!(snapshot, bucket, fn items -> [item | items] end)
  end

  defp draft_item_id(kind) do
    unique_item_id(kind, @drafting_status)
  end

  defp unique_item_id(kind, @drafting_status) do
    "draft-#{kind}-#{unique_suffix()}"
  end

  defp unique_item_id(kind, _status) do
    "#{kind}-#{unique_suffix()}"
  end

  defp unique_suffix do
    random =
      8
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 10)

    "#{System.system_time(:microsecond)}-#{random}"
  end

  defp find_item(snapshot, kind, id) do
    bucket = Map.get(snapshot, bucket_key(kind), [])
    Enum.find(bucket || [], &(&1["id"] == id))
  end

  defp reorder_bucket(items, ids) do
    positions =
      ids
      |> Enum.with_index()
      |> Map.new()

    {ordered, remaining} =
      Enum.split_with(items, &Map.has_key?(positions, &1["id"]))

    Enum.sort_by(ordered, &Map.fetch!(positions, &1["id"])) ++ remaining
  end

  defp update_item(snapshot, kind, id, updater) do
    bucket = bucket_key(kind)

    Map.update!(snapshot, bucket, fn items ->
      Enum.map(items, fn item ->
        if item["id"] == id do
          updater.(item)
        else
          item
        end
      end)
    end)
  end

  defp bucket_key("goal"), do: "goals"
  defp bucket_key("task"), do: "tasks"
  defp bucket_key("fact"), do: "facts"

  defp touch(draft), do: Map.put(draft, "updated_at", timestamp())
end
