defmodule G3Web.TrackerLiveTest do
  use G3Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias G3.Tracker.Workspace

  setup do
    Workspace.reset()

    script =
      start_supervised!(
        {Agent,
         fn ->
           [
             fn _request ->
               {:ok,
                %{
                  "message" => "What would success look like for that goal?",
                  "needs_follow_up" => true,
                  "actions" => [
                    %{
                      "tool" => "upsert_draft",
                      "kind" => "goal",
                      "fields" => %{"title" => "Run a half marathon"}
                    }
                  ]
                }}
             end
           ]
         end}
      )

    Application.put_env(:g3, :tracker_model_script, script)
    on_exit(fn -> Application.delete_env(:g3, :tracker_model_script) end)
    :ok
  end

  test "renders the tracker shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#tracker-page[phx-hook='PreventInitialFocus']")
    assert has_element?(view, "#chat-composer[phx-hook='ClearOnSubmit']")

    assert has_element?(
             view,
             "#chat_message[phx-hook='SubmitOnCtrlEnter'][data-submit-target='chat-composer']"
           )

    assert has_element?(view, "#chat-panel")
    assert has_element?(view, "#existing-items-panel")
    assert has_element?(view, "#existing-items-panel.order-1")
    assert has_element?(view, "#chat-panel.order-3")
    assert has_element?(view, "#tracker-draft")
    assert has_element?(view, "#open-graph-page[href='/graph']")
    refute has_element?(view, "#goals-graph")
    assert has_element?(view, "#goals-list[phx-hook='GoalsSorter']")
    assert has_element?(view, "#tasks-list")
    refute has_element?(view, "#facts-list")
    assert has_element?(view, "#tracker-draft #selected-object-empty")
  end

  test "the left items panel can be hidden and shown again", %{conn: conn} do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form"
      }
    )

    assert {:ok, goal_snapshot} = Workspace.save_draft()
    [%{"id" => goal_id}] = goal_snapshot["goals"]

    Workspace.upsert_draft(
      "fact",
      %{
        "title" => "Launch copy needs legal approval",
        "details" => "Initial launch messaging must be approved by legal before publishing.",
        "project_title" => "Launch portfolio site"
      }
    )

    assert {:ok, fact_snapshot} = Workspace.save_draft()
    [%{"id" => fact_id}] = fact_snapshot["facts"]

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#goal-#{goal_id}")

    view
    |> element("#hide-items-panel")
    |> render_click()

    refute has_element?(view, "#existing-items-panel")
    assert has_element?(view, "#items-panel-rail")
    assert has_element?(view, "#show-items-panel")

    view
    |> element("#show-items-panel")
    |> render_click()

    assert has_element?(view, "#existing-items-panel")
    refute has_element?(view, "#items-panel-rail")
    assert has_element?(view, "#goal-#{goal_id}")
    refute has_element?(view, "#fact-#{fact_id}")
  end

  test "existing-items pane does not render fact cards and keeps goal/task cards concise", %{
    conn: conn
  } do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form"
      }
    )

    assert {:ok, goal_snapshot} = Workspace.save_draft()
    [%{"id" => goal_id}] = goal_snapshot["goals"]

    Workspace.upsert_draft(
      "task",
      %{
        "title" => "Write homepage copy",
        "details" => "Draft and review the launch copy with legal."
      }
    )

    assert {:ok, task_snapshot} = Workspace.save_draft()
    [%{"id" => task_id}] = task_snapshot["tasks"]

    Workspace.upsert_draft(
      "fact",
      %{
        "title" => "Launch copy needs legal approval",
        "details" => "Initial launch messaging must be approved by legal before publishing.",
        "project_title" => "Launch portfolio site"
      }
    )

    assert {:ok, fact_snapshot} = Workspace.save_draft()
    [%{"id" => fact_id}] = fact_snapshot["facts"]

    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#goal-#{goal_id} p")
    refute has_element?(view, "#task-#{task_id} p")
    refute has_element?(view, "#fact-#{fact_id}")
  end

  test "submitting a message updates the persistent draft and selects it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#chat-composer", chat: %{message: "I want to run a half marathon"})
    |> render_submit()

    assert has_element?(view, "#current-draft-kind[data-value='goal']")
    assert has_element?(view, "#draft-ready-flag[data-value='incomplete']")
    assert has_element?(view, "#draft-title", "Run a half marathon")
    refute has_element?(view, "#draft-json")
    assert has_element?(view, "#chat-messages [data-role='assistant']")
    assert has_element?(view, "#selected-object-panel[data-selected-id='draft-current']")
    assert chat_message_value(view) == ""
  end

  test "clicking a graph object shows it in the header detail view", %{conn: conn} do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form",
        "target_date" => "2026-05"
      }
    )

    assert {:ok, _snapshot} = Workspace.save_draft()
    snapshot = Workspace.snapshot()
    [%{"id" => goal_id}] = snapshot["goals"]

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#goal-#{goal_id}")
    |> render_click()

    assert has_element?(view, "#selected-object-panel[data-selected-id='#{goal_id}']")
    assert has_element?(view, "#goal-#{goal_id}[data-selected='true']")
  end

  test "selecting a goal shows its related facts in the center panel without duplicating project details",
       %{conn: conn} do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form"
      }
    )

    assert {:ok, goal_snapshot} = Workspace.save_draft()
    [%{"id" => goal_id}] = goal_snapshot["goals"]

    Workspace.upsert_draft(
      "fact",
      %{
        "title" => "Launch copy needs legal approval",
        "details" => "Initial launch messaging must be approved by legal before publishing.",
        "project_title" => "Launch portfolio site"
      }
    )

    assert {:ok, _fact_snapshot} = Workspace.save_draft()

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#goal-#{goal_id}")
    |> render_click()

    refute has_element?(view, "#project-context")
    refute has_element?(view, "#selected-object-title")
    assert has_element?(view, "#related-facts", "Launch copy needs legal approval")
    assert has_element?(view, "#draft-description", "Portfolio site is live with case studies")
    assert has_element?(view, "#draft-facts", "Linked facts: 1")
  end

  test "selecting a goal shows its linked tasks in the center panel", %{conn: conn} do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "ps4/5",
        "success_criteria" => "Console is acquired and ready for jailbreaking"
      }
    )

    assert {:ok, goal_snapshot} = Workspace.save_draft()
    [%{"id" => goal_id}] = goal_snapshot["goals"]

    Workspace.upsert_draft(
      "task",
      %{
        "title" => "Acquire jailbreakable PS4/5",
        "details" => "Check local listings and firmware versions before buying.",
        "due_date" => "2026-03-22",
        "parent_goal_title" => "ps4/5"
      }
    )

    assert {:ok, task_snapshot} = Workspace.save_draft()
    [%{"id" => task_id}] = task_snapshot["tasks"]

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#goal-#{goal_id}")
    |> render_click()

    assert has_element?(view, "#related-tasks")
    assert has_element?(view, "#related-tasks-count", "1")
    assert has_element?(view, "#related-task-#{task_id}", "Acquire jailbreakable PS4/5")
    assert has_element?(view, "#related-task-#{task_id}", "Due 2026-03-22")
  end

  test "selecting a task does not show project facts for its parent goal", %{conn: conn} do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form"
      }
    )

    assert {:ok, _goal_snapshot} = Workspace.save_draft()

    Workspace.upsert_draft(
      "fact",
      %{
        "title" => "Launch copy needs legal approval",
        "details" => "Initial launch messaging must be approved by legal before publishing.",
        "project_title" => "Launch portfolio site"
      }
    )

    assert {:ok, _fact_snapshot} = Workspace.save_draft()

    Workspace.upsert_draft(
      "task",
      %{
        "title" => "Write homepage copy",
        "due_date" => "2026-03-20",
        "parent_goal_title" => "Launch portfolio site"
      }
    )

    assert {:ok, task_snapshot} = Workspace.save_draft()
    [%{"id" => task_id}] = task_snapshot["tasks"]

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#task-#{task_id}")
    |> render_click()

    assert has_element?(view, "#project-context", "Launch portfolio site")
    refute has_element?(view, "#related-facts")
  end

  test "selecting a subgoal shows its parent goal as project context", %{conn: conn} do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form"
      }
    )

    assert {:ok, _snapshot} = Workspace.save_draft()

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Publish three case studies",
        "success_criteria" => "Three polished case studies are live on the site",
        "parent_goal_title" => "Launch portfolio site"
      }
    )

    assert {:ok, subgoal_snapshot} = Workspace.save_draft()

    [%{"id" => subgoal_id}] =
      Enum.filter(subgoal_snapshot["goals"], &(&1["title"] == "Publish three case studies"))

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#goal-#{subgoal_id}")
    |> render_click()

    assert has_element?(view, "#project-context", "Launch portfolio site")
    assert has_element?(view, "#draft-facts", "Parent: Launch portfolio site")
  end

  test "sending a fact while a goal is selected saves it under that project", %{conn: conn} do
    script =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Agent, :start_link,
           [
             fn ->
               [
                 fn request ->
                   assert request.system_instruction =~ "Focused object:"
                   assert request.system_instruction =~ "Launch portfolio site"

                   {:ok,
                    %{
                      "message" => "Saved that as a fact for the project.",
                      "needs_follow_up" => false,
                      "actions" => [
                        %{
                          "tool" => "upsert_draft",
                          "kind" => "fact",
                          "fields" => %{
                            "title" => "Launch copy needs legal approval",
                            "details" =>
                              "It must be approved by legal before the launch goes out."
                          }
                        },
                        %{"tool" => "save_draft"}
                      ]
                    }}
                 end
               ]
             end
           ]}
      })

    Application.put_env(:g3, :tracker_model_script, script)

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form"
      }
    )

    assert {:ok, snapshot} = Workspace.save_draft()
    [%{"id" => goal_id}] = snapshot["goals"]

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#goal-#{goal_id}")
    |> render_click()

    view
    |> form("#chat-composer",
      chat: %{message: "Fact: it must be approved by legal before launch."}
    )
    |> render_submit()

    [%{"id" => fact_id, "title" => fact_title, "project_title" => project_title}] =
      Workspace.snapshot()["facts"]

    assert has_element?(view, "#facts-count", "1")
    refute has_element?(view, "#fact-#{fact_id}")
    assert has_element?(view, "#draft-facts", "Linked facts: 1")
    assert fact_title == "Launch copy needs legal approval"
    assert project_title == "Launch portfolio site"
  end

  test "clear focus clears the selected header and object memory", %{conn: conn} do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Build debugger",
        "details" => "Inspect traces and memory state"
      }
    )

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#selected-object-panel[data-selected-id='draft-current']")
    assert has_element?(view, "#draft-title", "Build debugger")

    view
    |> element("#clear-selection")
    |> render_click()

    refute has_element?(view, "#selected-object-panel")
    assert has_element?(view, "#selected-object-empty")
    assert has_element?(view, "#draft-empty-state")
    assert has_element?(view, "#chat-messages [data-role='assistant']", "Tell me about a goal")
    assert has_element?(view, "#goal-draft-current[data-selected='false']")
  end

  test "reordering goals updates their persisted order", %{conn: conn} do
    first_goal_id = create_saved_goal!("Build debugger")
    second_goal_id = create_saved_goal!("Ship docs")
    third_goal_id = create_saved_goal!("Launch beta")

    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "reorder_goals", %{"ids" => [third_goal_id, first_goal_id, second_goal_id]})

    assert Enum.map(Workspace.snapshot()["goals"], & &1["id"]) == [
             third_goal_id,
             first_goal_id,
             second_goal_id
           ]

    assert has_element?(view, "#goal-#{third_goal_id}[data-goal-id='#{third_goal_id}']")
  end

  test "completed tasks are hidden by default and can be shown again", %{conn: conn} do
    Workspace.upsert_draft(
      "task",
      %{
        "title" => "Write homepage copy",
        "due_date" => "2026-03-20"
      }
    )

    assert {:ok, snapshot} = Workspace.save_draft()
    [%{"id" => task_id}] = snapshot["tasks"]

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#task-#{task_id}")
    |> render_click()

    view
    |> element("#toggle-selected-completion")
    |> render_click()

    refute has_element?(view, "#task-#{task_id}")
    refute has_element?(view, "#selected-object-panel")

    view
    |> element("#toggle-show-completed")
    |> render_click()

    assert has_element?(view, "#task-#{task_id}")
    assert has_element?(view, "#task-#{task_id}", "completed")
  end

  test "being drafted tasks can be completed directly", %{conn: conn} do
    Workspace.upsert_draft(
      "task",
      %{
        "title" => "Write homepage copy",
        "due_date" => "2026-03-20"
      }
    )

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#selected-object-panel[data-selected-id='draft-current']")
    assert has_element?(view, "#toggle-selected-completion", "Complete and save")

    view
    |> element("#toggle-selected-completion")
    |> render_click()

    [%{"id" => task_id, "status" => "completed"}] = Workspace.snapshot()["tasks"]

    refute has_element?(view, "#task-draft-current")
    refute has_element?(view, "#selected-object-panel")

    view
    |> element("#toggle-show-completed")
    |> render_click()

    assert has_element?(view, "#task-#{task_id}")
    assert has_element?(view, "#task-#{task_id}", "completed")
  end

  test "clarifying a selected non-current draft updates that selected goal", %{conn: conn} do
    script =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Agent, :start_link,
           [
             fn ->
               [
                 fn request ->
                   active_draft_section =
                     request.system_instruction
                     |> String.split("Goals:")
                     |> List.first()

                   assert active_draft_section =~
                            ~s("title": "Build LLM reverse engineering tool")

                   refute active_draft_section =~ ~s("title": "Build BEAM currency kernel")

                   {:ok,
                    %{
                      "message" => "Added success criteria to the LLM reverse engineering tool.",
                      "needs_follow_up" => true,
                      "actions" => [
                        %{
                          "tool" => "upsert_draft",
                          "kind" => "goal",
                          "fields" => %{
                            "success_criteria" => "Can inspect traces, prompts, and tool calls"
                          }
                        }
                      ]
                    }}
                 end
               ]
             end
           ]}
      })

    Application.put_env(:g3, :tracker_model_script, script)

    Workspace.upsert_draft("goal", %{"title" => "Build LLM reverse engineering tool"})
    snapshot = Workspace.start_draft("goal", %{"title" => "Build BEAM currency kernel"})

    [%{"id" => first_goal_id}] =
      Enum.filter(snapshot["goals"], &(&1["title"] == "Build LLM reverse engineering tool"))

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#goal-#{first_goal_id}")
    |> render_click()

    assert Workspace.snapshot()["active_draft"]["title"] == "Build LLM reverse engineering tool"

    view
    |> form("#chat-composer",
      chat: %{message: "Success means it can inspect traces, prompts, and tool calls"}
    )
    |> render_submit()

    active_draft = Workspace.snapshot()["active_draft"]

    assert active_draft["title"] == "Build LLM reverse engineering tool"
    assert active_draft["success_criteria"] == "Can inspect traces, prompts, and tool calls"

    assert Enum.any?(
             Workspace.snapshot()["goals"],
             &(&1["title"] == "Build BEAM currency kernel" and &1["status"] == "being_drafted")
           )
  end

  test "selecting an object restores its saved conversation", %{conn: conn} do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form",
        "target_date" => "2026-05"
      }
    )

    assert {:ok, snapshot} = Workspace.save_draft()
    [%{"id" => goal_id}] = snapshot["goals"]

    Workspace.put_object_conversation(
      "goal",
      goal_id,
      [
        %{
          "role" => "user",
          "content" => "I want to launch my portfolio site",
          "follow_up" => false
        },
        %{"role" => "assistant", "content" => "What does success look like?", "follow_up" => true}
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#goal-#{goal_id}")
    |> render_click()

    assert has_element?(view, "#selected-object-panel[data-selected-id='#{goal_id}']")

    assert has_element?(
             view,
             "#chat-messages [data-role='user']",
             "I want to launch my portfolio site"
           )

    assert has_element?(
             view,
             "#chat-messages [data-role='assistant']",
             "What does success look like?"
           )
  end

  test "summarizing and clearing a selected object's conversation updates the UI", %{conn: conn} do
    script =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Agent, :start_link,
           [
             fn ->
               [
                 fn request ->
                   assert request.system_instruction =~
                            "You summarize object-origin planning conversations."

                   {:ok,
                    %{
                      "summary" => "Launch portfolio site with case studies and a clear deadline."
                    }}
                 end
               ]
             end
           ]}
      })

    Application.put_env(:g3, :tracker_model_script, script)

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form",
        "target_date" => "2026-05"
      }
    )

    assert {:ok, snapshot} = Workspace.save_draft()
    [%{"id" => goal_id}] = snapshot["goals"]

    Workspace.put_object_conversation(
      "goal",
      goal_id,
      [
        %{
          "role" => "user",
          "content" => "I want to launch my portfolio site",
          "follow_up" => false
        },
        %{"role" => "assistant", "content" => "What does success look like?", "follow_up" => true}
      ]
    )

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> element("#goal-#{goal_id}")
    |> render_click()

    view
    |> element("#summarize-conversation")
    |> render_click()

    assert has_element?(
             view,
             "#selected-object-summary",
             "Launch portfolio site with case studies and a clear deadline."
           )

    view
    |> element("#clear-conversation")
    |> render_click()

    refute has_element?(view, "#selected-object-summary")
    assert has_element?(view, "#chat-messages [data-role='assistant']", "Tell me about a goal")
  end

  defp chat_message_value(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#chat_message")
    |> Enum.map(&LazyHTML.text/1)
    |> List.first()
    |> Kernel.||("")
  end

  defp create_saved_goal!(title) do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => title,
        "success_criteria" => "#{title} is complete and usable"
      }
    )

    assert {:ok, snapshot} = Workspace.save_draft()
    [saved_goal | _rest] = snapshot["goals"]
    saved_goal["id"]
  end
end
