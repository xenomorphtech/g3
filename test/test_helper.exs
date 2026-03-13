external_ai_exclusions =
  if System.get_env("RUN_EXTERNAL_AI_TESTS") == "true" do
    []
  else
    [external_ai: true]
  end

ExUnit.start(exclude: external_ai_exclusions)
