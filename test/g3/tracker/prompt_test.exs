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
      ],
      "facts" => [
        %{
          "id" => "fact-1",
          "title" => "Launch copy needs legal approval",
          "project_title" => "Launch the portfolio",
          "status" => "known"
        }
      ]
    }

    prompt =
      Prompt.system_instruction(snapshot, %{
        "kind" => "goal",
        "title" => "Launch the portfolio",
        "status" => "draft"
      })

    assert prompt =~ "Launch the portfolio"
    assert prompt =~ "task-1"
    assert prompt =~ "fact-1"
    assert prompt =~ "Facts:"
    assert prompt =~ "Focused object:"
    assert prompt =~ "upsert_draft"
    assert prompt =~ "start_new_draft"
    assert prompt =~ "measurable success criteria"
    assert prompt =~ "Most tasks should be attached to a parent goal on the graph."
    assert prompt =~ "materialize it into the graph with `upsert_draft` or `start_new_draft`"
    assert prompt =~ "`status: \"being_drafted\"`"
    assert prompt =~ "split them into separate objects"
    assert prompt =~ "separate lines or bullets"
    assert prompt =~ "start a new object instead of mutating the previous one"
    assert prompt =~ "Goals may be nested"
    assert prompt =~ "A subgoal is still a regular `goal`"
    assert prompt =~ "Goal target dates are optional metadata"
    assert prompt =~ "Do not ask for a target date just because a goal is missing one."
    assert prompt =~ "ask the follow-up question for only the active draft"
    assert prompt =~ "do not use the phrases \"both goals\", \"for both\", or \"for each\""

    assert prompt =~
             "Avoid plural follow-up phrasing like \"both goals\", \"for each\", or \"for both\""

    assert prompt =~
             "Do not ask the user to answer for multiple incomplete goals in a single reply."

    assert prompt =~ "Do not say \"both goals\""

    assert prompt =~ "emit enough `upsert_draft` and `save_draft` actions"
    assert prompt =~ "Do not ask for both goals at once, and do not ask for target dates."
    assert prompt =~ "Never emit a bare"
    assert prompt =~ "do not emit `save_draft` before the concrete `upsert_draft`"
    assert prompt =~ "add task, use the native voices to be listened"
    assert prompt =~ "emit task actions, not goal actions"
    assert prompt =~ "The first action must be a concrete task `upsert_draft`"
    assert prompt =~ "Do not create a new goal"
    assert prompt =~ "The project will be called Flux."
    assert prompt =~ "Add a subgoal to publish three case studies before launch."
    assert prompt =~ "leave `parent_goal_title` unset"
    assert prompt =~ "Saved facts live in the facts store"
    assert prompt =~ "`project_title`"
    assert prompt =~ "If a project goal is currently focused in the UI and the user states a fact"
    assert prompt =~ "Do not say that you saved a fact unless"
    assert prompt =~ "search_facts_bm25"
    assert prompt =~ "search_facts_grep"
    assert prompt =~ "search saved facts by relevance using BM25"
    assert prompt =~ "ripgrep-like text or regex pattern"
    assert prompt =~ "always provide a short non-empty `query`"
    assert prompt =~ "always provide a non-empty `pattern`"
    assert prompt =~ "copy the inner pattern exactly"
    assert prompt =~ "What facts do we have about legal approval for launches?"
    assert prompt =~ "Search facts for /BEAM first/"
    assert prompt =~ "Fact: it must run entirely on the BEAM first."
    assert prompt =~ "Actually never mind"
    assert prompt =~ "save it in that same turn"
  end
end
