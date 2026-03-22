defmodule G3.Tracker.ConversationSummary do
  @moduledoc false

  def summarize(conversation, opts \\ []) when is_list(conversation) do
    client = Keyword.get(opts, :client, configured_client())

    request = %{
      system_instruction: """
      You summarize object-origin planning conversations.

      Write a concise 1-2 sentence summary of the conversation.
      Focus on the object being discussed, key constraints, and any dates or priorities.
      Return valid JSON only.
      """,
      contents: build_contents(conversation),
      response_schema: %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["summary"],
        "properties" => %{
          "summary" => %{"type" => "string"}
        }
      }
    }

    with true <- conversation != [],
         {:ok, result} <- call_client(client, request),
         %{"summary" => summary} when is_binary(summary) <- result do
      {:ok, String.trim(summary)}
    else
      false -> {:error, :empty_conversation}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_summary_result}
    end
  end

  defp build_contents(conversation) do
    Enum.map(conversation, fn
      %{"role" => role, "content" => content} ->
        %{"role" => api_role(role), "parts" => [%{"text" => content}]}

      %{role: role, content: content} ->
        %{"role" => api_role(role), "parts" => [%{"text" => content}]}
    end)
  end

  defp api_role("assistant"), do: "model"
  defp api_role(:assistant), do: "model"
  defp api_role(_role), do: "user"

  defp call_client(client, request) when is_function(client, 1), do: client.(request)
  defp call_client(client, request), do: client.respond(request)

  defp configured_client do
    Application.fetch_env!(:g3, :tracker_model_client)
  end
end
