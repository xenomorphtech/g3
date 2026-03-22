defmodule G3.Tracker.ExternalEvalTest do
  use ExUnit.Case, async: false

  @moduletag :external_ai

  alias G3.TestSupport.TrackerEvalCases
  alias G3.Tracker.Assistant
  alias G3.Tracker.Workspace

  @goal_eval_cases TrackerEvalCases.external_goal_follow_up_cases()
  @goal_save_cases TrackerEvalCases.external_goal_save_cases()
  @task_eval_cases TrackerEvalCases.external_task_linking_cases()
  @focused_multi_task_cases TrackerEvalCases.external_focused_multi_task_cases()
  @fact_save_cases TrackerEvalCases.external_fact_save_cases()
  @fact_search_cases TrackerEvalCases.external_fact_search_cases()
  @ambiguous_task_cases TrackerEvalCases.external_ambiguous_task_cases()
  @standalone_task_cases TrackerEvalCases.external_standalone_task_cases()
  @multiturn_goal_cases TrackerEvalCases.external_multiturn_goal_cases()
  @multiline_goal_cases TrackerEvalCases.external_multiline_goal_cases()

  for eval_case <- @goal_eval_cases do
    test "#{eval_case.id} asks for missing goal details instead of prematurely saving" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})

      assert {:ok, result} =
               Assistant.respond(
                 eval_case.user_message,
                 workspace: workspace,
                 client: external_client()
               )

      assert result.needs_follow_up == eval_case.expected_follow_up
      assert result.message =~ "?"
      assert_message_does_not_include(result.message, eval_case[:message_must_not_include] || [])
      assert result.snapshot["active_draft"]["kind"] == eval_case.expected_kind

      assert String.contains?(
               result.snapshot["active_draft"]["title"],
               eval_case.expected_title_contains
             )

      assert saved_items_count(result.snapshot["goals"]) == eval_case.expected_saved_goals
      assert graph_draft_count(result.snapshot["goals"]) == 1
      assert result.snapshot["tasks"] == []
    end
  end

  for eval_case <- @task_eval_cases do
    test "#{eval_case.id} links a task to the right parent goal when it is clear" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})
      seed_workspace(workspace, eval_case.seed_items)

      assert {:ok, result} =
               Assistant.respond(
                 eval_case.user_message,
                 workspace: workspace,
                 client: external_client()
               )

      assert result.needs_follow_up == false
      assert result.snapshot["active_draft"] == nil
      assert length(result.snapshot["goals"]) == eval_case.expected_goals_count
      assert [%{} = task | _] = result.snapshot["tasks"]
      assert task["kind"] == "task"
      assert task["parent_goal_title"] == eval_case.expected_parent_goal_title
    end
  end

  for eval_case <- @focused_multi_task_cases do
    test "#{eval_case.id} creates focused tasks without creating a new goal" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})
      seed_workspace(workspace, eval_case.seed_items)

      assert {:ok, result} =
               Assistant.respond(
                 eval_case.user_message,
                 workspace: workspace,
                 focus_object: eval_case.focus_object,
                 client: external_client()
               )

      titles =
        result.snapshot["tasks"]
        |> Enum.map(&String.downcase(&1["title"]))

      assert result.needs_follow_up == false
      assert result.snapshot["active_draft"] == nil
      assert length(result.snapshot["goals"]) == eval_case.expected_goals_count
      assert length(result.snapshot["tasks"]) == eval_case.expected_task_count

      Enum.each(result.snapshot["tasks"], fn task ->
        assert task["kind"] == "task"
        assert task["parent_goal_title"] == "Build a Thai language learning app"
      end)

      Enum.each(eval_case.expected_task_title_tokens, fn expected_tokens ->
        assert Enum.any?(titles, fn title ->
                 Enum.all?(expected_tokens, &String.contains?(title, &1))
               end)
      end)

      Enum.each(eval_case.forbidden_goal_titles, fn title ->
        refute Enum.any?(result.snapshot["goals"], &(&1["title"] == title))
      end)
    end
  end

  for eval_case <- @fact_save_cases do
    test "#{eval_case.id} saves a fact under the focused project when the project context is clear" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})
      seed_workspace(workspace, eval_case.seed_items)

      assert {:ok, result} =
               Assistant.respond(
                 eval_case.user_message,
                 workspace: workspace,
                 focus_object: eval_case.focus_object,
                 client: external_client()
               )

      assert result.needs_follow_up == false
      assert result.snapshot["active_draft"] == nil
      assert length(result.snapshot["goals"]) == eval_case.expected_goals_count
      assert [%{} = fact] = result.snapshot["facts"]
      assert fact["kind"] == "fact"
      assert fact["project_title"] == eval_case.expected_project_title
      assert String.contains?(String.downcase(fact["title"]), eval_case.expected_title_contains)
    end
  end

  for eval_case <- @fact_search_cases do
    test "#{eval_case.id} uses the fact search tool before answering" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})
      seed_workspace(workspace, eval_case.seed_items)

      assert {:ok, result} =
               Assistant.respond(
                 eval_case.user_message,
                 workspace: workspace,
                 client: external_client()
               )

      assert Enum.any?(result.actions, &(&1["tool"] == eval_case.expected_tool))
      assert result.snapshot["facts"] != []
      assert_message_includes(result.message, eval_case.message_must_include)
      assert_message_does_not_include(result.message, eval_case.message_must_not_include)
    end
  end

  for eval_case <- @ambiguous_task_cases do
    test "#{eval_case.id} asks which goal a task belongs to when multiple goals match" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})
      seed_workspace(workspace, eval_case.seed_items)

      assert {:ok, result} =
               Assistant.respond(
                 eval_case.user_message,
                 workspace: workspace,
                 client: external_client()
               )

      assert result.needs_follow_up == true
      assert result.message =~ "?"
      assert result.snapshot["active_draft"]["kind"] == "task"

      assert String.contains?(
               result.snapshot["active_draft"]["title"],
               eval_case.expected_title_contains
             )

      assert result.snapshot["active_draft"]["parent_goal_title"] == nil
      assert graph_draft_count(result.snapshot["tasks"]) == 1
      assert length(result.snapshot["goals"]) == eval_case.expected_goals_count
    end
  end

  for eval_case <- @goal_save_cases do
    test "#{eval_case.id} saves a complete goal without a follow-up" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})

      assert {:ok, result} =
               Assistant.respond(
                 eval_case.user_message,
                 workspace: workspace,
                 client: external_client()
               )

      assert result.needs_follow_up == false
      assert result.snapshot["active_draft"] == nil
      assert [%{} = goal] = result.snapshot["goals"]
      assert goal["kind"] == "goal"
      assert String.contains?(goal["title"], eval_case.expected_title_contains)
      assert String.starts_with?(goal["target_date"], eval_case.expected_target_date_prefix)
      assert result.snapshot["tasks"] == []
    end
  end

  for eval_case <- @standalone_task_cases do
    test "#{eval_case.id} keeps a standalone chore unattached when no parent goal exists" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})

      assert {:ok, result} =
               Assistant.respond(
                 eval_case.user_message,
                 workspace: workspace,
                 client: external_client()
               )

      assert result.needs_follow_up == false
      assert result.snapshot["active_draft"] == nil
      assert result.snapshot["goals"] == []
      assert [%{} = task] = result.snapshot["tasks"]
      assert task["kind"] == "task"
      assert String.contains?(task["title"], eval_case.expected_title_contains)
      assert task["due_date"] == eval_case.expected_due_date
      assert task["parent_goal_title"] == nil
    end
  end

  for eval_case <- @multiturn_goal_cases do
    test "#{eval_case.id} carries the draft across turns and saves when criteria become concrete" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})

      assert {:ok, first_result} =
               Assistant.respond(
                 eval_case.first_user_message,
                 workspace: workspace,
                 client: external_client()
               )

      assert first_result.needs_follow_up == true
      assert first_result.snapshot["active_draft"]["kind"] == "goal"

      history = [
        %{role: "user", content: eval_case.first_user_message},
        %{role: "assistant", content: first_result.message}
      ]

      assert {:ok, second_result} =
               Assistant.respond(
                 eval_case.second_user_message,
                 workspace: workspace,
                 history: history,
                 client: external_client()
               )

      assert second_result.needs_follow_up == false
      assert second_result.snapshot["active_draft"] == nil
      assert [%{} = goal] = second_result.snapshot["goals"]
      assert String.contains?(goal["title"], eval_case.expected_goal_title_contains)
      assert String.starts_with?(goal["target_date"], eval_case.expected_target_date_prefix)
    end
  end

  for eval_case <- @multiline_goal_cases do
    test "#{eval_case.id} keeps newline-separated goals as distinct graph objects" do
      eval_case = unquote(Macro.escape(eval_case))
      workspace = start_supervised!({Workspace, path: temp_path(eval_case.id)})

      assert {:ok, result} =
               Assistant.respond(
                 eval_case.user_message,
                 workspace: workspace,
                 client: external_client()
               )

      titles =
        result.snapshot["goals"]
        |> Enum.map(&String.downcase(&1["title"]))

      assert length(result.snapshot["goals"]) == 2
      assert result.snapshot["tasks"] == []
      assert result.snapshot["active_draft"]["kind"] == "goal"

      Enum.each(eval_case.message_must_include, fn expected_text ->
        assert String.contains?(String.downcase(result.message), String.downcase(expected_text))
      end)

      assert_message_does_not_include(result.message, eval_case.message_must_not_include)

      assert exactly_one_goal_group_mentioned?(
               result.message,
               eval_case.message_focus_token_groups
             )

      Enum.each(eval_case.expected_title_tokens, fn expected_tokens ->
        assert Enum.any?(titles, fn title ->
                 Enum.all?(expected_tokens, &String.contains?(title, &1))
               end)
      end)
    end
  end

  defp seed_workspace(workspace, seed_items) do
    Enum.each(seed_items, fn seed_item ->
      Workspace.upsert_draft(seed_item.kind, seed_item.fields, workspace)
      assert {:ok, _snapshot} = Workspace.save_draft(workspace)
    end)
  end

  defp saved_items_count(items) do
    Enum.count(items, &(&1["status"] != "being_drafted"))
  end

  defp graph_draft_count(items) do
    Enum.count(items, &(&1["status"] == "being_drafted"))
  end

  defp assert_message_does_not_include(message, substrings) do
    downcased = String.downcase(message)

    Enum.each(substrings, fn substring ->
      refute String.contains?(downcased, String.downcase(substring))
    end)
  end

  defp assert_message_includes(message, substrings) do
    downcased = String.downcase(message)

    Enum.each(substrings, fn substring ->
      assert String.contains?(downcased, String.downcase(substring))
    end)
  end

  defp exactly_one_goal_group_mentioned?(message, token_groups) do
    downcased = String.downcase(message)

    token_groups
    |> Enum.count(fn token_group ->
      Enum.all?(token_group, &String.contains?(downcased, &1))
    end)
    |> Kernel.==(1)
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

  defp external_client do
    Application.fetch_env!(:g3, :external_eval_model_client)
  end
end
