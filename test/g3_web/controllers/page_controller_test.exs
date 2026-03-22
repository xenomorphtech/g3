defmodule G3Web.PageControllerTest do
  use G3Web.ConnCase

  alias G3.Tracker.Workspace

  test "GET /", %{conn: conn} do
    Workspace.reset()
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Talk through it"
    assert html =~ "Current tracker context"
  end
end
