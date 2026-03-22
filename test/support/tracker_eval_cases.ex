defmodule G3.TestSupport.TrackerEvalCases do
  @moduledoc false

  def prompt_rl_cases do
    [
      binary_ninja_planning_case(),
      rename_active_goal_case(),
      half_marathon_goal_case(),
      portfolio_task_linking_case(),
      trace_viewer_task_linking_case(),
      focused_multi_task_add_case(),
      focused_fact_save_case(),
      multiple_goals_split_case(),
      multiline_goals_under_emitted_actions_case(),
      new_goal_starts_new_object_case(),
      ambiguous_launch_task_resolution_case(),
      passport_standalone_task_case(),
      abandoned_goal_draft_case()
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
            goals_count: 1,
            tasks_count: 0
          }
        },
        %{
          user_message:
            "I want it to help inspect prompts, tool calls, and agent context for agent runs.",
          expected_contents_length: 3,
          prompt_must_include: [
            "Build a Binary Ninja-like tool for LLMs",
            "A Binary Ninja-like inspection tool for LLM workflows",
            "Do not ask for a target date just because a goal is missing one."
          ],
          scripted_response: %{
            "message" => "That helps. What would count as a successful first release?",
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
            message_must_not_include: ["by when", "target date"],
            action_tools: ["upsert_draft"],
            forbidden_action_tools: ["save_draft"],
            active_draft_kind: "goal",
            active_draft_fields: %{
              "title" => "Build a Binary Ninja-like tool for LLMs",
              "details" => "Inspect prompts, tool calls, and agent context for agent runs"
            },
            goals_count: 1,
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

  def rename_active_goal_case do
    %{
      id: :rename_active_goal,
      seed_items: [],
      turns: [
        %{
          user_message: "I want to build an LLM reverse engineering studio",
          expected_contents_length: 1,
          prompt_must_include: [
            "materialize it into the graph with `upsert_draft` or `start_new_draft`",
            "If the user is refining the current draft and changes its name"
          ],
          scripted_response: %{
            "message" => "What would success look like for that project?",
            "needs_follow_up" => true,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "goal",
                "fields" => %{
                  "title" => "Build an LLM reverse engineering studio"
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
              "title" => "Build an LLM reverse engineering studio"
            },
            goals_count: 1,
            tasks_count: 0
          }
        },
        %{
          user_message: "The project will be called Flux.",
          expected_contents_length: 3,
          prompt_must_include: [
            "Build an LLM reverse engineering studio",
            "Do not start a new draft just because the title changed."
          ],
          scripted_response: %{
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
          },
          expected: %{
            needs_follow_up: true,
            message_must_include: ["updated the title", "Flux", "?"],
            action_tools: ["upsert_draft"],
            forbidden_action_tools: ["start_new_draft", "save_draft"],
            active_draft_kind: "goal",
            active_draft_fields: %{
              "title" => "Flux"
            },
            goals_count: 1,
            tasks_count: 0,
            goal_titles: ["Flux"]
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

  def focused_multi_task_add_case do
    %{
      id: :focused_multi_task_add,
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
          expected_contents_length: 1,
          prompt_must_include: [
            "Focused object:",
            "Build a Thai language learning app",
            "Most tasks should be attached to a parent goal on the graph.",
            "split them into separate objects",
            "emit task actions, not goal actions"
          ],
          scripted_response: %{
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
          },
          expected: %{
            needs_follow_up: false,
            message_must_include: ["two tasks", "Thai language learning app"],
            action_tools: ["upsert_draft", "save_draft", "start_new_draft", "save_draft"],
            forbidden_action_tools: [],
            active_draft_kind: nil,
            goals_count: 1,
            tasks_count: 2,
            task_titles: ["Implement native voice playback", "Add speech recognition input"]
          }
        }
      ]
    }
  end

  def focused_fact_save_case do
    %{
      id: :focused_fact_save,
      seed_items: [
        %{
          kind: "goal",
          fields: %{
            "title" => "Build a Binary Ninja-like tool for LLMs",
            "success_criteria" => "Can inspect traces, prompts, and tool calls"
          }
        }
      ],
      turns: [
        %{
          user_message: "Fact: it must run entirely on the BEAM first.",
          focus_object: %{
            "kind" => "goal",
            "title" => "Build a Binary Ninja-like tool for LLMs",
            "status" => "draft"
          },
          expected_contents_length: 1,
          prompt_must_include: [
            "Focused object:",
            "Build a Binary Ninja-like tool for LLMs",
            "Saved facts live in the facts store",
            "If a project goal is currently focused in the UI and the user states a fact"
          ],
          scripted_response: %{
            "message" => "Saved that as a fact for the project.",
            "needs_follow_up" => false,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "fact",
                "fields" => %{
                  "title" => "Run entirely on the BEAM first",
                  "details" => "It must run entirely on the BEAM first."
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
            facts_count: 1,
            saved_fact_fields: %{
              "title" => "Run entirely on the BEAM first",
              "project_title" => "Build a Binary Ninja-like tool for LLMs"
            }
          }
        }
      ]
    }
  end

  def multiple_goals_split_case do
    %{
      id: :multiple_goals_split,
      seed_items: [],
      turns: [
        %{
          user_message:
            "I want to launch my portfolio site by June and run a half marathon in October 2026.",
          expected_contents_length: 1,
          prompt_must_include: [
            "split them into separate objects",
            "start a new object instead of mutating the previous one"
          ],
          scripted_response: %{
            "message" =>
              "I split that into two goals. I saved the portfolio goal and started a half marathon goal draft so we can add success criteria.",
            "needs_follow_up" => true,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "goal",
                "fields" => %{
                  "title" => "Launch portfolio site",
                  "success_criteria" => "Portfolio site is live by June 2026",
                  "target_date" => "2026-06"
                }
              },
              %{"tool" => "save_draft"},
              %{
                "tool" => "upsert_draft",
                "kind" => "goal",
                "fields" => %{
                  "title" => "Run a half marathon",
                  "target_date" => "2026-10"
                }
              }
            ]
          },
          expected: %{
            needs_follow_up: true,
            message_must_include: ["split", "two goals"],
            action_tools: ["upsert_draft", "save_draft", "upsert_draft"],
            forbidden_action_tools: [],
            active_draft_kind: "goal",
            active_draft_fields: %{
              "title" => "Run a half marathon",
              "target_date" => "2026-10"
            },
            goals_count: 2,
            tasks_count: 0,
            goal_titles: ["Launch portfolio site", "Run a half marathon"]
          }
        }
      ]
    }
  end

  def new_goal_starts_new_object_case do
    %{
      id: :new_goal_starts_new_object,
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
          user_message: "I also want to learn Rust this quarter.",
          expected_contents_length: 1,
          prompt_must_include: [
            "Launch portfolio site",
            "start a new object instead of mutating the previous one"
          ],
          scripted_response: %{
            "message" =>
              "Started a new goal draft for learning Rust. What would success look like by the end of the quarter?",
            "needs_follow_up" => true,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "goal",
                "fields" => %{
                  "title" => "Learn Rust this quarter"
                }
              }
            ]
          },
          expected: %{
            needs_follow_up: true,
            message_must_include: ["new goal draft", "?"],
            action_tools: ["upsert_draft"],
            forbidden_action_tools: ["save_draft"],
            active_draft_kind: "goal",
            active_draft_fields: %{
              "title" => "Learn Rust this quarter"
            },
            goals_count: 2,
            tasks_count: 0,
            goal_titles: ["Launch portfolio site", "Learn Rust this quarter"]
          }
        }
      ]
    }
  end

  def multiline_goals_under_emitted_actions_case do
    %{
      id: :multiline_goals_under_emitted_actions,
      seed_items: [],
      turns: [
        %{
          user_message:
            "build a binary ninja like reverse engineering tool for llms\nbuild a beam vm currency like kernel",
          expected_contents_length: 1,
          prompt_must_include: [
            "separate lines or bullets",
            "Do not ask for both goals at once, and do not ask for target dates.",
            "Do not ask the user to answer for multiple incomplete goals in a single reply.",
            "Avoid plural follow-up phrasing like \"both goals\", \"for each\", or \"for both\""
          ],
          scripted_response: %{
            "message" =>
              "I've started a new draft for the BEAM VM currency-like kernel. What would success look like for it?",
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
          },
          expected: %{
            needs_follow_up: true,
            message_must_include: ["success", "BEAM", "?"],
            message_must_not_include: ["target date", "for each", "both goals"],
            action_tools: ["upsert_draft"],
            forbidden_action_tools: ["save_draft"],
            active_draft_kind: "goal",
            active_draft_fields: %{
              "title" => "Build a beam vm currency like kernel"
            },
            goals_count: 2,
            tasks_count: 0,
            goal_titles: [
              "Build a Binary Ninja-like reverse engineering tool for LLMs",
              "Build a beam vm currency like kernel"
            ]
          }
        }
      ]
    }
  end

  def ambiguous_launch_task_resolution_case do
    %{
      id: :ambiguous_launch_task_resolution,
      seed_items: [
        %{
          kind: "goal",
          fields: %{
            "title" => "Launch portfolio site",
            "success_criteria" =>
              "Portfolio site launches successfully with the main page approved",
            "target_date" => "2026-05"
          }
        },
        %{
          kind: "goal",
          fields: %{
            "title" => "Launch newsletter",
            "success_criteria" =>
              "Newsletter launches successfully with the first three issues scheduled",
            "target_date" => "2026-04"
          }
        }
      ],
      turns: [
        %{
          user_message: "Create a task to write the launch copy by 2026-03-22.",
          expected_contents_length: 1,
          prompt_must_include: [
            "Launch portfolio site",
            "Launch newsletter",
            "If a task seems to support a goal but the parent is unclear, ask which goal it belongs to instead of guessing."
          ],
          scripted_response: %{
            "message" =>
              "Which goal should this task belong to: Launch portfolio site or Launch newsletter?",
            "needs_follow_up" => true,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "task",
                "fields" => %{
                  "title" => "Write launch copy",
                  "due_date" => "2026-03-22"
                }
              }
            ]
          },
          expected: %{
            needs_follow_up: true,
            message_must_include: ["Which goal", "?"],
            action_tools: ["upsert_draft"],
            forbidden_action_tools: ["save_draft"],
            active_draft_kind: "task",
            active_draft_fields: %{
              "title" => "Write launch copy",
              "due_date" => "2026-03-22"
            },
            goals_count: 2,
            tasks_count: 1
          }
        },
        %{
          user_message: "It belongs to the portfolio site goal.",
          expected_contents_length: 3,
          prompt_must_include: [
            "Write launch copy",
            "Launch portfolio site",
            "Launch newsletter"
          ],
          scripted_response: %{
            "message" => "Saved that task under Launch portfolio site.",
            "needs_follow_up" => false,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "task",
                "fields" => %{
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
            goals_count: 2,
            tasks_count: 1,
            saved_task_fields: %{
              "title" => "Write launch copy",
              "due_date" => "2026-03-22",
              "parent_goal_title" => "Launch portfolio site"
            }
          }
        }
      ]
    }
  end

  def passport_standalone_task_case do
    %{
      id: :passport_standalone_task,
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
          user_message: "Create a task to renew my passport by 2026-04-01.",
          expected_contents_length: 1,
          prompt_must_include: [
            "Standalone chores are fine when no meaningful parent goal exists.",
            "Launch portfolio site"
          ],
          scripted_response: %{
            "message" => "Saved that standalone task.",
            "needs_follow_up" => false,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "task",
                "fields" => %{
                  "title" => "Renew passport",
                  "due_date" => "2026-04-01"
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
            tasks_count: 1,
            saved_task_fields: %{
              "title" => "Renew passport",
              "due_date" => "2026-04-01",
              "parent_goal_title" => nil
            }
          }
        }
      ]
    }
  end

  def abandoned_goal_draft_case do
    %{
      id: :abandoned_goal_draft,
      seed_items: [],
      turns: [
        %{
          user_message: "I want to learn Rust this quarter.",
          expected_contents_length: 1,
          prompt_must_include: [
            "Maintain a single active draft object across turns.",
            "clear_draft: remove the active draft when the user abandons it."
          ],
          scripted_response: %{
            "message" => "What would count as success for learning Rust this quarter?",
            "needs_follow_up" => true,
            "actions" => [
              %{
                "tool" => "upsert_draft",
                "kind" => "goal",
                "fields" => %{
                  "title" => "Learn Rust"
                }
              }
            ]
          },
          expected: %{
            needs_follow_up: true,
            message_must_include: ["success", "?"],
            action_tools: ["upsert_draft"],
            forbidden_action_tools: ["save_draft", "clear_draft"],
            active_draft_kind: "goal",
            active_draft_fields: %{
              "title" => "Learn Rust"
            },
            goals_count: 1,
            tasks_count: 0
          }
        },
        %{
          user_message: "Actually never mind, drop that.",
          expected_contents_length: 3,
          prompt_must_include: [
            "Learn Rust",
            "clear_draft: remove the active draft when the user abandons it."
          ],
          scripted_response: %{
            "message" => "Cleared that draft.",
            "needs_follow_up" => false,
            "actions" => [
              %{"tool" => "clear_draft"}
            ]
          },
          expected: %{
            needs_follow_up: false,
            message_must_include: ["Cleared"],
            action_tools: ["clear_draft"],
            forbidden_action_tools: ["save_draft", "upsert_draft"],
            active_draft_kind: nil,
            goals_count: 0,
            tasks_count: 0
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
        expected_title_contains: "promoted",
        expected_kind: "goal",
        expected_follow_up: true,
        expected_saved_goals: 0,
        message_must_not_include: ["target date", "deadline", "by when"]
      },
      %{
        id: :binary_ninja_goal_seed,
        user_message: "I want to make a Binary Ninja-like tool for LLMs",
        expected_title_contains: "Binary Ninja-like tool for LLMs",
        expected_kind: "goal",
        expected_follow_up: true,
        expected_saved_goals: 0,
        message_must_not_include: ["target date", "deadline", "by when"]
      }
    ]
  end

  def external_goal_save_cases do
    [
      %{
        id: :half_marathon_goal_external_save,
        user_message:
          "I want to run a half marathon in October 2026 and finish in under two hours.",
        expected_title_contains: "half marathon",
        expected_target_date_prefix: "2026-10"
      }
    ]
  end

  def external_task_linking_cases do
    [
      %{
        id: :portfolio_task_external_linking,
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
        user_message:
          "Create a task to write the homepage copy by 2026-03-20 for the portfolio launch.",
        expected_parent_goal_title: "Launch portfolio site",
        expected_goals_count: 1
      },
      %{
        id: :trace_viewer_task_external_linking,
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
        user_message: "Create a task to build the trace viewer by 2026-04-15 with high priority.",
        expected_parent_goal_title: "Build a Binary Ninja-like tool for LLMs",
        expected_goals_count: 1
      }
    ]
  end

  def external_focused_multi_task_cases do
    [
      %{
        id: :focused_thai_app_multi_task_external,
        seed_items: [
          %{
            kind: "goal",
            fields: %{
              "title" => "Build a Thai language learning app",
              "success_criteria" => "Users can practice listening and speaking Thai every day"
            }
          }
        ],
        focus_object: %{
          "kind" => "goal",
          "title" => "Build a Thai language learning app",
          "status" => "draft"
        },
        user_message:
          "add task, use the native voices to be listened, and allow the user to say them",
        expected_goals_count: 1,
        expected_task_count: 2,
        expected_task_title_tokens: [
          ["voice"],
          ["speech"]
        ],
        forbidden_goal_titles: ["Add task"]
      }
    ]
  end

  def external_fact_save_cases do
    [
      %{
        id: :focused_project_fact_external_save,
        seed_items: [
          %{
            kind: "goal",
            fields: %{
              "title" => "Build a Binary Ninja-like tool for LLMs",
              "success_criteria" =>
                "Load traces, diff prompts between runs, inspect tool calls, and deliver an MVP"
            }
          }
        ],
        focus_object: %{
          "kind" => "goal",
          "title" => "Build a Binary Ninja-like tool for LLMs",
          "status" => "draft"
        },
        user_message: "Fact: it must run entirely on the BEAM first.",
        expected_title_contains: "beam",
        expected_project_title: "Build a Binary Ninja-like tool for LLMs",
        expected_goals_count: 1
      }
    ]
  end

  def external_fact_search_cases do
    [
      %{
        id: :bm25_fact_search_external,
        seed_items: [
          %{
            kind: "fact",
            fields: %{
              "title" => "Launch copy needs legal approval",
              "details" =>
                "Initial launch messaging must be approved by legal before publishing.",
              "project_title" => "Launch portfolio site"
            }
          }
        ],
        user_message: "What facts do we have about legal approval for launches?",
        expected_tool: "search_facts_bm25",
        message_must_include: ["legal", "launch"],
        message_must_not_include: ["no facts", "not sure"]
      },
      %{
        id: :grep_fact_search_external,
        seed_items: [
          %{
            kind: "fact",
            fields: %{
              "title" => "Debugger runs on the BEAM first",
              "details" =>
                "The first debugger milestone should stay entirely on the BEAM runtime.",
              "project_title" => "Build debugger"
            }
          }
        ],
        user_message: "Search facts for /BEAM first/",
        expected_tool: "search_facts_grep",
        message_must_include: ["BEAM", "debugger"],
        message_must_not_include: ["no facts", "not sure"]
      }
    ]
  end

  def external_ambiguous_task_cases do
    [
      %{
        id: :ambiguous_launch_task_external_follow_up,
        seed_items: [
          %{
            kind: "goal",
            fields: %{
              "title" => "Launch portfolio site",
              "success_criteria" =>
                "Portfolio site launches successfully with the main page approved",
              "target_date" => "2026-05"
            }
          },
          %{
            kind: "goal",
            fields: %{
              "title" => "Launch newsletter",
              "success_criteria" =>
                "Newsletter launches successfully with the first three issues scheduled",
              "target_date" => "2026-04"
            }
          }
        ],
        user_message: "Create a task to write the launch copy by 2026-03-22.",
        expected_title_contains: "launch copy",
        expected_goals_count: 2
      }
    ]
  end

  def external_standalone_task_cases do
    [
      %{
        id: :passport_task_external_save,
        user_message: "Create a task to renew my passport by 2026-04-01.",
        expected_title_contains: "passport",
        expected_due_date: "2026-04-01"
      }
    ]
  end

  def external_multiturn_goal_cases do
    [
      %{
        id: :binary_ninja_multiturn_refinement,
        first_user_message: "I want to make a Binary Ninja-like tool for LLMs",
        second_user_message:
          "Success means I can load traces, diff prompts between runs, inspect tool calls, and ship an MVP by July 2026.",
        expected_goal_title_contains: "Binary Ninja-like tool for LLMs",
        expected_target_date_prefix: "2026-07"
      }
    ]
  end

  def external_multiline_goal_cases do
    [
      %{
        id: :multiline_goal_split_external,
        user_message:
          "build a binary ninja like reverse engineering tool for llms\nbuild a beam vm currency like kernel",
        message_must_include: ["success", "?"],
        message_must_not_include: ["target date", "for each", "for both", "both goals"],
        message_focus_token_groups: [
          ["binary", "ninja"],
          ["beam", "currency"]
        ],
        expected_title_tokens: [
          ["binary", "ninja"],
          ["beam", "currency"]
        ]
      }
    ]
  end
end
