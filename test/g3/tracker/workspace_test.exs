defmodule G3.Tracker.WorkspaceTest do
  use ExUnit.Case, async: false

  alias G3.Tracker.Workspace

  test "persists saved items to disk" do
    path = temp_path("workspace")

    pid = start_supervised!({Workspace, path: path})
    Workspace.upsert_draft("task", %{"title" => "Send invoice", "due_date" => "2026-03-14"}, pid)
    assert {:ok, snapshot} = Workspace.save_draft(pid)
    assert length(snapshot["tasks"]) == 1

    GenServer.stop(pid)

    reloaded_pid =
      start_supervised!(%{
        id: make_ref(),
        start: {Workspace, :start_link, [[path: path]]}
      })

    reloaded_snapshot = Workspace.snapshot(reloaded_pid)

    assert [%{"title" => "Send invoice"}] = reloaded_snapshot["tasks"]
    assert reloaded_snapshot["active_draft"] == nil
  end

  test "keeps the active draft as an in-graph object with being_drafted status" do
    pid = start_supervised!({Workspace, path: temp_path("workspace-draft")})

    snapshot = Workspace.upsert_draft("goal", %{"title" => "Learn Rust"}, pid)

    assert snapshot["active_draft"]["title"] == "Learn Rust"
    assert snapshot["active_draft"]["status"] == "being_drafted"
    assert [%{"title" => "Learn Rust", "status" => "being_drafted"}] = snapshot["goals"]
    assert snapshot["tasks"] == []
  end

  test "persists a subgoal as a goal with a parent goal title" do
    path = temp_path("workspace-subgoals")
    pid = start_supervised!({Workspace, path: path})

    root_goal_id = create_saved_goal!(pid, "Launch portfolio site")

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Publish three case studies",
        "success_criteria" => "Three polished case studies are live on the site",
        "parent_goal_title" => "Launch portfolio site"
      },
      pid
    )

    assert {:ok, snapshot} = Workspace.save_draft(pid)

    assert Enum.any?(snapshot["goals"], fn goal ->
             goal["id"] != root_goal_id and
               goal["title"] == "Publish three case studies" and
               goal["parent_goal_title"] == "Launch portfolio site"
           end)

    GenServer.stop(pid)

    reloaded_pid =
      start_supervised!(%{
        id: make_ref(),
        start: {Workspace, :start_link, [[path: path]]}
      })

    reloaded_snapshot = Workspace.snapshot(reloaded_pid)

    assert Enum.any?(reloaded_snapshot["goals"], fn goal ->
             goal["title"] == "Publish three case studies" and
               goal["parent_goal_title"] == "Launch portfolio site"
           end)
  end

  test "persists saved facts in their own store" do
    path = temp_path("workspace-facts")
    pid = start_supervised!({Workspace, path: path})

    Workspace.upsert_draft(
      "fact",
      %{
        "title" => "Debugger runs on the BEAM first",
        "details" => "The first version should stay entirely on the BEAM runtime.",
        "project_title" => "Build debugger"
      },
      pid
    )

    assert {:ok, snapshot} = Workspace.save_draft(pid)

    assert [
             %{
               "title" => "Debugger runs on the BEAM first",
               "project_title" => "Build debugger",
               "status" => "known"
             }
           ] = snapshot["facts"]

    GenServer.stop(pid)

    reloaded_pid =
      start_supervised!(%{
        id: make_ref(),
        start: {Workspace, :start_link, [[path: path]]}
      })

    reloaded_snapshot = Workspace.snapshot(reloaded_pid)

    assert [%{"title" => "Debugger runs on the BEAM first"}] = reloaded_snapshot["facts"]
  end

  test "persists object conversation metadata" do
    path = temp_path("workspace-conversation")
    pid = start_supervised!({Workspace, path: path})

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form"
      },
      pid
    )

    snapshot =
      Workspace.put_object_conversation(
        "goal",
        "draft-current",
        [
          %{"role" => "user", "content" => "I want to launch my portfolio site"},
          %{
            "role" => "assistant",
            "content" => "What does success look like?",
            "follow_up" => true
          }
        ],
        pid
      )

    assert snapshot["active_draft"]["origin_conversation"] != nil

    assert {:ok, saved_snapshot} = Workspace.save_draft(pid)
    [%{"id" => goal_id}] = saved_snapshot["goals"]

    snapshot =
      Workspace.put_object_summary("goal", goal_id, "Launch site with case studies.", pid)

    [%{"origin_summary" => "Launch site with case studies."}] = snapshot["goals"]
  end

  test "activates a selected non-current draft before further edits" do
    pid = start_supervised!({Workspace, path: temp_path("workspace-activate-draft")})

    Workspace.upsert_draft("goal", %{"title" => "Build LLM reverse engineering tool"}, pid)
    snapshot = Workspace.start_draft("goal", %{"title" => "Build BEAM currency kernel"}, pid)

    assert snapshot["active_draft"]["title"] == "Build BEAM currency kernel"

    [%{"id" => first_goal_id}] =
      Enum.filter(snapshot["goals"], &(&1["title"] == "Build LLM reverse engineering tool"))

    activated_snapshot = Workspace.activate_draft("goal", first_goal_id, pid)

    assert activated_snapshot["active_draft"]["title"] == "Build LLM reverse engineering tool"

    assert Enum.any?(
             activated_snapshot["goals"],
             &(&1["title"] == "Build BEAM currency kernel" and &1["status"] == "being_drafted")
           )
  end

  test "reorders goals by the provided ids" do
    pid = start_supervised!({Workspace, path: temp_path("workspace-reorder-goals")})

    first_goal_id = create_saved_goal!(pid, "Build debugger")
    second_goal_id = create_saved_goal!(pid, "Ship docs")
    third_goal_id = create_saved_goal!(pid, "Launch beta")

    snapshot = Workspace.reorder_goals([third_goal_id, first_goal_id, second_goal_id], pid)

    assert Enum.map(snapshot["goals"], & &1["id"]) == [
             third_goal_id,
             first_goal_id,
             second_goal_id
           ]

    assert Enum.map(snapshot["goals"], & &1["title"]) == [
             "Launch beta",
             "Build debugger",
             "Ship docs"
           ]
  end

  test "updates saved object statuses" do
    pid = start_supervised!({Workspace, path: temp_path("workspace-statuses")})

    goal_id = create_saved_goal!(pid, "Launch beta")

    Workspace.upsert_draft("task", %{"title" => "Write release notes"}, pid)
    assert {:ok, task_snapshot} = Workspace.save_draft(pid)
    [%{"id" => task_id}] = task_snapshot["tasks"]

    _snapshot = Workspace.set_object_status("goal", goal_id, "achieved", pid)
    snapshot = Workspace.set_object_status("task", task_id, "completed", pid)

    assert Enum.any?(snapshot["goals"], &(&1["id"] == goal_id and &1["status"] == "achieved"))
    assert Enum.any?(snapshot["tasks"], &(&1["id"] == task_id and &1["status"] == "completed"))
  end

  test "saves a draft with an overridden completion status" do
    pid = start_supervised!({Workspace, path: temp_path("workspace-save-draft-as")})

    Workspace.upsert_draft("task", %{"title" => "Write release notes"}, pid)

    assert {:ok, snapshot} = Workspace.save_draft_as("completed", pid)
    assert snapshot["active_draft"] == nil
    assert [%{"title" => "Write release notes", "status" => "completed"}] = snapshot["tasks"]
  end

  test "upserting a new title renames the current draft instead of creating another goal" do
    pid = start_supervised!({Workspace, path: temp_path("workspace-rename-draft")})

    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Build an LLM reverse engineering studio",
        "details" => "Inspect traces and prompt runs"
      },
      pid
    )

    snapshot = Workspace.upsert_draft("goal", %{"title" => "Flux"}, pid)

    assert snapshot["active_draft"]["title"] == "Flux"
    assert length(snapshot["goals"]) == 1
    assert [%{"title" => "Flux"}] = snapshot["goals"]
  end

  test "reload normalizes duplicate archived draft ids so all goals remain visible" do
    path = temp_path("workspace-duplicate-draft-ids")

    File.write!(
      path,
      Jason.encode!(%{
        "goals" => [
          %{
            "id" => "draft-goal-10",
            "kind" => "goal",
            "title" => "Emulate NMSS protocol",
            "status" => "being_drafted"
          },
          %{
            "id" => "goal-32",
            "kind" => "goal",
            "title" => "Build a BEAM VM currency-like kernel",
            "status" => "draft"
          },
          %{
            "id" => "draft-goal-10",
            "kind" => "goal",
            "title" =>
              "Build Lux, a statically typed intermediate language targeting the BEAM VM",
            "status" => "being_drafted"
          }
        ],
        "tasks" => [],
        "facts" => []
      })
    )

    pid = start_supervised!({Workspace, path: path})
    snapshot = Workspace.snapshot(pid)

    assert length(snapshot["goals"]) == 3

    goal_ids = Enum.map(snapshot["goals"], & &1["id"])
    assert length(goal_ids) == MapSet.size(MapSet.new(goal_ids))

    assert Enum.map(snapshot["goals"], & &1["title"]) == [
             "Emulate NMSS protocol",
             "Build a BEAM VM currency-like kernel",
             "Build Lux, a statically typed intermediate language targeting the BEAM VM"
           ]
  end

  defp temp_path(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "g3-#{prefix}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.json"
      )

    File.rm(path)
    path
  end

  defp create_saved_goal!(pid, title) do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => title,
        "success_criteria" => "#{title} is complete and usable"
      },
      pid
    )

    assert {:ok, snapshot} = Workspace.save_draft(pid)
    [saved_goal | _rest] = snapshot["goals"]
    saved_goal["id"]
  end
end
