defmodule G3.TestSupport.TrackerEvalCases do
  @moduledoc false

  def prompt_rl_cases do
    [
      binary_ninja_planning_case(),
      half_marathon_goal_case(),
      portfolio_task_linking_case(),
      trace_viewer_task_linking_case()
    ]
  end

  def binary_ninja_planning_case do
    %{
      id: :binary_ninja_planning,
      seed_items: [],
      turns: [
        %{
          user_message: "I want to make a Binary Ninja-like tool for LLMs",
          expected_contents_length: 1,
          prompt_must_include: [
            "Ask a concrete follow-up question",
            "Available app-layer tools",
            "Goals:",
            "Tasks:"
          ],
          scripted_response: %{
            "message" =>
              "What would success look like for that tool, and who would use it first?",
            "needs_follow_up" => true,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "goal",
                "fields" => %{
                  "title" => "Build a Binary Ninja-like tool for LLMs",
                  "summary" => "A Binary Ninja-like inspection tool for LLM workflows"
                }
              }
            ]
          },
          expected: %{
            needs_follow_up: true,
            message_must_include: ["success", "?"],
            action_tools: ["upsert_draft"],
            forbidden_action_tools: ["save_draft"],
            active_draft_kind: "goal",
            active_draft_fields: %{
              "title" => "Build a Binary Ninja-like tool for LLMs",
              "summary" => "A Binary Ninja-like inspection tool for LLM workflows"
            },
            goals_count: 0,
            tasks_count: 0
          }
        },
        %{
          user_message:
            "I want it to help inspect prompts, tool calls, and agent context for agent runs.",
          expected_contents_length: 3,
          prompt_must_include: [
            "Build a Binary Ninja-like tool for LLMs",
            "A Binary Ninja-like inspection tool for LLM workflows"
          ],
          scripted_response: %{
            "message" =>
              "That helps. What would count as a successful first release, and by when?",
            "needs_follow_up" => true,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "goal",
                "fields" => %{
                  "details" => "Inspect prompts, tool calls, and agent context for agent runs"
                }
              }
            ]
          },
          expected: %{
            needs_follow_up: true,
            message_must_include: ["successful first release", "?"],
            action_tools: ["upsert_draft"],
            forbidden_action_tools: ["save_draft"],
            active_draft_kind: "goal",
            active_draft_fields: %{
              "title" => "Build a Binary Ninja-like tool for LLMs",
              "details" => "Inspect prompts, tool calls, and agent context for agent runs"
            },
            goals_count: 0,
            tasks_count: 0
          }
        },
        %{
          user_message:
            "Success means I can load traces, diff prompts between runs, inspect tool calls, and ship an MVP by July 2026.",
          expected_contents_length: 5,
          prompt_must_include: [
            "Inspect prompts, tool calls, and agent context for agent runs",
            "Build a Binary Ninja-like tool for LLMs"
          ],
          scripted_response: %{
            "message" => "Saved that goal and marked it as the current milestone.",
            "needs_follow_up" => false,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "goal",
                "fields" => %{
                  "success_criteria" =>
                    "Load traces, diff prompts between runs, inspect tool calls, and deliver an MVP",
                  "target_date" => "2026-07"
                }
              },
              %{"tool" => "save_draft"}
            ]
          },
          expected: %{
            needs_follow_up: false,
            message_must_include: ["Saved"],
            action_tools: ["upsert_draft", "save_draft"],
            forbidden_action_tools: [],
            active_draft_kind: nil,
            goals_count: 1,
            tasks_count: 0,
            saved_goal_fields: %{
              "title" => "Build a Binary Ninja-like tool for LLMs",
              "success_criteria" =>
                "Load traces, diff prompts between runs, inspect tool calls, and deliver an MVP",
              "target_date" => "2026-07"
            }
          }
        }
      ]
    }
  end

  def half_marathon_goal_case do
    %{
      id: :half_marathon_goal,
      seed_items: [],
      turns: [
        %{
          user_message:
            "I want to run a half marathon in October 2026 and finish in under two hours.",
          expected_contents_length: 1,
          prompt_must_include: [
            "A goal is ready when it has a clear title and measurable success criteria."
          ],
          scripted_response: %{
            "message" => "Saved that goal.",
            "needs_follow_up" => false,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "goal",
                "fields" => %{
                  "title" => "Run a half marathon",
                  "success_criteria" => "Finish a half marathon in under two hours",
                  "target_date" => "2026-10"
                }
              },
              %{"tool" => "save_draft"}
            ]
          },
          expected: %{
            needs_follow_up: false,
            message_must_include: ["Saved"],
            action_tools: ["upsert_draft", "save_draft"],
            forbidden_action_tools: [],
            active_draft_kind: nil,
            goals_count: 1,
            tasks_count: 0,
            saved_goal_fields: %{
              "title" => "Run a half marathon",
              "success_criteria" => "Finish a half marathon in under two hours",
              "target_date" => "2026-10"
            }
          }
        }
      ]
    }
  end

  def portfolio_task_linking_case do
    %{
      id: :portfolio_task_linking,
      seed_items: [
        %{
          kind: "goal",
          fields: %{
            "title" => "Launch portfolio site",
            "success_criteria" => "Portfolio site is live with case studies and a contact form",
            "target_date" => "2026-05"
          }
        }
      ],
      turns: [
        %{
          user_message:
            "Create a task to write the homepage copy by 2026-03-20 for the portfolio launch.",
          expected_contents_length: 1,
          prompt_must_include: [
            "Most tasks should be attached to a parent goal on the graph.",
            "Launch portfolio site"
          ],
          scripted_response: %{
            "message" => "Saved that task under Launch portfolio site.",
            "needs_follow_up" => false,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "task",
                "fields" => %{
                  "title" => "Write homepage copy",
                  "due_date" => "2026-03-20",
                  "priority" => "medium",
                  "parent_goal_title" => "Launch portfolio site"
                }
              },
              %{"tool" => "save_draft"}
            ]
          },
          expected: %{
            needs_follow_up: false,
            message_must_include: ["Launch portfolio site"],
            action_tools: ["upsert_draft", "save_draft"],
            forbidden_action_tools: [],
            active_draft_kind: nil,
            goals_count: 1,
            tasks_count: 1,
            saved_task_fields: %{
              "title" => "Write homepage copy",
              "due_date" => "2026-03-20",
              "priority" => "medium",
              "parent_goal_title" => "Launch portfolio site"
            }
          }
        }
      ]
    }
  end

  def trace_viewer_task_linking_case do
    %{
      id: :trace_viewer_task_linking,
      seed_items: [
        %{
          kind: "goal",
          fields: %{
            "title" => "Build a Binary Ninja-like tool for LLMs",
            "success_criteria" =>
              "Load traces, diff prompts between runs, inspect tool calls, and deliver an MVP",
            "target_date" => "2026-07"
          }
        }
      ],
      turns: [
        %{
          user_message:
            "Create a task to build the trace viewer by 2026-04-15 with high priority.",
          expected_contents_length: 1,
          prompt_must_include: [
            "Most tasks should be attached to a parent goal on the graph.",
            "Build a Binary Ninja-like tool for LLMs"
          ],
          scripted_response: %{
            "message" => "Saved that task under Build a Binary Ninja-like tool for LLMs.",
            "needs_follow_up" => false,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "task",
                "fields" => %{
                  "title" => "Build trace viewer",
                  "due_date" => "2026-04-15",
                  "priority" => "high",
                  "parent_goal_title" => "Build a Binary Ninja-like tool for LLMs"
                }
              },
              %{"tool" => "save_draft"}
            ]
          },
          expected: %{
            needs_follow_up: false,
            message_must_include: ["Build a Binary Ninja-like tool for LLMs"],
            action_tools: ["upsert_draft", "save_draft"],
            forbidden_action_tools: [],
            active_draft_kind: nil,
            goals_count: 1,
            tasks_count: 1,
            saved_task_fields: %{
              "title" => "Build trace viewer",
              "due_date" => "2026-04-15",
              "priority" => "high",
              "parent_goal_title" => "Build a Binary Ninja-like tool for LLMs"
            }
          }
        }
      ]
    }
  end

  def external_goal_follow_up_cases do
    [
      %{
        id: :promotion_goal_seed,
        user_message: "I want to get promoted this year.",
        expected_kind: "goal",
        expected_follow_up: true,
        expected_saved_goals: 0
      },
      %{
        id: :binary_ninja_goal_seed,
        user_message: "I want to make a Binary Ninja-like tool for LLMs",
        expected_kind: "goal",
        expected_follow_up: true,
        expected_saved_goals: 0
      }
    ]
  end
end
