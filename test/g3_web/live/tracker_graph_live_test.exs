defmodule G3Web.TrackerGraphLiveTest do
  use G3Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias G3.Tracker.Workspace

  setup do
    Workspace.reset()
    :ok
  end

  test "renders the dedicated graph page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/graph")

    assert has_element?(view, "#tracker-graph-page")
    assert has_element?(view, "#goals-graph")
    assert has_element?(view, "#back-to-tracker[href='/']")
    assert has_element?(view, "#graph-selected-empty")
  end

  test "graph page renders goal, subgoal, and task relationships", %{conn: conn} do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form"
      }
    )

    assert {:ok, root_snapshot} = Workspace.save_draft()
    [%{"id" => root_goal_id}] = root_snapshot["goals"]

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

    Workspace.upsert_draft(
      "task",
      %{
        "title" => "Draft case study outlines",
        "parent_goal_title" => "Publish three case studies"
      }
    )

    assert {:ok, task_snapshot} = Workspace.save_draft()
    [%{"id" => task_id}] = task_snapshot["tasks"]

    {:ok, view, _html} = live(conn, ~p"/graph")

    assert has_element?(view, "#graph-goal-#{root_goal_id}")
    assert has_element?(view, "#graph-goal-#{subgoal_id}")
    assert has_element?(view, "#graph-task-#{task_id}")
    assert has_element?(view, "#graph-edge-#{root_goal_id}-#{subgoal_id}")
    assert has_element?(view, "#graph-edge-#{subgoal_id}-#{task_id}")
  end

  test "graph nodes render without kind or status labels", %{conn: conn} do
    Workspace.upsert_draft("goal", %{"title" => "Run a half marathon"})

    {:ok, view, _html} = live(conn, ~p"/graph")

    assert has_element?(view, "#graph-goal-draft-current h4", "Run a half marathon")
    refute has_element?(view, "#graph-goal-draft-current p")
    refute has_element?(view, "#graph-goal-draft-current span")
  end

  test "selecting a node shows its details", %{conn: conn} do
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

    {:ok, view, _html} = live(conn, ~p"/graph")

    view
    |> element("#graph-goal-#{goal_id}")
    |> render_click()

    assert has_element?(view, "#graph-selected-panel[data-selected-id='#{goal_id}']")
    assert has_element?(view, "#graph-selected-title", "Launch portfolio site")
    assert has_element?(view, "#graph-selected-details")
  end

  test "achieved goals and their descendants are hidden by default and can be shown again", %{
    conn: conn
  } do
    Workspace.upsert_draft(
      "goal",
      %{
        "title" => "Launch portfolio site",
        "success_criteria" => "Portfolio site is live with case studies and a contact form"
      }
    )

    assert {:ok, root_snapshot} = Workspace.save_draft()
    [%{"id" => root_goal_id}] = root_snapshot["goals"]

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

    Workspace.upsert_draft(
      "task",
      %{
        "title" => "Draft case study outlines",
        "parent_goal_title" => "Publish three case studies"
      }
    )

    assert {:ok, task_snapshot} = Workspace.save_draft()
    [%{"id" => task_id}] = task_snapshot["tasks"]

    {:ok, view, _html} = live(conn, ~p"/graph")

    view
    |> element("#graph-goal-#{root_goal_id}")
    |> render_click()

    view
    |> element("#toggle-graph-selected-completion")
    |> render_click()

    refute has_element?(view, "#graph-goal-#{root_goal_id}")
    refute has_element?(view, "#graph-goal-#{subgoal_id}")
    refute has_element?(view, "#graph-task-#{task_id}")
    assert has_element?(view, "#graph-selected-empty")

    view
    |> element("#toggle-show-completed-graph")
    |> render_click()

    assert has_element?(view, "#graph-goal-#{root_goal_id}")
    assert has_element?(view, "#graph-goal-#{subgoal_id}")
    assert has_element?(view, "#graph-task-#{task_id}")
  end

  test "being drafted tasks can be completed directly from the graph page", %{conn: conn} do
    Workspace.upsert_draft(
      "task",
      %{
        "title" => "Write homepage copy",
        "due_date" => "2026-03-20"
      }
    )

    {:ok, view, _html} = live(conn, ~p"/graph")

    assert has_element?(view, "#graph-selected-panel[data-selected-id='draft-current']")
    assert has_element?(view, "#toggle-graph-selected-completion", "Complete and save")

    view
    |> element("#toggle-graph-selected-completion")
    |> render_click()

    [%{"id" => task_id, "status" => "completed"}] = Workspace.snapshot()["tasks"]

    refute has_element?(view, "#graph-task-draft-current")
    assert has_element?(view, "#graph-selected-empty")

    view
    |> element("#toggle-show-completed-graph")
    |> render_click()

    assert has_element?(view, "#graph-task-#{task_id}")

    view
    |> element("#graph-task-#{task_id}")
    |> render_click()

    assert has_element?(view, "#toggle-graph-selected-completion", "Restore task")
  end
end
