defmodule G3.Tracker.AssistantTest do
  use ExUnit.Case, async: false

  alias G3.Tracker.Assistant
  alias G3.Tracker.Workspace

  test "stores a partial goal draft and asks a follow-up question" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    client = fn request ->
      assert request.system_instruction =~ "Ask a concrete follow-up question"

      {:ok,
       %{
         "message" => "What would success look like for that goal?",
         "needs_follow_up" => true,
         "actions" => [
           %{
             "tool" => "upsert_draft",
             "kind" => "goal",
             "fields" => %{"title" => "Get in better shape"}
           }
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond("I want to get in better shape",
               workspace: workspace,
               client: client
             )

    assert result.needs_follow_up
    assert result.snapshot["goals"] == []
    assert result.snapshot["active_draft"]["kind"] == "goal"
    assert result.snapshot["active_draft"]["title"] == "Get in better shape"
  end

  test "saves a task when the model returns save actions" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    client = fn request ->
      assert request.system_instruction =~ "Tasks:"

      {:ok,
       %{
         "message" => "Saved that as a task.",
         "needs_follow_up" => false,
         "actions" => [
           %{
             "tool" => "upsert_draft",
             "kind" => "task",
             "fields" => %{
               "title" => "Send the Q2 planning deck",
               "due_date" => "2026-03-14",
               "priority" => "high"
             }
           },
           %{"tool" => "save_draft"}
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "Create a task to send the Q2 planning deck tomorrow",
               workspace: workspace,
               client: client
             )

    assert result.needs_follow_up == false
    assert result.snapshot["active_draft"] == nil

    assert [%{"title" => "Send the Q2 planning deck", "priority" => "high"}] =
             result.snapshot["tasks"]
  end

  defp temp_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "g3-assistant-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.json"
      )

    File.rm(path)
    path
  end
end
