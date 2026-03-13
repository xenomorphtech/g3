defmodule G3.Tracker.PromptRLTest do
  use ExUnit.Case, async: false

  alias G3.TestSupport.TrackerEvalCases
  alias G3.Tracker.Assistant
  alias G3.Tracker.Workspace

  @eval_cases TrackerEvalCases.prompt_rl_cases()

  for eval_case <- @eval_cases do
    test "#{eval_case.id} follows the expected planning flow" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})
      seed_workspace(workspace, eval_case.seed_items)

      {_history, final_result} =
        Enum.reduce(eval_case.turns, {[], nil}, fn turn, {history, _result} ->
          client = fn request ->
            assert length(request.contents) == turn.expected_contents_length

            assert List.last(request.contents) == %{
                     "role" => "user",
                     "parts" => [%{"text" => turn.user_message}]
                   }

            Enum.each(turn.prompt_must_include, fn expected_text ->
              assert request.system_instruction =~ expected_text
            end)

            {:ok, turn.scripted_response}
          end

          assert {:ok, result} =
                   Assistant.respond(turn.user_message,
                     workspace: workspace,
                     client: client,
                     history: history
                   )

          assert_turn_result(result, turn.expected)

          {append_history(history, turn.user_message, result.message), result}
        end)

      assert final_result != nil
    end
  end

  defp assert_turn_result(result, expected) do
    assert result.needs_follow_up == expected.needs_follow_up

    Enum.each(expected.message_must_include, fn expected_text ->
      assert result.message =~ expected_text
    end)

    action_tools = Enum.map(result.actions, & &1["tool"])
    assert action_tools == expected.action_tools
    refute Enum.any?(expected.forbidden_action_tools, &(&1 in action_tools))

    assert length(result.snapshot["goals"]) == expected.goals_count
    assert length(result.snapshot["tasks"]) == expected.tasks_count

    case expected.active_draft_kind do
      nil ->
        assert result.snapshot["active_draft"] == nil

      kind ->
        assert result.snapshot["active_draft"]["kind"] == kind
        assert_subset(result.snapshot["active_draft"], expected.active_draft_fields)
    end

    case Map.get(expected, :saved_goal_fields) do
      nil ->
        :ok

      goal_fields ->
        assert [%{} = saved_goal | _] = result.snapshot["goals"]
        assert_subset(saved_goal, goal_fields)
    end

    case Map.get(expected, :saved_task_fields) do
      nil ->
        :ok

      task_fields ->
        assert [%{} = saved_task | _] = result.snapshot["tasks"]
        assert_subset(saved_task, task_fields)
    end
  end

  defp assert_subset(actual, expected_subset) do
    Enum.each(expected_subset, fn {key, expected_value} ->
      assert actual[key] == expected_value
    end)
  end

  defp append_history(history, user_message, assistant_message) do
    history
    |> Kernel.++([
      %{"role" => "user", "content" => user_message},
      %{"role" => "assistant", "content" => assistant_message}
    ])
    |> Enum.take(-10)
  end

  defp seed_workspace(workspace, seed_items) do
    Enum.each(seed_items, fn seed_item ->
      Workspace.upsert_draft(seed_item.kind, seed_item.fields, workspace)
      assert {:ok, _snapshot} = Workspace.save_draft(workspace)
    end)
  end

  defp temp_path(id) do
    path =
      Path.join(
        System.tmp_dir!(),
        "g3-prompt-rl-#{id}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.json"
      )

    File.rm(path)
    path
  end
end
