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

  defp temp_path(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "g3-#{prefix}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}.json"
      )

    File.rm(path)
    path
  end
end
