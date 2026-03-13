defmodule G3.Tracker.ExternalEvalTest do
  use ExUnit.Case, async: false

  @moduletag :external_ai

  alias G3.TestSupport.TrackerEvalCases
  alias G3.Tracker.Assistant
  alias G3.Tracker.Workspace

  @eval_cases TrackerEvalCases.external_goal_follow_up_cases()

  for eval_case <- @eval_cases do
    test "#{eval_case.id} asks for missing goal details instead of prematurely saving" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})

      assert {:ok, result} =
               Assistant.respond(
                 eval_case.user_message,
                 workspace: workspace,
                 client: G3.AI.GeminiClient
               )

      assert result.needs_follow_up == eval_case.expected_follow_up
      assert result.message =~ "?"
      assert result.snapshot["active_draft"]["kind"] == eval_case.expected_kind
      assert length(result.snapshot["goals"]) == eval_case.expected_saved_goals
      assert result.snapshot["tasks"] == []
    end
  end

  defp temp_path(id) do
    path =
      Path.join(
        System.tmp_dir!(),
        "g3-external-eval-#{id}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.json"
      )

    File.rm(path)
    path
  end
end
