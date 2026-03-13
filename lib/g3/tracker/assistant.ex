defmodule G3.Tracker.Assistant do
  @moduledoc false

  alias G3.Tracker.Prompt
  alias G3.Tracker.Workspace

  def respond(user_message, opts \\ []) when is_binary(user_message) do
    workspace = Keyword.get(opts, :workspace, Workspace)
    client = Keyword.get(opts, :client, configured_client())
    history = Keyword.get(opts, :history, [])
    snapshot = Workspace.snapshot(workspace)

    request = %{
      system_instruction: Prompt.system_instruction(snapshot),
      contents: Prompt.build_contents(history, user_message),
      response_schema: Prompt.response_schema()
    }

    with {:ok, result} <- call_client(client, request),
         {:ok, normalized} <- normalize_result(result),
         {:ok, next_snapshot} <- apply_actions(normalized["actions"], workspace) do
      {:ok,
       %{
         message: normalized["message"],
         needs_follow_up: normalized["needs_follow_up"],
         snapshot: next_snapshot,
         actions: normalized["actions"]
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
       "actions" => Map.get(result, "actions", [])
     }}
  end

  defp normalize_result(_result), do: {:error, :invalid_result_shape}

  defp apply_actions(actions, workspace) when is_list(actions) do
    Enum.reduce_while(actions, {:ok, Workspace.snapshot(workspace)}, fn action,
                                                                        {:ok, _snapshot} ->
      case apply_action(action, workspace) do
        {:ok, snapshot} -> {:cont, {:ok, snapshot}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_actions(_actions, workspace), do: {:ok, Workspace.snapshot(workspace)}

  defp apply_action(%{"tool" => "upsert_draft"} = action, workspace) do
    kind = normalize_kind(Map.get(action, "kind"))
    fields = Map.get(action, "fields", %{}) || %{}
    {:ok, Workspace.upsert_draft(kind, fields, workspace)}
  end

  defp apply_action(%{"tool" => "save_draft"}, workspace) do
    case Workspace.save_draft(workspace) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, {:draft_incomplete, _missing}} -> {:ok, Workspace.snapshot(workspace)}
      {:error, _reason} = error -> error
    end
  end

  defp apply_action(%{"tool" => "clear_draft"}, workspace) do
    {:ok, Workspace.clear_draft(workspace)}
  end

  defp apply_action(_action, workspace), do: {:ok, Workspace.snapshot(workspace)}

  defp normalize_kind(kind) when kind in ["goal", "task"], do: kind
  defp normalize_kind(_kind), do: nil

  defp configured_client do
    Application.fetch_env!(:g3, :tracker_model_client)
  end
end
