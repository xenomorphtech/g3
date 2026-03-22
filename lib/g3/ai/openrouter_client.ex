defmodule G3.AI.OpenRouterClient do
  @moduledoc false

  @behaviour G3.Tracker.ModelClient

  alias G3.AI.LocalConfig

  @endpoint "https://openrouter.ai/api/v1/chat/completions"
  @connect_timeout 15_000
  @receive_timeout 90_000

  @impl true
  def respond(%{
        system_instruction: system_instruction,
        contents: contents,
        response_schema: response_schema
      }) do
    with {:ok, config} <- LocalConfig.load(config_path()),
         {:ok, payload} <- generate(config, system_instruction, contents, response_schema) do
      decode_payload(payload)
    end
  end

  defp generate(config, system_instruction, contents, response_schema) do
    request_body = %{
      "messages" => build_messages(system_instruction, contents),
      "temperature" => 0.1,
      "response_format" => %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "g3_response",
          "strict" => true,
          "schema" => response_schema
        }
      }
    }

    config
    |> candidate_models()
    |> attempt_models(request_body, config.api_key)
  end

  defp attempt_models([], _request_body, _api_key), do: {:error, :no_model_candidates}

  defp attempt_models([model | rest], request_body, api_key) do
    response =
      Req.post(
        url: @endpoint,
        headers: request_headers(api_key),
        json: Map.put(request_body, "model", model),
        connect_options: [timeout: @connect_timeout],
        receive_timeout: @receive_timeout
      )

    case response do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        extract_text(response_body)

      {:ok, %{status: status, body: response_body}} when status in [400, 404] and rest != [] ->
        if missing_model?(response_body) do
          attempt_models(rest, request_body, api_key)
        else
          {:error, {:openrouter_request_failed, status, response_body}}
        end

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:openrouter_request_failed, status, response_body}}

      {:error, reason} ->
        {:error, {:openrouter_transport_error, reason}}
    end
  end

  defp build_messages(system_instruction, contents) do
    [%{"role" => "system", "content" => system_instruction}] ++
      Enum.map(contents, &build_message/1)
  end

  defp build_message(%{"role" => role, "parts" => parts}) do
    %{
      "role" => openrouter_role(role),
      "content" => parts_text(parts)
    }
  end

  defp build_message(%{role: role, parts: parts}) do
    %{
      "role" => openrouter_role(role),
      "content" => parts_text(parts)
    }
  end

  defp build_message(%{"role" => role, "content" => content}) do
    %{
      "role" => openrouter_role(role),
      "content" => to_string(content)
    }
  end

  defp build_message(%{role: role, content: content}) do
    %{
      "role" => openrouter_role(role),
      "content" => to_string(content)
    }
  end

  defp build_message(message), do: %{"role" => "user", "content" => inspect(message)}

  defp parts_text(parts) when is_list(parts) do
    parts
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{text: text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _part -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp parts_text(_parts), do: ""

  defp openrouter_role("model"), do: "assistant"
  defp openrouter_role(:model), do: "assistant"
  defp openrouter_role("assistant"), do: "assistant"
  defp openrouter_role(:assistant), do: "assistant"
  defp openrouter_role("system"), do: "system"
  defp openrouter_role(:system), do: "system"
  defp openrouter_role(_role), do: "user"

  defp request_headers(api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"http-referer", "http://localhost:4000"},
      {"x-title", "G3"}
    ]
  end

  defp candidate_models(config) do
    [config.model, config.fallback_model]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    {:ok, content}
  end

  defp extract_text(%{
         "choices" => [%{"message" => %{"content" => nil, "reasoning" => reasoning}} | _]
       })
       when is_binary(reasoning) do
    {:ok, reasoning}
  end

  defp extract_text(%{"choices" => [%{"message" => %{"content" => parts}} | _]})
       when is_list(parts) do
    text =
      parts
      |> Enum.map(fn
        %{"text" => value} when is_binary(value) -> value
        %{"type" => "text", "text" => value} when is_binary(value) -> value
        _part -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    if text == "", do: {:error, :missing_text_candidate}, else: {:ok, text}
  end

  defp extract_text(body), do: {:error, {:unexpected_response_shape, body}}

  defp decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :invalid_structured_output}
      {:error, _reason} -> decode_fenced_payload(payload)
    end
  end

  defp decode_fenced_payload(payload) do
    payload
    |> strip_code_fence()
    |> Jason.decode()
    |> case do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :invalid_structured_output}
      {:error, reason} -> {:error, {:invalid_json_payload, reason, payload}}
    end
  end

  defp strip_code_fence(payload) do
    payload
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*/u, "")
    |> String.replace(~r/\s*```$/u, "")
    |> String.trim()
  end

  defp missing_model?(%{"error" => %{"message" => message}}) when is_binary(message) do
    normalized = String.downcase(message)

    (String.contains?(normalized, "model") and String.contains?(normalized, "not found")) or
      String.contains?(normalized, "invalid model")
  end

  defp missing_model?(_body), do: false

  defp config_path do
    Application.fetch_env!(:g3, :openrouter_config_path)
  end
end
