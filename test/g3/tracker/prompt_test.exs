defmodule G3.Tracker.PromptTest do
  use ExUnit.Case, async: true

  alias G3.Tracker.Draft
  alias G3.Tracker.Prompt

  test "includes active draft and existing items in the system prompt" do
    snapshot = %{
      "active_draft" => Draft.empty("goal") |> Map.put("title", "Launch the portfolio"),
      "goals" => [
        %{
          "id" => "goal-1",
          "title" => "Launch the portfolio",
          "success_criteria" => "Site is live",
          "status" => "draft"
        }
      ],
      "tasks" => [
        %{
          "id" => "task-1",
          "title" => "Write the homepage copy",
          "status" => "planned"
        }
      ]
    }

    prompt = Prompt.system_instruction(snapshot)

    assert prompt =~ "Launch the portfolio"
    assert prompt =~ "task-1"
    assert prompt =~ "upsert_draft"
    assert prompt =~ "measurable success criteria"
    assert prompt =~ "Most tasks should be attached to a parent goal on the graph."
  end
end
