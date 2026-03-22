defmodule G3.TestSupport.PromptVariants.CandidatePrompt do
  @moduledoc false

  alias G3.Tracker.Prompt

  def system_instruction(snapshot, focus_object \\ nil) do
    """
    PROMPT_ARM: candidate
    #{Prompt.system_instruction(snapshot, focus_object)}
    """
  end

  defdelegate build_contents(history, latest_user_message), to: Prompt
  defdelegate response_schema(), to: Prompt
end
