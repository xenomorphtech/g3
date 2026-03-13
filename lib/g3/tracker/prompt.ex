defmodule G3.Tracker.Prompt do
  @moduledoc false

  def system_instruction(snapshot) do
    """
    You are Goal Studio, an LLM-assisted goals and task tracker.

    Today is #{Date.utc_today()}.

    Your job:
    - Read the user's latest message in the context of the existing tracker state.
    - Maintain a single active draft object across turns.
    - Ask a concrete follow-up question when the information is not complete enough to form a useful item.
    - Never invent dates, priorities, or success criteria.
    - Prefer concise responses.

    Completion rules:
    - A task is ready when it has a clear actionable title.
    - Most tasks should be attached to a parent goal on the graph.
    - If a task clearly supports the active goal or an existing goal, set `parent_goal_title`.
    - If a task seems to support a goal but the parent is unclear, ask which goal it belongs to instead of guessing.
    - Standalone chores are fine when no meaningful parent goal exists.
    - A goal is ready when it has a clear title and measurable success criteria.
    - If a goal is missing success criteria, ask for it instead of saving.
    - If the user is clearly refining the current draft, merge the new details into that draft.

    Available app-layer tools:
    - upsert_draft: create or merge fields into the active draft. Use this whenever you learn anything durable.
    - save_draft: save the current draft into the task or goal list if it is ready.
    - clear_draft: remove the active draft when the user abandons it.

    Existing tracker state:
    #{state_summary(snapshot)}

    Output rules:
    - Return valid JSON only.
    - Use `needs_follow_up: true` when you ask a question because the draft is still incomplete.
    - Include actions in the order they should be applied.
    - If the user references an already-existing task or goal, acknowledge it in the message and avoid creating a duplicate unless the user is clearly asking for a new item.
    """
  end

  def response_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["message", "needs_follow_up", "actions"],
      "properties" => %{
        "message" => %{
          "type" => "string",
          "description" => "The natural-language assistant reply to show the user."
        },
        "needs_follow_up" => %{
          "type" => "boolean",
          "description" => "True when the assistant is explicitly asking for missing information."
        },
        "actions" => %{
          "type" => "array",
          "description" => "App-layer tool calls to persist the structured draft state.",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["tool"],
            "properties" => %{
              "tool" => %{
                "type" => "string",
                "enum" => ["upsert_draft", "save_draft", "clear_draft"]
              },
              "kind" => %{
                "type" => ["string", "null"],
                "enum" => ["goal", "task", nil]
              },
              "fields" => %{
                "type" => ["object", "null"],
                "additionalProperties" => false,
                "properties" => %{
                  "title" => %{"type" => ["string", "null"]},
                  "summary" => %{"type" => ["string", "null"]},
                  "details" => %{"type" => ["string", "null"]},
                  "status" => %{"type" => ["string", "null"]},
                  "success_criteria" => %{"type" => ["string", "null"]},
                  "target_date" => %{"type" => ["string", "null"]},
                  "due_date" => %{"type" => ["string", "null"]},
                  "priority" => %{
                    "type" => ["string", "null"],
                    "enum" => ["low", "medium", "high", nil]
                  },
                  "parent_goal_title" => %{"type" => ["string", "null"]}
                }
              }
            }
          }
        }
      }
    }
  end

  def build_contents(history, latest_user_message) do
    history
    |> Enum.map(&content_part/1)
    |> Kernel.++([%{"role" => "user", "parts" => [%{"text" => latest_user_message}]}])
  end

  defp content_part(%{"role" => role, "content" => content}) do
    %{"role" => api_role(role), "parts" => [%{"text" => content}]}
  end

  defp content_part(%{role: role, content: content}) do
    %{"role" => api_role(role), "parts" => [%{"text" => content}]}
  end

  defp api_role("assistant"), do: "model"
  defp api_role(:assistant), do: "model"
  defp api_role(_role), do: "user"

  defp state_summary(snapshot) do
    active_draft = snapshot["active_draft"] || %{}

    """
    Active draft:
    #{Jason.encode!(active_draft, pretty: true)}

    Goals:
    #{summarize_items(snapshot["goals"], ["title", "success_criteria", "target_date", "status"])}

    Tasks:
    #{summarize_items(snapshot["tasks"], ["title", "due_date", "priority", "parent_goal_title", "status"])}
    """
  end

  defp summarize_items([], _fields), do: "- none"

  defp summarize_items(items, fields) do
    items
    |> Enum.take(8)
    |> Enum.map(fn item ->
      details =
        fields
        |> Enum.map(fn field ->
          case item[field] do
            nil -> nil
            value -> "#{field}=#{value}"
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join(", ")

      "- #{item["id"]}: #{details}"
    end)
    |> Enum.join("\n")
  end
end
