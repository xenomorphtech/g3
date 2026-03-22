defmodule G3.TestSupport.PromptEval do
  @moduledoc false

  alias G3.Tracker.Assistant
  alias G3.Tracker.Workspace

  def run_suite(eval_cases, opts) when is_list(eval_cases) and is_list(opts) do
    results = Enum.map(eval_cases, &run_case(&1, opts))
    %{results: results, summary: summarize_results(results)}
  end

  def run_ab(eval_cases, opts) when is_list(eval_cases) and is_list(opts) do
    baseline_opts = Keyword.fetch!(opts, :baseline)
    candidate_opts = Keyword.fetch!(opts, :candidate)

    baseline = run_suite(eval_cases, baseline_opts)
    candidate = run_suite(eval_cases, candidate_opts)

    %{
      baseline: baseline,
      candidate: candidate,
      comparison: compare_results(baseline.results, candidate.results)
    }
  end

  defp run_case(eval_case, opts) do
    workspace_prefix = Keyword.get(opts, :workspace_prefix, "prompt-eval")
    assistant_opts = Keyword.drop(opts, [:workspace_prefix])
    {:ok, workspace} = Workspace.start_link(path: temp_path(workspace_prefix, eval_case.id))

    try do
      seed_workspace(workspace, Map.get(eval_case, :seed_items, []))
      seed_drafts(workspace, Map.get(eval_case, :seed_drafts, []))

      {turn_reports, _history, final_result} =
        Enum.reduce(eval_case.turns, {[], [], nil}, fn turn, {reports, history, _result} ->
          case Assistant.respond(
                 turn.user_message,
                 Keyword.merge(assistant_opts,
                   workspace: workspace,
                   history: history,
                   focus_object: Map.get(turn, :focus_object)
                 )
               ) do
            {:ok, result} ->
              turn_report = evaluate_turn(turn, result)

              {
                reports ++ [turn_report],
                append_history(history, turn.user_message, result.message),
                result
              }

            {:error, reason} ->
              {
                reports ++ [error_turn_report(turn, reason)],
                history,
                nil
              }
          end
        end)

      checks_passed = Enum.sum(Enum.map(turn_reports, & &1.checks_passed))
      checks_total = Enum.sum(Enum.map(turn_reports, & &1.checks_total))

      %{
        id: eval_case.id,
        passed?: Enum.all?(turn_reports, & &1.passed?),
        checks_passed: checks_passed,
        checks_total: checks_total,
        score: score(checks_passed, checks_total),
        turn_reports: turn_reports,
        final_result: final_result
      }
    after
      GenServer.stop(workspace)
    end
  end

  defp evaluate_turn(turn, result) do
    expected = Map.get(turn, :expected, %{})

    checks =
      []
      |> maybe_add_check(
        Map.has_key?(expected, :needs_follow_up),
        "needs_follow_up matches",
        result.needs_follow_up == expected[:needs_follow_up]
      )
      |> maybe_add_check(
        Map.has_key?(expected, :goals_count),
        "goals_count matches",
        length(result.snapshot["goals"]) == expected[:goals_count]
      )
      |> maybe_add_check(
        Map.has_key?(expected, :tasks_count),
        "tasks_count matches",
        length(result.snapshot["tasks"]) == expected[:tasks_count]
      )
      |> maybe_add_check(
        Map.has_key?(expected, :facts_count),
        "facts_count matches",
        length(result.snapshot["facts"]) == expected[:facts_count]
      )
      |> maybe_add_check(
        Map.has_key?(expected, :action_tools),
        "action_tools match",
        Enum.map(result.actions, & &1["tool"]) == expected[:action_tools]
      )
      |> maybe_add_check(
        Map.has_key?(expected, :active_draft_kind),
        "active_draft_kind matches",
        active_draft_kind_matches?(result.snapshot["active_draft"], expected[:active_draft_kind])
      )
      |> maybe_add_check(
        Map.has_key?(expected, :active_title_contains),
        "active draft title contains expected text",
        active_title_contains?(result.snapshot["active_draft"], expected[:active_title_contains])
      )
      |> maybe_add_check(
        Map.has_key?(expected, :active_draft_fields),
        "active draft fields match expected subset",
        subset_matches?(result.snapshot["active_draft"], expected[:active_draft_fields])
      )
      |> maybe_add_check(
        Map.has_key?(expected, :saved_goal_fields),
        "saved goal fields match expected subset",
        first_saved_item_matches?(result.snapshot["goals"], expected[:saved_goal_fields])
      )
      |> maybe_add_check(
        Map.has_key?(expected, :saved_task_fields),
        "saved task fields match expected subset",
        first_saved_item_matches?(result.snapshot["tasks"], expected[:saved_task_fields])
      )
      |> maybe_add_check(
        Map.has_key?(expected, :saved_fact_fields),
        "saved fact fields match expected subset",
        first_saved_item_matches?(result.snapshot["facts"], expected[:saved_fact_fields])
      )
      |> add_message_checks(result.message, expected)
      |> add_title_checks(result.snapshot["goals"], "goal", Map.get(expected, :goal_titles, []))
      |> add_title_checks(result.snapshot["tasks"], "task", Map.get(expected, :task_titles, []))
      |> add_title_checks(result.snapshot["facts"], "fact", Map.get(expected, :fact_titles, []))

    checks_passed = Enum.count(checks, & &1.pass?)
    checks_total = length(checks)

    %{
      user_message: turn.user_message,
      checks: checks,
      checks_passed: checks_passed,
      checks_total: checks_total,
      passed?: Enum.all?(checks, & &1.pass?),
      score: score(checks_passed, checks_total),
      result: result
    }
  end

  defp error_turn_report(turn, reason) do
    %{
      user_message: turn.user_message,
      checks: [%{label: "assistant responds successfully", pass?: false, detail: inspect(reason)}],
      checks_passed: 0,
      checks_total: 1,
      passed?: false,
      score: 0.0,
      result: nil
    }
  end

  defp maybe_add_check(checks, true, label, pass?) do
    checks ++ [%{label: label, pass?: pass?}]
  end

  defp maybe_add_check(checks, false, _label, _pass?), do: checks

  defp add_message_checks(checks, message, expected) do
    checks
    |> Kernel.++(
      Enum.map(Map.get(expected, :message_must_include, []), fn fragment ->
        %{
          label: ~s(message includes "#{fragment}"),
          pass?: String.contains?(message, fragment)
        }
      end)
    )
    |> Kernel.++(
      Enum.map(Map.get(expected, :message_must_not_include, []), fn fragment ->
        %{
          label: ~s(message omits "#{fragment}"),
          pass?: not String.contains?(String.downcase(message), String.downcase(fragment))
        }
      end)
    )
  end

  defp add_title_checks(checks, items, kind, expected_titles) do
    actual_titles = Enum.map(items, & &1["title"])

    checks ++
      Enum.map(expected_titles, fn expected_title ->
        %{
          label: "#{kind} title includes #{expected_title}",
          pass?: expected_title in actual_titles
        }
      end)
  end

  defp active_draft_kind_matches?(nil, nil), do: true
  defp active_draft_kind_matches?(nil, _kind), do: false
  defp active_draft_kind_matches?(_draft, nil), do: false
  defp active_draft_kind_matches?(draft, kind), do: draft["kind"] == kind

  defp active_title_contains?(nil, _expected_text), do: false
  defp active_title_contains?(_draft, expected_text) when not is_binary(expected_text), do: false

  defp active_title_contains?(draft, expected_text) do
    String.contains?(draft["title"] || "", expected_text)
  end

  defp first_saved_item_matches?(items, expected_subset) do
    items
    |> Enum.find(&(&1["status"] != "being_drafted"))
    |> subset_matches?(expected_subset)
  end

  defp subset_matches?(nil, _expected_subset), do: false
  defp subset_matches?(_actual, expected_subset) when not is_map(expected_subset), do: false

  defp subset_matches?(actual, expected_subset) do
    Enum.all?(expected_subset, fn {key, expected_value} ->
      actual[key] == expected_value
    end)
  end

  defp summarize_results(results) do
    checks_passed = Enum.sum(Enum.map(results, & &1.checks_passed))
    checks_total = Enum.sum(Enum.map(results, & &1.checks_total))

    %{
      cases_total: length(results),
      cases_passed: Enum.count(results, & &1.passed?),
      checks_passed: checks_passed,
      checks_total: checks_total,
      score: score(checks_passed, checks_total)
    }
  end

  defp compare_results(baseline_results, candidate_results) do
    baseline_by_id = Map.new(baseline_results, &{&1.id, &1})

    cases =
      Enum.map(candidate_results, fn candidate_result ->
        baseline_result = Map.fetch!(baseline_by_id, candidate_result.id)

        %{
          id: candidate_result.id,
          baseline_score: baseline_result.score,
          candidate_score: candidate_result.score,
          delta: candidate_result.score - baseline_result.score,
          baseline_passed?: baseline_result.passed?,
          candidate_passed?: candidate_result.passed?
        }
      end)

    %{
      cases: cases,
      improved_case_count: Enum.count(cases, &(&1.delta > 0)),
      regressed_case_count: Enum.count(cases, &(&1.delta < 0)),
      unchanged_case_count: Enum.count(cases, &(&1.delta == 0))
    }
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

      case Workspace.save_draft(workspace) do
        {:ok, _snapshot} -> :ok
        {:error, reason} -> raise "failed to seed workspace for prompt eval: #{inspect(reason)}"
      end
    end)
  end

  defp seed_drafts(workspace, seed_drafts) do
    Enum.each(seed_drafts, fn seed_draft ->
      Workspace.start_draft(seed_draft.kind, seed_draft.fields, workspace)
    end)
  end

  defp temp_path(prefix, id) do
    path =
      Path.join(
        System.tmp_dir!(),
        "g3-#{prefix}-#{id}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.json"
      )

    File.rm(path)
    path
  end

  defp score(_checks_passed, 0), do: 0.0
  defp score(checks_passed, checks_total), do: checks_passed / checks_total
end
