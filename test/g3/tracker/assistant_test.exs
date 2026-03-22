defmodule G3.Tracker.AssistantTest do
  use ExUnit.Case, async: false

  alias G3.Tracker.Assistant
  alias G3.Tracker.Workspace

  test "stores a partial goal draft and asks a follow-up question" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    client = fn request ->
      assert request.system_instruction =~ "Ask a concrete follow-up question"

      {:ok,
       %{
         "message" => "What would success look like for that goal?",
         "needs_follow_up" => true,
         "actions" => [
           %{
             "tool" => "upsert_draft",
             "kind" => "goal",
             "fields" => %{"title" => "Get in better shape"}
           }
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond("I want to get in better shape",
               workspace: workspace,
               client: client
             )

    assert result.needs_follow_up
    assert result.snapshot["active_draft"]["kind"] == "goal"
    assert result.snapshot["active_draft"]["title"] == "Get in better shape"

    assert [%{"status" => "being_drafted", "title" => "Get in better shape"}] =
             result.snapshot["goals"]
  end

  test "materializes a goal draft even when the model omits usable draft fields" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    client = fn _request ->
      {:ok,
       %{
         "message" => "What would success look like for that tool?",
         "needs_follow_up" => true,
         "actions" => [%{"tool" => "upsert_draft"}]
       }}
    end

    assert {:ok, result} =
             Assistant.respond("I want to make a Binary Ninja-like tool for LLMs",
               workspace: workspace,
               client: client
             )

    assert result.needs_follow_up == true
    assert result.snapshot["active_draft"]["kind"] == "goal"

    assert String.contains?(
             result.snapshot["active_draft"]["title"],
             "Binary Ninja-like tool for LLMs"
           )
  end

  test "saves a task when the model returns save actions" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    client = fn request ->
      assert request.system_instruction =~ "Tasks:"

      {:ok,
       %{
         "message" => "Saved that as a task.",
         "needs_follow_up" => false,
         "actions" => [
           %{
             "tool" => "upsert_draft",
             "kind" => "task",
             "fields" => %{
               "title" => "Send the Q2 planning deck",
               "due_date" => "2026-03-14",
               "priority" => "high"
             }
           },
           %{"tool" => "save_draft"}
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "Create a task to send the Q2 planning deck tomorrow",
               workspace: workspace,
               client: client
             )

    assert result.needs_follow_up == false
    assert result.snapshot["active_draft"] == nil

    assert [%{"title" => "Send the Q2 planning deck", "priority" => "high"}] =
             result.snapshot["tasks"]
  end

  test "saves a fact and links it to the focused project goal" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Build a Binary Ninja-like tool for LLMs",
        "success_criteria" => "Can inspect traces, prompts, and tool calls"
      },
      workspace
    )

    assert {:ok, _snapshot} = Workspace.save_draft(workspace)

    client = fn request ->
      assert request.system_instruction =~ "Facts:"
      assert request.system_instruction =~ "Focused object:"
      assert request.system_instruction =~ "Build a Binary Ninja-like tool for LLMs"

      {:ok,
       %{
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
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "Fact: it must run entirely on the BEAM first.",
               workspace: workspace,
               client: client,
               focus_object: %{
                 "kind" => "goal",
                 "title" => "Build a Binary Ninja-like tool for LLMs",
                 "status" => "draft"
               }
             )

    assert result.needs_follow_up == false
    assert result.snapshot["active_draft"] == nil

    assert [
             %{
               "title" => "Run entirely on the BEAM first",
               "project_title" => "Build a Binary Ninja-like tool for LLMs"
             }
           ] = result.snapshot["facts"]
  end

  test "coalesces fragmented draft actions and still saves the goal" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Build a Binary Ninja-like tool for LLMs"
      },
      workspace
    )

    client = fn _request ->
      {:ok,
       %{
         "message" => "Great, I've saved that goal. What's the first step you'd like to take?",
         "needs_follow_up" => true,
         "actions" => [
           %{"tool" => "upsert_draft"},
           %{"tool" => "upsert_draft", "kind" => "goal"},
           %{
             "tool" => "upsert_draft",
             "fields" => %{
               "success_criteria" =>
                 "Load traces, diff prompts between runs, inspect tool calls, and ship an MVP by July 2026.",
               "target_date" => "2026-07"
             }
           },
           %{"tool" => "save_draft"}
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "Success means I can load traces, diff prompts between runs, inspect tool calls, and ship an MVP by July 2026.",
               workspace: workspace,
               client: client,
               history: [
                 %{role: "user", content: "I want to make a Binary Ninja-like tool for LLMs"},
                 %{role: "assistant", content: "What would success look like for this tool?"}
               ]
             )

    assert result.needs_follow_up == false
    assert result.snapshot["active_draft"] == nil

    assert [
             %{
               "title" => "Build a Binary Ninja-like tool for LLMs",
               "target_date" => "2026-07",
               "success_criteria" =>
                 "Load traces, diff prompts between runs, inspect tool calls, and ship an MVP by July 2026."
             }
           ] = result.snapshot["goals"]
  end

  test "can search facts with bm25 before answering" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    Workspace.upsert_draft(
      "fact",
      %{
        "title" => "Launch copy needs legal approval",
        "details" => "Initial launch messaging must be approved by legal before publishing.",
        "project_title" => "Launch portfolio site"
      },
      workspace
    )

    assert {:ok, _snapshot} = Workspace.save_draft(workspace)

    script =
      start_supervised!(
        {Agent,
         fn ->
           [
             fn request ->
               assert request.system_instruction =~ "search_facts_bm25"

               {:ok,
                %{
                  "message" => "Let me search the fact store.",
                  "needs_follow_up" => false,
                  "actions" => [
                    %{"tool" => "search_facts_bm25"}
                  ]
                }}
             end,
             fn request ->
               latest_message =
                 request.contents |> List.last() |> get_in(["parts", Access.at(0), "text"])

               assert latest_message =~ "Use the fact search results above"
               assert request.contents |> Jason.encode!() =~ "Launch copy needs legal approval"

               {:ok,
                %{
                  "message" =>
                    "We have one matching fact: launch copy needs legal approval for the Launch portfolio site project.",
                  "needs_follow_up" => false,
                  "actions" => []
                }}
             end
           ]
         end}
      )

    client = fn request ->
      Agent.get_and_update(script, fn
        [next | rest] -> {next.(request), rest}
        [] -> {{:error, :no_scripted_responses}, []}
      end)
    end

    assert {:ok, result} =
             Assistant.respond(
               "What facts do we have about legal approval for launches?",
               workspace: workspace,
               client: client
             )

    assert result.needs_follow_up == false
    assert result.snapshot["facts"] != []
    assert Enum.map(result.actions, & &1["tool"]) == ["search_facts_bm25"]
    assert result.message =~ "matching fact"
    assert result.message =~ "Launch portfolio site"
  end

  test "can search facts with grep before answering" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    Workspace.upsert_draft(
      "fact",
      %{
        "title" => "Debugger runs on the BEAM first",
        "details" => "The first debugger milestone should stay entirely on the BEAM runtime.",
        "project_title" => "Build debugger"
      },
      workspace
    )

    assert {:ok, _snapshot} = Workspace.save_draft(workspace)

    script =
      start_supervised!(
        {Agent,
         fn ->
           [
             fn request ->
               assert request.system_instruction =~ "search_facts_grep"

               {:ok,
                %{
                  "message" => "Let me search the fact store.",
                  "needs_follow_up" => false,
                  "actions" => [
                    %{"tool" => "search_facts_grep"}
                  ]
                }}
             end,
             fn request ->
               latest_message =
                 request.contents |> List.last() |> get_in(["parts", Access.at(0), "text"])

               assert latest_message =~ "Use the fact search results above"
               assert request.contents |> Jason.encode!() =~ "Debugger runs on the BEAM first"

               {:ok,
                %{
                  "message" =>
                    "We have one matching fact: the debugger needs to run on the BEAM first for the Build debugger project.",
                  "needs_follow_up" => false,
                  "actions" => []
                }}
             end
           ]
         end}
      )

    client = fn request ->
      Agent.get_and_update(script, fn
        [next | rest] -> {next.(request), rest}
        [] -> {{:error, :no_scripted_responses}, []}
      end)
    end

    assert {:ok, result} =
             Assistant.respond(
               "Search facts for /BEAM first/",
               workspace: workspace,
               client: client
             )

    assert result.needs_follow_up == false
    assert result.snapshot["facts"] != []
    assert Enum.map(result.actions, & &1["tool"]) == ["search_facts_grep"]
    assert result.message =~ "matching fact"
    assert result.message =~ "Build debugger"
  end

  test "can split multiple goals from one user message" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    client = fn _request ->
      {:ok,
       %{
         "message" => "I split that into two goals and started the second as the active draft.",
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
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "I want to launch my portfolio site by June and run a half marathon in October 2026.",
               workspace: workspace,
               client: client
             )

    assert result.needs_follow_up == true
    assert result.snapshot["active_draft"]["title"] == "Run a half marathon"

    assert Enum.map(result.snapshot["goals"], & &1["title"]) == [
             "Run a half marathon",
             "Launch portfolio site"
           ]
  end

  test "salvages newline-separated goals when the model only materializes one action" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    client = fn _request ->
      {:ok,
       %{
         "message" =>
           "I've started drafting two goals: one for the LLM reverse engineering tool and one for the BEAM VM currency kernel. To make these actionable, could you provide success criteria and a target date for each?",
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
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "build a binary ninja like reverse engineering tool for llms\nbuild a beam vm currency like kernel",
               workspace: workspace,
               client: client
             )

    assert result.needs_follow_up == true
    assert result.snapshot["active_draft"]["title"] == "Build a beam vm currency like kernel"

    assert Enum.map(result.snapshot["goals"], & &1["title"]) == [
             "Build a beam vm currency like kernel",
             "Build a Binary Ninja-like reverse engineering tool for LLMs"
           ]
  end

  test "does not duplicate newline-separated goals when the model already emitted both with paraphrased titles" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    client = fn _request ->
      {:ok,
       %{
         "message" =>
           "I've started drafts for both goals. Could you please provide success criteria and a target date for each?",
         "needs_follow_up" => true,
         "actions" => [
           %{"tool" => "upsert_draft"},
           %{"tool" => "upsert_draft", "kind" => "goal"},
           %{
             "tool" => "upsert_draft",
             "kind" => "goal",
             "fields" => %{"title" => "Build a Binary Ninja-like tool for LLMs"}
           },
           %{
             "tool" => "start_new_draft",
             "kind" => "goal",
             "fields" => %{"title" => "Build a BEAM VM currency-like kernel"}
           }
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "build a binary ninja like reverse engineering tool for llms\nbuild a beam vm currency like kernel",
               workspace: workspace,
               client: client
             )

    assert length(result.snapshot["goals"]) == 2

    assert Enum.map(result.snapshot["goals"], & &1["title"]) == [
             "Build a BEAM VM currency-like kernel",
             "Build a Binary Ninja-like tool for LLMs"
           ]
  end

  test "forces needs_follow_up to false after a successful save" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    client = fn _request ->
      {:ok,
       %{
         "message" => "Saved that goal. Want to add a first task?",
         "needs_follow_up" => true,
         "actions" => [
           %{
             "tool" => "upsert_draft",
             "kind" => "goal",
             "fields" => %{
               "title" => "Run a half marathon",
               "success_criteria" => "Finish in under two hours"
             }
           },
           %{"tool" => "save_draft"}
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "I want to run a half marathon and finish in under two hours.",
               workspace: workspace,
               client: client
             )

    assert result.needs_follow_up == false
    assert result.snapshot["active_draft"] == nil
    assert [%{"title" => "Run a half marathon"}] = result.snapshot["goals"]
  end

  test "links a task to the clearest existing goal before saving" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Build a Binary Ninja-like tool for LLMs",
        "success_criteria" =>
          "Load traces, diff prompts between runs, inspect tool calls, and deliver an MVP"
      },
      workspace
    )

    assert {:ok, _snapshot} = Workspace.save_draft(workspace)

    client = fn _request ->
      {:ok,
       %{
         "message" => "Saved that task.",
         "needs_follow_up" => false,
         "actions" => [
           %{
             "tool" => "upsert_draft",
             "kind" => "task",
             "fields" => %{
               "title" => "Build trace viewer",
               "due_date" => "2026-04-15",
               "priority" => "high"
             }
           },
           %{"tool" => "save_draft"}
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "Create a task to build the trace viewer by 2026-04-15 with high priority.",
               workspace: workspace,
               client: client
             )

    assert result.needs_follow_up == false

    assert [%{"parent_goal_title" => "Build a Binary Ninja-like tool for LLMs"}] =
             result.snapshot["tasks"]
  end

  test "saves a subgoal when the model links it to a parent goal" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "The portfolio site is live with strong proof of work"
      },
      workspace
    )

    assert {:ok, _snapshot} = Workspace.save_draft(workspace)

    client = fn request ->
      assert request.system_instruction =~ "Goals may be nested"
      assert request.system_instruction =~ "parent_goal_title"

      {:ok,
       %{
         "message" => "Started a subgoal under Launch portfolio site.",
         "needs_follow_up" => true,
         "actions" => [
           %{
             "tool" => "upsert_draft",
             "kind" => "goal",
             "fields" => %{
               "title" => "Publish three case studies",
               "parent_goal_title" => "Launch portfolio site"
             }
           }
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "Add a subgoal to publish three case studies before launch.",
               workspace: workspace,
               client: client,
               focus_object: %{
                 "kind" => "goal",
                 "title" => "Launch portfolio site",
                 "status" => "draft"
               }
             )

    assert result.snapshot["active_draft"]["kind"] == "goal"
    assert result.snapshot["active_draft"]["title"] == "Publish three case studies"
    assert result.snapshot["active_draft"]["parent_goal_title"] == "Launch portfolio site"
  end

  test "adds two focused tasks without creating a new goal" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Build a Thai language learning app",
        "success_criteria" => "Users can practice listening and speaking Thai every day"
      },
      workspace
    )

    assert {:ok, _snapshot} = Workspace.save_draft(workspace)

    client = fn request ->
      assert request.system_instruction =~ "Focused object:"
      assert request.system_instruction =~ "Build a Thai language learning app"

      {:ok,
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
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "add task, use the native voices to be listened, and allow the user to say them",
               workspace: workspace,
               client: client,
               focus_object: %{
                 "kind" => "goal",
                 "title" => "Build a Thai language learning app",
                 "status" => "draft"
               }
             )

    assert result.needs_follow_up == false
    assert result.snapshot["active_draft"] == nil
    assert length(result.snapshot["goals"]) == 1

    assert Enum.sort(Enum.map(result.snapshot["tasks"], & &1["title"])) == [
             "Add speech recognition input",
             "Implement native voice playback"
           ]

    assert Enum.all?(
             result.snapshot["tasks"],
             &(&1["parent_goal_title"] == "Build a Thai language learning app")
           )
  end

  test "does not create an empty goal from an incomplete goal action during an imperative task request" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Build a Thai language learning app",
        "success_criteria" => "Users can practice listening and speaking Thai every day"
      },
      workspace
    )

    assert {:ok, _snapshot} = Workspace.save_draft(workspace)

    client = fn _request ->
      {:ok,
       %{
         "message" =>
           "I've added two tasks to your Thai language app project: one for implementing native voice playback and another for speech recognition.",
         "needs_follow_up" => true,
         "actions" => [
           %{"tool" => "upsert_draft", "kind" => "goal"}
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "add task, use the native voices to be listened, and allow the user to say them",
               workspace: workspace,
               client: client,
               focus_object: %{
                 "kind" => "goal",
                 "title" => "Build a Thai language learning app",
                 "status" => "draft"
               }
             )

    assert length(result.snapshot["goals"]) == 1
    assert Enum.all?(result.snapshot["goals"], &(&1["title"] != nil and &1["title"] != ""))
    assert result.snapshot["active_draft"]["kind"] == "task"
    refute Enum.any?(result.snapshot["goals"], &(&1["title"] == "Add task"))
  end

  test "does not auto-link a task when multiple goal matches are equally plausible" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    for goal <- [
          %{
            "title" => "Launch portfolio site",
            "success_criteria" =>
              "Portfolio site launches successfully with the main page approved"
          },
          %{
            "title" => "Launch newsletter",
            "success_criteria" =>
              "Newsletter launches successfully with the first three issues scheduled"
          }
        ] do
      Workspace.upsert_draft("goal", goal, workspace)
      assert {:ok, _snapshot} = Workspace.save_draft(workspace)
    end

    client = fn _request ->
      {:ok,
       %{
         "message" => "Saved that task.",
         "needs_follow_up" => false,
         "actions" => [
           %{
             "tool" => "upsert_draft",
             "kind" => "task",
             "fields" => %{
               "title" => "Write launch copy",
               "due_date" => "2026-03-22"
             }
           },
           %{"tool" => "save_draft"}
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "Create a task to write the launch copy by 2026-03-22.",
               workspace: workspace,
               client: client
             )

    assert [%{"parent_goal_title" => nil}] = result.snapshot["tasks"]
  end

  test "starting a new goal leaves the previous saved goal unchanged" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form",
        "target_date" => "2026-05"
      },
      workspace
    )

    assert {:ok, _snapshot} = Workspace.save_draft(workspace)

    client = fn _request ->
      {:ok,
       %{
         "message" => "Started a new goal draft for learning Rust.",
         "needs_follow_up" => true,
         "actions" => [
           %{
             "tool" => "upsert_draft",
             "kind" => "goal",
             "fields" => %{"title" => "Learn Rust this quarter"}
           }
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "I also want to learn Rust this quarter.",
               workspace: workspace,
               client: client
             )

    assert result.snapshot["active_draft"]["title"] == "Learn Rust this quarter"

    assert Enum.map(result.snapshot["goals"], & &1["title"]) == [
             "Learn Rust this quarter",
             "Launch portfolio site"
           ]
  end

  test "renaming the active draft title keeps it as the same object" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Build an LLM reverse engineering studio",
        "details" => "Inspect traces and prompt runs"
      },
      workspace
    )

    client = fn _request ->
      {:ok,
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
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "project will be called flux",
               workspace: workspace,
               client: client
             )

    assert result.snapshot["active_draft"]["title"] == "Flux"
    assert length(result.snapshot["goals"]) == 1
    assert [%{"title" => "Flux"}] = result.snapshot["goals"]
  end

  test "can explicitly start a new draft while another goal is still being drafted" do
    workspace = start_supervised!({Workspace, path: temp_path()})

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Build debugger",
        "details" => "Inspect traces and memory state"
      },
      workspace
    )

    client = fn _request ->
      {:ok,
       %{
         "message" =>
           "Started a separate goal draft for the docs site. What would success look like for it?",
         "needs_follow_up" => true,
         "actions" => [
           %{
             "tool" => "start_new_draft",
             "kind" => "goal",
             "fields" => %{"title" => "Launch docs site"}
           }
         ]
       }}
    end

    assert {:ok, result} =
             Assistant.respond(
               "I also want to launch a docs site",
               workspace: workspace,
               client: client
             )

    assert result.snapshot["active_draft"]["title"] == "Launch docs site"

    assert Enum.map(result.snapshot["goals"], & &1["title"]) == [
             "Launch docs site",
             "Build debugger"
           ]
  end

  defp temp_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "g3-assistant-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.json"
      )

    File.rm(path)
    path
  end
end
