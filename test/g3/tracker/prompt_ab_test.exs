defmodule G3.Tracker.PromptABTest do
  use ExUnit.Case, async: false

  alias G3.TestSupport.PromptEval
  alias G3.TestSupport.PromptVariants.BaselinePrompt
  alias G3.TestSupport.PromptVariants.CandidatePrompt

  test "run_ab compares baseline and candidate prompt behavior on the same eval case" do
    eval_cases = [
      %{
        id: :single_focus_multiline_goals,
        seed_items: [],
        turns: [
          %{
            user_message:
              "build a binary ninja like reverse engineering tool for llms\nbuild a beam vm currency like kernel",
            expected: %{
              needs_follow_up: true,
              goals_count: 2,
              tasks_count: 0,
              active_draft_kind: "goal",
              goal_titles: [
                "Build a Binary Ninja-like reverse engineering tool for LLMs",
                "Build a beam vm currency like kernel"
              ],
              message_must_include: ["BEAM", "?"],
              message_must_not_include: ["both goals", "target dates"]
            }
          }
        ]
      },
      %{
        id: :rename_current_project,
        seed_items: [],
        seed_drafts: [
          %{
            kind: "goal",
            fields: %{
              "title" => "Build an LLM reverse engineering studio"
            }
          }
        ],
        turns: [
          %{
            user_message: "project will be called flux",
            expected: %{
              needs_follow_up: true,
              goals_count: 1,
              tasks_count: 0,
              active_draft_kind: "goal",
              active_title_contains: "Flux",
              message_must_include: ["Flux", "?"],
              message_must_not_include: ["new goal"]
            }
          }
        ]
      },
      %{
        id: :focused_multi_task_under_goal,
        seed_items: [
          %{
            kind: "goal",
            fields: %{
              "title" => "Build a Thai language learning app",
              "success_criteria" => "Users can practice listening and speaking Thai every day"
            }
          }
        ],
        turns: [
          %{
            user_message:
              "add task, use the native voices to be listened, and allow the user to say them",
            focus_object: %{
              "kind" => "goal",
              "title" => "Build a Thai language learning app",
              "status" => "draft"
            },
            expected: %{
              needs_follow_up: false,
              goals_count: 1,
              tasks_count: 2,
              active_draft_kind: nil,
              task_titles: ["Implement native voice playback", "Add speech recognition input"],
              message_must_include: ["tasks", "Thai language learning app"],
              message_must_not_include: ["new goal"]
            }
          }
        ]
      }
    ]

    client = fn request ->
      latest_message = request.contents |> List.last() |> get_in(["parts", Access.at(0), "text"])
      candidate? = String.contains?(request.system_instruction, "PROMPT_ARM: candidate")

      response =
        case {latest_message, candidate?} do
          {"project will be called flux", true} ->
            %{
              "message" =>
                "I've updated the title to Flux. To finalize this goal, what would success look like for this project?",
              "needs_follow_up" => true,
              "actions" => [
                %{
                  "tool" => "upsert_draft",
                  "kind" => "goal",
                  "fields" => %{"title" => "Flux"}
                }
              ]
            }

          {"project will be called flux", false} ->
            %{
              "message" =>
                "I've started a new goal called Flux. What would success look like for it?",
              "needs_follow_up" => true,
              "actions" => [
                %{
                  "tool" => "start_new_draft",
                  "kind" => "goal",
                  "fields" => %{"title" => "Flux"}
                }
              ]
            }

          {"add task, use the native voices to be listened, and allow the user to say them", true} ->
            %{
              "message" => "I added two tasks under Build a Thai language learning app.",
              "needs_follow_up" => false,
              "actions" => [
                %{
                  "tool" => "upsert_draft",
                  "kind" => "task",
                  "fields" => %{
                    "title" => "Implement native voice playback",
                    "parent_goal_title" => "Build a Thai language learning app"
                  }
                },
                %{"tool" => "save_draft"},
                %{
                  "tool" => "start_new_draft",
                  "kind" => "task",
                  "fields" => %{
                    "title" => "Add speech recognition input",
                    "parent_goal_title" => "Build a Thai language learning app"
                  }
                },
                %{"tool" => "save_draft"}
              ]
            }

          {"add task, use the native voices to be listened, and allow the user to say them",
           false} ->
            %{
              "message" =>
                "I've started a new goal for that work. What would success look like for it?",
              "needs_follow_up" => true,
              "actions" => [
                %{
                  "tool" => "start_new_draft",
                  "kind" => "goal",
                  "fields" => %{"title" => "Add task"}
                }
              ]
            }

          {_, true} ->
            %{
              "message" =>
                "I've started both goals. What would success look like for the BEAM VM currency-like kernel?",
              "needs_follow_up" => true,
              "actions" => [
                %{
                  "tool" => "upsert_draft",
                  "kind" => "goal",
                  "fields" => %{
                    "title" => "Build a Binary Ninja-like reverse engineering tool for LLMs"
                  }
                }
              ]
            }

          _ ->
            %{
              "message" =>
                "I've started both goals. What would success look like for both goals, and what target dates do you have?",
              "needs_follow_up" => true,
              "actions" => [
                %{
                  "tool" => "upsert_draft",
                  "kind" => "goal",
                  "fields" => %{
                    "title" => "Build a Binary Ninja-like reverse engineering tool for LLMs"
                  }
                }
              ]
            }
        end

      {:ok, response}
    end

    report =
      PromptEval.run_ab(
        eval_cases,
        baseline: [
          client: client,
          prompt_module: BaselinePrompt,
          workspace_prefix: "prompt-ab-baseline"
        ],
        candidate: [
          client: client,
          prompt_module: CandidatePrompt,
          workspace_prefix: "prompt-ab-candidate"
        ]
      )

    assert report.baseline.summary.cases_total == 3
    assert report.candidate.summary.cases_total == 3
    assert report.comparison.improved_case_count == 3
    assert report.comparison.regressed_case_count == 0

    assert Enum.any?(report.comparison.cases, fn comparison_case ->
             comparison_case.id == :single_focus_multiline_goals and
               comparison_case.candidate_score > comparison_case.baseline_score
           end)

    assert Enum.any?(report.comparison.cases, fn comparison_case ->
             comparison_case.id == :rename_current_project and
               comparison_case.candidate_score > comparison_case.baseline_score
           end)

    assert Enum.any?(report.comparison.cases, fn comparison_case ->
             comparison_case.id == :focused_multi_task_under_goal and
               comparison_case.candidate_score > comparison_case.baseline_score
           end)
  end
end
