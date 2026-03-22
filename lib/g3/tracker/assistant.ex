defmodule G3.Tracker.Assistant do
  @moduledoc false

  @link_stopwords ~w(a an and by for from i in into is my of on or that the this to with your)
  @detail_segment_prefixes [
    "success means",
    "success looks like",
    "success criteria",
    "target date",
    "due date",
    "deadline",
    "priority",
    "details",
    "notes",
    "because",
    "so that",
    "it should",
    "this should"
  ]
  @item_line_verbs ~w(
    automate become build create cut design develop draft finish grow improve implement launch
    learn make migrate plan practice prototype publish reduce run ship start study write
  )

  alias G3.Tracker.Draft
  alias G3.Tracker.FactSearch
  alias G3.Tracker.Prompt
  alias G3.Tracker.Workspace

  def respond(user_message, opts \\ []) when is_binary(user_message) do
    workspace = Keyword.get(opts, :workspace, Workspace)
    client = Keyword.get(opts, :client, configured_client())
    history = Keyword.get(opts, :history, [])
    prompt_module = Keyword.get(opts, :prompt_module, Prompt)
    focus_object = Keyword.get(opts, :focus_object)
    snapshot = Workspace.snapshot(workspace)

    request = %{
      system_instruction: prompt_module.system_instruction(snapshot, focus_object),
      contents: prompt_module.build_contents(history, user_message),
      response_schema: prompt_module.response_schema()
    }

    with {:ok, result} <- call_client(client, request),
         {:ok, normalized} <- normalize_result(result),
         {:ok, resolved} <-
           maybe_resolve_search_actions(
             normalized,
             snapshot,
             user_message,
             history,
             focus_object,
             prompt_module,
             client
           ),
         {:ok, applied_snapshot} <- apply_actions(resolved["actions"], workspace, focus_object) do
      next_snapshot =
        user_message
        |> ensure_active_draft(snapshot, applied_snapshot, resolved["actions"], workspace)
        |> ensure_split_objects(
          user_message,
          resolved["message"],
          snapshot,
          resolved["actions"],
          workspace
        )

      needs_follow_up =
        normalize_needs_follow_up(
          resolved["needs_follow_up"],
          resolved["actions"],
          next_snapshot
        )

      {:ok,
       %{
         message: resolved["message"],
         needs_follow_up: needs_follow_up,
         snapshot: next_snapshot,
         actions: Map.get(resolved, "all_actions", resolved["actions"])
       }}
    end
  end

  defp call_client(client, request) when is_function(client, 1), do: client.(request)
  defp call_client(client, request), do: client.respond(request)

  defp normalize_result(%{} = result) do
    {:ok,
     %{
       "message" => Map.get(result, "message", ""),
       "needs_follow_up" => Map.get(result, "needs_follow_up", false),
       "actions" => normalize_actions(Map.get(result, "actions", []))
     }}
  end

  defp normalize_result(_result), do: {:error, :invalid_result_shape}

  defp normalize_actions(actions) when is_list(actions) do
    Enum.reduce(actions, [], fn action, acc ->
      case acc do
        [] ->
          [action]

        _ ->
          previous = List.last(acc)

          if mergeable_fragment_pair?(previous, action) do
            Enum.drop(acc, -1) ++ [merge_action_fragments(previous, action)]
          else
            acc ++ [action]
          end
      end
    end)
  end

  defp normalize_actions(_actions), do: []

  defp mergeable_fragment_pair?(previous, action) do
    same_tool? =
      Map.get(previous, "tool") == Map.get(action, "tool") and
        Map.get(previous, "tool") in ["upsert_draft", "start_new_draft"]

    same_tool? and incomplete_draft_action_fragment?(previous)
  end

  defp incomplete_draft_action_fragment?(action) do
    normalize_kind(Map.get(action, "kind")) == nil or
      not (is_map(Map.get(action, "fields")) and map_size(Map.get(action, "fields")) > 0)
  end

  defp merge_action_fragments(previous, action) do
    merged_fields =
      Map.merge(
        Map.get(previous, "fields", %{}) || %{},
        Map.get(action, "fields", %{}) || %{}
      )

    merged = Map.merge(previous, action)

    if merged_fields == %{} do
      Map.delete(merged, "fields")
    else
      Map.put(merged, "fields", merged_fields)
    end
  end

  defp maybe_resolve_search_actions(
         normalized,
         snapshot,
         user_message,
         history,
         focus_object,
         prompt_module,
         client
       ) do
    search_actions = Enum.filter(normalized["actions"], &search_action?/1)
    non_search_actions = Enum.reject(normalized["actions"], &search_action?/1)

    if search_actions == [] do
      {:ok, Map.put(normalized, "all_actions", normalized["actions"])}
    else
      tool_results = execute_search_actions(search_actions, snapshot, user_message)

      search_history =
        history ++
          [%{"role" => "user", "content" => user_message}] ++
          maybe_assistant_history(normalized["message"]) ++
          [%{"role" => "user", "content" => tool_results_message(user_message, tool_results)}]

      follow_up_request = %{
        system_instruction: prompt_module.system_instruction(snapshot, focus_object),
        contents:
          prompt_module.build_contents(
            search_history,
            "Use the fact search results above to answer the original request. If another search is not necessary, do not call search again."
          ),
        response_schema: prompt_module.response_schema()
      }

      with {:ok, follow_up_result} <- call_client(client, follow_up_request),
           {:ok, normalized_follow_up} <- normalize_result(follow_up_result) do
        follow_up_actions = Enum.reject(normalized_follow_up["actions"], &search_action?/1)

        {:ok,
         normalized_follow_up
         |> Map.put("actions", non_search_actions ++ follow_up_actions)
         |> Map.put("all_actions", search_actions ++ non_search_actions ++ follow_up_actions)}
      end
    end
  end

  defp maybe_assistant_history(message) when is_binary(message) do
    if String.trim(message) == "" do
      []
    else
      [%{"role" => "assistant", "content" => message}]
    end
  end

  defp search_action?(%{"tool" => tool}), do: tool in ["search_facts_bm25", "search_facts_grep"]
  defp search_action?(_action), do: false

  defp execute_search_actions(actions, snapshot, user_message) do
    facts = snapshot["facts"] || []

    Enum.map(actions, fn action ->
      case action do
        %{"tool" => "search_facts_bm25"} ->
          case resolve_bm25_query(action, user_message) do
            nil ->
              %{"tool" => "search_facts_bm25", "error" => "Missing search input."}

            query ->
              %{
                "tool" => "search_facts_bm25",
                "query" => query,
                "results" => FactSearch.bm25(query, facts)
              }
          end

        %{"tool" => "search_facts_grep"} ->
          case resolve_grep_pattern(action, user_message) do
            nil ->
              %{"tool" => "search_facts_grep", "error" => "Missing search input."}

            pattern ->
              %{
                "tool" => "search_facts_grep",
                "pattern" => pattern,
                "results" => FactSearch.grep(pattern, facts)
              }
          end

        %{"tool" => tool} ->
          %{"tool" => tool, "error" => "Missing search input."}
      end
    end)
  end

  defp resolve_bm25_query(action, user_message) do
    normalize_search_input(action["query"]) ||
      extract_bm25_query(user_message)
  end

  defp resolve_grep_pattern(action, user_message) do
    normalize_search_input(action["pattern"]) ||
      extract_slash_pattern(user_message) ||
      extract_quoted_pattern(user_message) ||
      extract_search_tail(user_message)
  end

  defp normalize_search_input(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_search_input(_value), do: nil

  defp extract_bm25_query(user_message) do
    user_message
    |> extract_search_tail()
    |> normalize_search_input()
  end

  defp extract_slash_pattern(user_message) when is_binary(user_message) do
    case Regex.run(~r{/([^/\n]+(?:/[^/\n]+)*)/}, user_message, capture: :all_but_first) do
      [pattern] -> String.trim(pattern)
      _ -> nil
    end
  end

  defp extract_slash_pattern(_user_message), do: nil

  defp extract_quoted_pattern(user_message) when is_binary(user_message) do
    case Regex.run(~r/"([^"\n]+)"|'([^'\n]+)'/, user_message, capture: :all_but_first) do
      [double_quoted, nil] when is_binary(double_quoted) -> String.trim(double_quoted)
      [nil, single_quoted] when is_binary(single_quoted) -> String.trim(single_quoted)
      [double_quoted, single_quoted] -> normalize_search_input(double_quoted || single_quoted)
      _ -> nil
    end
  end

  defp extract_quoted_pattern(_user_message), do: nil

  defp extract_search_tail(user_message) when is_binary(user_message) do
    user_message
    |> String.trim()
    |> then(fn text ->
      Enum.reduce(
        [
          ~r/^\s*what\s+facts\s+do\s+we\s+have\s+about\s+/iu,
          ~r/^\s*what\s+do\s+we\s+know\s+about\s+/iu,
          ~r/^\s*(?:search|find|look\s+up)\s+facts\s+(?:for|about)\s+/iu,
          ~r/^\s*(?:search|grep)\s+(?:the\s+)?facts\s+(?:for|about)\s+/iu
        ],
        text,
        fn pattern, acc -> Regex.replace(pattern, acc, "") end
      )
    end)
    |> String.trim_trailing("?")
    |> String.trim_trailing(".")
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp extract_search_tail(_user_message), do: nil

  defp tool_results_message(user_message, tool_results) do
    """
    Tool results for the original user request:
    #{user_message}

    #{Jason.encode!(tool_results, pretty: true)}
    """
  end

  defp apply_actions(actions, workspace, focus_object) when is_list(actions) do
    Enum.reduce_while(actions, {:ok, Workspace.snapshot(workspace)}, fn action,
                                                                        {:ok, _snapshot} ->
      case apply_action(action, workspace, focus_object) do
        {:ok, snapshot} -> {:cont, {:ok, snapshot}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_actions(_actions, workspace, _focus_object), do: {:ok, Workspace.snapshot(workspace)}

  defp apply_action(%{"tool" => "upsert_draft"} = action, workspace, _focus_object) do
    kind = resolve_draft_action_kind(action, workspace)
    fields = Map.get(action, "fields", %{}) || %{}

    if meaningful_draft_action?(kind, fields, workspace) do
      {:ok, Workspace.upsert_draft(kind, fields, workspace)}
    else
      {:ok, Workspace.snapshot(workspace)}
    end
  end

  defp apply_action(%{"tool" => "start_new_draft"} = action, workspace, _focus_object) do
    kind = resolve_draft_action_kind(action, workspace)
    fields = Map.get(action, "fields", %{}) || %{}

    if meaningful_draft_action?(kind, fields, workspace) do
      {:ok, Workspace.start_draft(kind, fields, workspace)}
    else
      {:ok, Workspace.snapshot(workspace)}
    end
  end

  defp apply_action(%{"tool" => "save_draft"} = action, workspace, focus_object) do
    maybe_upsert_before_save(workspace, action, focus_object)
  end

  defp apply_action(%{"tool" => "clear_draft"}, workspace, _focus_object) do
    {:ok, Workspace.clear_draft(workspace)}
  end

  defp apply_action(_action, workspace, _focus_object), do: {:ok, Workspace.snapshot(workspace)}

  defp maybe_upsert_before_save(workspace, action, focus_object) do
    workspace =
      workspace
      |> maybe_upsert_from_save_action(action)
      |> maybe_attach_parent_goal(focus_object)

    case Workspace.save_draft(workspace) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, :no_active_draft} -> {:ok, Workspace.snapshot(workspace)}
      {:error, {:draft_incomplete, _missing}} -> {:ok, Workspace.snapshot(workspace)}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_upsert_from_save_action(workspace, action) do
    case {Workspace.snapshot(workspace)["active_draft"], normalize_kind(Map.get(action, "kind")),
          Map.get(action, "fields")} do
      {nil, kind, fields}
      when kind in ["goal", "task", "fact"] and is_map(fields) and map_size(fields) > 0 ->
        _snapshot = Workspace.upsert_draft(kind, fields, workspace)
        workspace

      _ ->
        workspace
    end
  end

  defp maybe_attach_parent_goal(workspace, focus_object) do
    snapshot = Workspace.snapshot(workspace)

    case snapshot["active_draft"] do
      %{"kind" => "task"} = draft ->
        maybe_attach_goal_link(workspace, snapshot, draft, "parent_goal_title", focus_object)

      %{"kind" => "fact"} = draft ->
        maybe_attach_goal_link(workspace, snapshot, draft, "project_title", focus_object)

      _ ->
        workspace
    end
  end

  defp maybe_attach_goal_link(workspace, snapshot, draft, field_name, focus_object) do
    linked_goal_title = draft[field_name]

    cond do
      present_string?(linked_goal_title) ->
        workspace

      focused_goal_title = focused_goal_title(focus_object) ->
        _snapshot =
          Workspace.upsert_draft(
            draft["kind"],
            %{field_name => focused_goal_title},
            workspace
          )

        workspace

      inferred_goal_title = infer_parent_goal_title(draft, snapshot["goals"]) ->
        _snapshot =
          Workspace.upsert_draft(
            draft["kind"],
            %{field_name => inferred_goal_title},
            workspace
          )

        workspace

      true ->
        workspace
    end
  end

  defp focused_goal_title(%{"kind" => "goal", "title" => title}) when is_binary(title), do: title
  defp focused_goal_title(_focus_object), do: nil

  defp normalize_kind(kind) when kind in ["goal", "task", "fact"], do: kind
  defp normalize_kind(_kind), do: nil

  defp resolve_draft_action_kind(action, workspace) do
    normalize_kind(Map.get(action, "kind")) ||
      get_in(Workspace.snapshot(workspace), ["active_draft", "kind"])
  end

  defp meaningful_draft_action?(kind, fields, workspace) do
    kind in ["goal", "task", "fact"] and
      (map_size(fields) > 0 or Workspace.snapshot(workspace)["active_draft"] != nil)
  end

  defp ensure_active_draft(user_message, previous_snapshot, next_snapshot, actions, workspace) do
    cond do
      next_snapshot["active_draft"] != nil ->
        next_snapshot

      save_requested?(actions) ->
        next_snapshot

      clear_draft_requested?(actions) ->
        next_snapshot

      materialization = infer_materialization(user_message, previous_snapshot, actions) ->
        Workspace.upsert_draft(materialization.kind, materialization.fields, workspace)

      true ->
        next_snapshot
    end
  end

  defp ensure_split_objects(
         next_snapshot,
         user_message,
         assistant_message,
         previous_snapshot,
         actions,
         workspace
       ) do
    segments = split_item_segments(user_message)

    candidates =
      segments
      |> Enum.map(
        &infer_segment_materialization(&1, previous_snapshot, actions, assistant_message)
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&materialization_identity/1)

    cond do
      length(segments) < 2 ->
        next_snapshot

      length(candidates) < 2 ->
        next_snapshot

      not split_materialization?(segments, candidates, previous_snapshot, assistant_message) ->
        next_snapshot

      true ->
        Enum.reduce(candidates, next_snapshot, fn candidate, snapshot_acc ->
          if materialized_in_snapshot?(snapshot_acc, candidate) do
            snapshot_acc
          else
            materialize_candidate(snapshot_acc, candidate, workspace)
          end
        end)
    end
  end

  defp normalize_needs_follow_up(model_value, actions, next_snapshot) do
    cond do
      save_requested?(actions) and next_snapshot["active_draft"] == nil -> false
      incomplete_active_draft?(next_snapshot) -> true
      true -> model_value
    end
  end

  defp incomplete_active_draft?(%{"active_draft" => nil}), do: false

  defp incomplete_active_draft?(%{"active_draft" => draft}) do
    not Draft.completion(draft).ready?
  end

  defp clear_draft_requested?(actions) do
    Enum.any?(actions, &(Map.get(&1, "tool") == "clear_draft"))
  end

  defp save_requested?(actions) do
    Enum.any?(actions, &(Map.get(&1, "tool") == "save_draft"))
  end

  defp materialize_candidate(%{"active_draft" => nil}, candidate, workspace) do
    Workspace.upsert_draft(candidate.kind, candidate.fields, workspace)
  end

  defp materialize_candidate(_snapshot, candidate, workspace) do
    Workspace.start_draft(candidate.kind, candidate.fields, workspace)
  end

  defp infer_materialization(user_message, previous_snapshot, actions) do
    kind = infer_kind(user_message, previous_snapshot, actions)
    action_fields = merge_action_fields(actions)
    fields = materialization_fields(user_message, kind, action_fields)

    if kind in ["goal", "task", "fact"] and map_size(fields) > 0 do
      %{kind: kind, fields: fields}
    end
  end

  defp infer_kind(_user_message, %{"active_draft" => %{"kind" => kind}}, _actions)
       when kind in ["goal", "task", "fact"] do
    kind
  end

  defp infer_kind(user_message, _previous_snapshot, actions) do
    unique_action_kind(actions) ||
      cond do
        fact_message?(user_message) -> "fact"
        task_message?(user_message) -> "task"
        goal_message?(user_message) -> "goal"
        true -> nil
      end
  end

  defp materialization_fields(user_message, kind, action_fields) do
    action_fields
    |> maybe_put_title(infer_title(user_message, kind))
    |> maybe_put_summary(user_message)
  end

  defp merge_action_fields(actions) do
    Enum.reduce(actions, %{}, fn
      %{"tool" => tool, "fields" => fields}, acc
      when tool in ["upsert_draft", "start_new_draft"] and is_map(fields) ->
        Map.merge(acc, fields)

      _action, acc ->
        acc
    end)
  end

  defp maybe_put_title(fields, nil), do: fields
  defp maybe_put_title(%{"title" => title} = fields, _fallback) when is_binary(title), do: fields
  defp maybe_put_title(fields, fallback), do: Map.put(fields, "title", fallback)

  defp maybe_put_summary(fields, _user_message) when map_size(fields) > 0, do: fields

  defp maybe_put_summary(fields, user_message),
    do: Map.put(fields, "summary", String.trim(user_message))

  defp infer_title(user_message, "goal") do
    user_message = strip_list_prefix(user_message)

    cond do
      captures = Regex.run(~r/^i want to\s+(.+?)[.!]?$/i, user_message, capture: :all_but_first) ->
        captures |> List.first() |> clean_title()

      captures =
          Regex.run(~r/^my goal is to\s+(.+?)[.!]?$/i, user_message, capture: :all_but_first) ->
        captures |> List.first() |> clean_title()

      bare_item_segment?(user_message) ->
        clean_title(user_message)

      true ->
        nil
    end
  end

  defp infer_title(user_message, "task") do
    user_message = strip_list_prefix(user_message)

    cond do
      captures =
          Regex.run(
            ~r/^(?:create|add|make)\s+(?:a\s+)?task\s+to\s+(.+?)(?:\s+by\s+\d{4}-\d{2}-\d{2}.*)?[.!]?$/i,
            user_message,
            capture: :all_but_first
          ) ->
        captures |> List.first() |> clean_title()

      bare_item_segment?(user_message) ->
        clean_title(user_message)

      true ->
        nil
    end
  end

  defp infer_title(user_message, "fact") do
    user_message
    |> strip_list_prefix()
    |> String.replace(~r/^(?:fact|note|constraint|decision)\s*:\s*/i, "")
    |> String.replace(~r/^remember(?:\s+that)?\s+/i, "")
    |> clean_title()
  end

  defp infer_title(_user_message, _kind), do: nil

  defp clean_title(text) when is_binary(text) do
    text
    |> String.trim()
    |> String.trim_trailing(".")
    |> case do
      "" -> nil
      trimmed -> uppercase_first(trimmed)
    end
  end

  defp uppercase_first(text) do
    {first, rest} = String.split_at(text, 1)
    String.upcase(first) <> rest
  end

  defp task_message?(user_message) do
    Regex.match?(~r/^(?:create|add|make)\s+(?:a\s+)?task\b/i, user_message)
  end

  defp fact_message?(user_message) do
    Regex.match?(
      ~r/^(?:fact|note|constraint|decision)\s*:|^remember(?:\s+that)?\b/i,
      user_message
    )
  end

  defp goal_message?(user_message) do
    Regex.match?(~r/^(?:i want to|my goal is to)\b/i, user_message)
  end

  defp split_item_segments(user_message) do
    user_message
    |> String.split(~r/\r?\n+/, trim: true)
    |> Enum.map(&strip_list_prefix/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_list_prefix(text) do
    text
    |> String.trim()
    |> String.replace(~r/^(?:[-*•]\s+|\d+[.)]\s+)/u, "")
  end

  defp infer_segment_materialization(segment, previous_snapshot, actions, assistant_message) do
    kind = infer_segment_kind(segment, previous_snapshot, actions, assistant_message)
    title = infer_title(segment, kind)

    if kind in ["goal", "task"] and present_string?(title) do
      %{kind: kind, fields: %{"title" => title}}
    end
  end

  defp infer_segment_kind(segment, previous_snapshot, actions, assistant_message) do
    fallback_kind =
      unique_action_kind(actions) ||
        message_claimed_kind(assistant_message) ||
        (previous_snapshot["active_draft"] && previous_snapshot["active_draft"]["kind"])

    cond do
      fact_message?(segment) -> "fact"
      task_message?(segment) -> "task"
      goal_message?(segment) -> "goal"
      bare_item_segment?(segment) and fallback_kind in ["goal", "task", "fact"] -> fallback_kind
      bare_item_segment?(segment) -> "goal"
      true -> nil
    end
  end

  defp unique_action_kind(actions) do
    case actions
         |> Enum.map(&draft_action_kind_signal/1)
         |> Enum.reject(&is_nil/1)
         |> Enum.uniq() do
      [kind] -> kind
      _ -> nil
    end
  end

  defp draft_action_kind_signal(%{"tool" => tool, "kind" => kind, "fields" => fields})
       when tool in ["upsert_draft", "start_new_draft"] and is_map(fields) and
              map_size(fields) > 0 do
    normalize_kind(kind)
  end

  defp draft_action_kind_signal(_action), do: nil

  defp message_claimed_kind(message) when is_binary(message) do
    cond do
      Regex.match?(~r/\b(?:two|2|multiple|several)\s+goals?\b/i, message) -> "goal"
      Regex.match?(~r/\b(?:two|2|multiple|several)\s+tasks?\b/i, message) -> "task"
      Regex.match?(~r/\b(?:two|2|multiple|several)\s+facts?\b/i, message) -> "fact"
      true -> nil
    end
  end

  defp message_claimed_kind(_message), do: nil

  defp split_materialization?(segments, candidates, previous_snapshot, assistant_message) do
    message_claimed_kind(assistant_message) in ["goal", "task"] or
      (previous_snapshot["active_draft"] == nil and length(candidates) == length(segments))
  end

  defp materialization_identity(%{kind: kind, fields: fields}) do
    {kind, normalize_title(fields["title"])}
  end

  defp materialized_in_snapshot?(snapshot, %{kind: kind, fields: fields}) do
    bucket =
      case kind do
        "goal" -> snapshot["goals"]
        "task" -> snapshot["tasks"]
        "fact" -> snapshot["facts"]
      end

    Enum.any?(bucket || [], fn item ->
      semantically_same_title?(item["title"], fields["title"])
    end)
  end

  defp normalize_title(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  defp normalize_title(_value), do: ""

  defp semantically_same_title?(left, right) do
    left_title = normalize_title(left)
    right_title = normalize_title(right)

    cond do
      left_title == "" or right_title == "" ->
        false

      left_title == right_title ->
        true

      String.contains?(left_title, right_title) or String.contains?(right_title, left_title) ->
        true

      true ->
        left_tokens = title_tokens(left_title)
        right_tokens = title_tokens(right_title)
        overlap = MapSet.size(MapSet.intersection(left_tokens, right_tokens))
        minimum_size = min(MapSet.size(left_tokens), MapSet.size(right_tokens))

        overlap >= 3 and overlap * 10 >= minimum_size * 6
    end
  end

  defp title_tokens(normalized_title) do
    normalized_title
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reject(&(&1 in ["a", "an", "the", "for", "to"]))
    |> MapSet.new()
  end

  defp bare_item_segment?(segment) when is_binary(segment) do
    trimmed = String.trim(segment)
    downcased = String.downcase(trimmed)
    [first_word | _rest] = String.split(downcased, ~r/\s+/, trim: true) ++ [""]

    trimmed != "" and
      not String.ends_with?(trimmed, "?") and
      not detail_segment?(downcased) and
      first_word in @item_line_verbs
  end

  defp bare_item_segment?(_segment), do: false

  defp detail_segment?(segment) do
    Enum.any?(@detail_segment_prefixes, &String.starts_with?(segment, &1))
  end

  defp infer_parent_goal_title(_draft, []), do: nil

  defp infer_parent_goal_title(draft, goals) do
    task_tokens =
      draft
      |> draft_text()
      |> tokenize_for_linking()

    goals
    |> Enum.map(fn goal ->
      goal_tokens =
        [goal["title"], goal["summary"], goal["details"], goal["success_criteria"]]
        |> Enum.join(" ")
        |> tokenize_for_linking()

      {goal["title"], overlap_score(task_tokens, goal_tokens)}
    end)
    |> choose_parent_goal_title(length(goals))
  end

  defp choose_parent_goal_title([], _goal_count), do: nil

  defp choose_parent_goal_title([{title, score}], 1) when score > 0, do: title

  defp choose_parent_goal_title(scored_goals, _goal_count) do
    case Enum.sort_by(scored_goals, fn {_title, score} -> -score end) do
      [{title, best}, {_other_title, second_best} | _rest] when best > 0 and best > second_best ->
        title

      [{title, best}] when best > 0 ->
        title

      _ ->
        nil
    end
  end

  defp draft_text(draft) do
    [draft["title"], draft["summary"], draft["details"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp tokenize_for_linking(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.map(&normalize_link_token/1)
    |> Enum.reject(&(&1 == "" or &1 in @link_stopwords))
    |> MapSet.new()
  end

  defp tokenize_for_linking(_text), do: MapSet.new()

  defp normalize_link_token(token) do
    if byte_size(token) > 4 and String.ends_with?(token, "s") do
      String.trim_trailing(token, "s")
    else
      token
    end
  end

  defp overlap_score(left_tokens, right_tokens) do
    left_tokens
    |> MapSet.intersection(right_tokens)
    |> MapSet.size()
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp configured_client do
    Application.fetch_env!(:g3, :tracker_model_client)
  end
end
