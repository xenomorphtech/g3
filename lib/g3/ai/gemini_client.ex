defmodule G3.AI.GeminiClient do
  @moduledoc false

  @behaviour G3.Tracker.ModelClient

  alias G3.AI.LocalConfig

  @endpoint "https://generativelanguage.googleapis.com/v1beta/models"
  @connect_timeout 15_000
  @receive_timeout 90_000

  @impl true
  def respond(%{
        system_instruction: system_instruction,
        contents: contents,
        response_schema: response_schema
      }) do
    with {:ok, config} <- LocalConfig.load(),
         {:ok, payload} <- generate(config, system_instruction, contents, response_schema) do
      decode_payload(payload)
    end
  end

  defp generate(config, system_instruction, contents, response_schema) do
    request_body = %{
      "systemInstruction" => %{"parts" => [%{"text" => system_instruction}]},
      "contents" => contents,
      "generationConfig" => %{
        "temperature" => 0.1,
        "responseMimeType" => "application/json",
        "responseJsonSchema" => response_schema
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
        url: "#{@endpoint}/#{model}:generateContent",
        headers: [{"x-goog-api-key", api_key}],
        json: request_body,
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
          {:error, {:gemini_request_failed, status, response_body}}
        end

      {:ok, %{status: status, body: response_body}} ->
        {:error, {:gemini_request_failed, status, response_body}}

      {:error, reason} ->
        {:error, {:gemini_transport_error, reason}}
    end
  end

  defp candidate_models(config) do
    [config.model, config.fallback_model]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_text(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]}) do
    case Enum.find(parts, &Map.has_key?(&1, "text")) do
      %{"text" => text} -> {:ok, text}
      _ -> {:error, :missing_text_candidate}
    end
  end

  defp extract_text(body), do: {:error, {:unexpected_response_shape, body}}

  defp decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :invalid_structured_output}
      {:error, reason} -> {:error, {:invalid_json_payload, reason, payload}}
    end
  end

  defp missing_model?(%{"error" => %{"message" => message}}) when is_binary(message) do
    normalized = String.downcase(message)
    String.contains?(normalized, "model") and String.contains?(normalized, "not found")
  end

  defp missing_model?(_body), do: false
end
