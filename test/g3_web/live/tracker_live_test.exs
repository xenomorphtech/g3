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

    assert has_element?(view, "#chat-composer")

    assert has_element?(
             view,
             "#chat_message[phx-hook='SubmitOnCtrlEnter'][data-submit-target='chat-composer']"
           )

    assert has_element?(view, "#tracker-draft")
    assert has_element?(view, "#goals-list")
    assert has_element?(view, "#tasks-list")
  end

  test "submitting a message updates the persistent draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#chat-composer", chat: %{message: "I want to run a half marathon"})
    |> render_submit()

    assert has_element?(view, "#current-draft-kind[data-value='goal']")
    assert has_element?(view, "#draft-ready-flag[data-value='incomplete']")
    assert has_element?(view, "#chat-messages [data-role='assistant']")
  end
end
