defmodule G3.Tracker.ModelClient do
  @moduledoc false

  @callback respond(map()) :: {:ok, map()} | {:error, term()}
end
