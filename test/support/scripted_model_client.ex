defmodule G3.TestSupport.ScriptedModelClient do
  @moduledoc false

  @behaviour G3.Tracker.ModelClient

  @impl true
  def respond(request) do
    script = Application.get_env(:g3, :tracker_model_script)

    case script do
      nil ->
        {:error, :missing_script}

      pid ->
        Agent.get_and_update(pid, fn
          [next | rest] ->
            response =
              case next do
                fun when is_function(fun, 1) -> fun.(request)
                value when is_map(value) -> {:ok, value}
              end

            {response, rest}

          [] ->
            {{:error, :no_scripted_responses}, []}
        end)
    end
  end
end
