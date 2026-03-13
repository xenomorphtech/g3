defmodule G3.AI.LocalConfig do
  @moduledoc false

  def load(path \\ config_path()) do
    with {:ok, encoded} <- File.read(path),
         {:ok, decoded} <- Jason.decode(encoded),
         {:ok, config} <- validate(decoded) do
      {:ok, config}
    else
      {:error, :enoent} -> {:error, {:config_not_found, path}}
      {:error, _reason} = error -> error
      _ -> {:error, {:invalid_config, path}}
    end
  end

  def config_path do
    Application.fetch_env!(:g3, :gemini_config_path)
  end

  defp validate(%{} = decoded) do
    api_key = blank_to_nil(decoded["api_key"])
    model = blank_to_nil(decoded["model"])
    fallback_model = blank_to_nil(decoded["fallback_model"])

    cond do
      is_nil(api_key) -> {:error, {:missing_field, "api_key"}}
      is_nil(model) -> {:error, {:missing_field, "model"}}
      true -> {:ok, %{api_key: api_key, model: model, fallback_model: fallback_model}}
    end
  end

  defp validate(_decoded), do: {:error, :invalid_json_shape}

  defp blank_to_nil(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
