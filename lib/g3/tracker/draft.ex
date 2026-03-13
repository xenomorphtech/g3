defmodule G3.Tracker.Draft do
  @moduledoc false

  @shared_fields ~w(title summary details status)
  @goal_fields ~w(success_criteria target_date)
  @task_fields ~w(due_date priority parent_goal_title)
  @allowed_fields @shared_fields ++ @goal_fields ++ @task_fields
  @blank_draft_fields Enum.map(@allowed_fields, &{&1, nil}) |> Map.new()

  def empty(kind) when kind in ["goal", "task"] do
    Map.merge(@blank_draft_fields, %{
      "id" => "draft-current",
      "kind" => kind,
      "status" => default_status(kind),
      "updated_at" => timestamp()
    })
  end

  def merge(nil, kind, fields) when kind in ["goal", "task"] do
    empty(kind)
    |> merge_fields(fields)
    |> touch()
  end

  def merge(%{"kind" => kind} = draft, kind, fields) do
    draft
    |> merge_fields(fields)
    |> touch()
  end

  def merge(%{} = _draft, kind, fields) when kind in ["goal", "task"] do
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

  def persisted_item(%{"kind" => "goal"} = draft, id) do
    draft
    |> Map.take(["title", "summary", "details", "success_criteria", "target_date", "status"])
    |> Map.merge(%{
      "id" => id,
      "kind" => "goal",
      "inserted_at" => timestamp(),
      "updated_at" => timestamp()
    })
  end

  def persisted_item(%{"kind" => "task"} = draft, id) do
    draft
    |> Map.take([
      "title",
      "summary",
      "details",
      "due_date",
      "priority",
      "parent_goal_title",
      "status"
    ])
    |> Map.merge(%{
      "id" => id,
      "kind" => "task",
      "inserted_at" => timestamp(),
      "updated_at" => timestamp()
    })
  end

  def default_state do
    %{
      "goals" => [],
      "tasks" => [],
      "active_draft" => nil,
      "updated_at" => timestamp()
    }
  end

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

  defp default_status("goal"), do: "draft"
  defp default_status("task"), do: "planned"

  defp touch(draft), do: Map.put(draft, "updated_at", timestamp())
end
