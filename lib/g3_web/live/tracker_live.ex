defmodule G3Web.TrackerLive do
  use G3Web, :live_view

  alias G3.Tracker.Assistant
  alias G3.Tracker.Draft
  alias G3.Tracker.Workspace

  @welcome_message """
  Tell me about a goal you want to achieve or a task you need to finish. I’ll keep a persistent draft object as we talk and ask follow-up questions when key details are missing.
  """

  @impl true
  def mount(_params, _session, socket) do
    snapshot = Workspace.snapshot()

    socket =
      socket
      |> assign(:page_title, "Goal Studio")
      |> assign(:form, empty_form())
      |> assign(:history, [])
      |> assign(:message_counter, 0)
      |> assign_snapshot(snapshot)
      |> stream_configure(:messages, dom_id: &"message-#{&1["id"]}")
      |> stream_configure(:goals, dom_id: &"goal-#{&1["id"]}")
      |> stream_configure(:tasks, dom_id: &"task-#{&1["id"]}")
      |> stream(:messages, [message("assistant", @welcome_message, 1, false)], reset: true)
      |> stream(:goals, snapshot["goals"], reset: true)
      |> stream(:tasks, snapshot["tasks"], reset: true)

    {:ok, assign(socket, :message_counter, 1)}
  end

  @impl true
  def handle_event("send_message", %{"chat" => %{"message" => raw_message}}, socket) do
    message_text = String.trim(raw_message)

    if message_text == "" do
      {:noreply, socket}
    else
      user_message = message("user", message_text, socket.assigns.message_counter + 1, false)

      socket =
        socket
        |> assign(:form, empty_form())
        |> assign(:message_counter, socket.assigns.message_counter + 1)
        |> stream_insert(:messages, user_message, at: -1)

      case Assistant.respond(message_text, history: socket.assigns.history) do
        {:ok, result} ->
          assistant_message =
            message(
              "assistant",
              result.message,
              socket.assigns.message_counter + 1,
              result.needs_follow_up
            )

          {:noreply,
           socket
           |> assign(:message_counter, socket.assigns.message_counter + 1)
           |> assign(
             :history,
             trim_history(socket.assigns.history ++ history_entries(message_text, result.message))
           )
           |> assign_snapshot(result.snapshot)
           |> stream_insert(:messages, assistant_message, at: -1)
           |> stream(:goals, result.snapshot["goals"], reset: true)
           |> stream(:tasks, result.snapshot["tasks"], reset: true)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end
  end

  def handle_event("clear_draft", _params, socket) do
    snapshot = Workspace.clear_draft()

    {:noreply, assign_snapshot(socket, snapshot)}
  end

  def handle_event("save_draft", _params, socket) do
    case Workspace.save_draft() do
      {:ok, snapshot} ->
        {:noreply,
         socket
         |> assign_snapshot(snapshot)
         |> stream(:goals, snapshot["goals"], reset: true)
         |> stream(:tasks, snapshot["tasks"], reset: true)
         |> put_flash(:info, "Draft saved.")}

      {:error, {:draft_incomplete, missing}} ->
        {:noreply, put_flash(socket, :error, Enum.join(missing, " "))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "There isn’t a ready draft to save yet.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section class="grid gap-6 xl:grid-cols-[minmax(0,1.35fr)_minmax(22rem,0.9fr)]">
        <div class="tracker-panel tracker-grid overflow-hidden rounded-[2rem]">
          <div class="relative space-y-8 px-5 py-6 sm:px-8 sm:py-8">
            <div class="flex flex-wrap items-start justify-between gap-5">
              <div class="space-y-2">
                <p class="text-xs uppercase tracking-[0.24em] text-slate-500">Goal Studio</p>
                <h1 class="font-heading text-4xl leading-none text-slate-950 sm:text-5xl">
                  Plan in chat
                </h1>
              </div>

              <div class="grid min-w-[15rem] gap-3 sm:grid-cols-2">
                <div class="rounded-3xl border border-white/70 bg-white/70 px-4 py-4 shadow-[0_18px_38px_rgba(15,23,42,0.08)]">
                  <p class="text-xs uppercase tracking-[0.24em] text-slate-500">Goals</p>
                  <p id="goals-count" class="mt-2 font-heading text-3xl text-slate-950">
                    {@goals_count}
                  </p>
                </div>
                <div class="rounded-3xl border border-white/70 bg-white/70 px-4 py-4 shadow-[0_18px_38px_rgba(15,23,42,0.08)]">
                  <p class="text-xs uppercase tracking-[0.24em] text-slate-500">Tasks</p>
                  <p id="tasks-count" class="mt-2 font-heading text-3xl text-slate-950">
                    {@tasks_count}
                  </p>
                </div>
              </div>
            </div>

            <div
              id="chat-messages"
              phx-update="stream"
              class="grid max-h-[34rem] gap-4 overflow-y-auto pr-1"
            >
              <article
                :for={{dom_id, entry} <- @streams.messages}
                id={dom_id}
                data-role={entry["role"]}
                class={[
                  "tracker-message rounded-[1.75rem] border px-4 py-4 shadow-[0_18px_38px_rgba(15,23,42,0.07)] sm:px-5",
                  entry["role"] == "assistant" &&
                    "border-white/70 bg-white/90 text-slate-800",
                  entry["role"] == "user" &&
                    "ml-auto max-w-[90%] border-sky-950/10 bg-sky-950 text-white"
                ]}
              >
                <div class="mb-2 flex items-center justify-between gap-3 text-xs uppercase tracking-[0.22em]">
                  <span class={[
                    entry["role"] == "assistant" && "text-slate-500",
                    entry["role"] == "user" && "text-sky-100"
                  ]}>
                    {if(entry["role"] == "assistant", do: "Studio", else: "You")}
                  </span>
                  <span
                    :if={entry["follow_up"]}
                    class="rounded-full bg-amber-100 px-2 py-1 text-[10px] text-amber-800"
                  >
                    Needs details
                  </span>
                </div>
                <p class="whitespace-pre-wrap text-sm leading-7">{entry["content"]}</p>
              </article>
            </div>

            <div class="rounded-[1.75rem] border border-slate-200/70 bg-white/80 p-4 shadow-[0_18px_38px_rgba(15,23,42,0.07)]">
              <.form for={@form} id="chat-composer" phx-submit="send_message" class="space-y-4">
                <.input
                  field={@form[:message]}
                  type="textarea"
                  label="What are you planning?"
                  rows="4"
                  placeholder="Examples: “I want to launch my portfolio site by June” or “Create a task to send the Q2 planning deck tomorrow.”"
                  phx-hook="SubmitOnCtrlEnter"
                  data-submit-target="chat-composer"
                  class="min-h-32 w-full rounded-[1.5rem] border border-slate-200 bg-white px-4 py-4 text-sm leading-7 text-slate-900 outline-none transition focus:border-sky-400 focus:ring-4 focus:ring-sky-100"
                  error_class="border-rose-400 ring-4 ring-rose-100"
                />

                <div class="flex flex-wrap items-center justify-between gap-3">
                  <p class="text-sm text-slate-500">
                    The assistant will patch the draft object before it answers. Press Ctrl+Enter to send.
                  </p>

                  <button
                    id="send-message"
                    type="submit"
                    phx-disable-with="Thinking..."
                    class="tracker-action inline-flex items-center gap-2 rounded-full bg-sky-950 px-5 py-3 text-sm font-semibold text-white"
                  >
                    <.icon name="hero-paper-airplane" class="size-4" /> Send to studio
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <aside class="grid gap-6">
          <section id="tracker-draft" class="tracker-panel overflow-hidden rounded-[2rem]">
            <div class="relative space-y-5 px-5 py-6 sm:px-6">
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="text-xs uppercase tracking-[0.24em] text-slate-500">Active draft</p>
                  <h2 class="mt-2 font-heading text-3xl text-slate-950">Object memory</h2>
                </div>
                <div class="flex gap-2">
                  <button
                    id="save-draft"
                    type="button"
                    phx-click="save_draft"
                    class="tracker-action rounded-full border border-slate-200 bg-white px-4 py-2 text-sm font-medium text-slate-800"
                  >
                    Save
                  </button>
                  <button
                    id="clear-draft"
                    type="button"
                    phx-click="clear_draft"
                    class="tracker-action rounded-full border border-slate-200 bg-white px-4 py-2 text-sm font-medium text-slate-800"
                  >
                    Clear
                  </button>
                </div>
              </div>

              <div class="rounded-[1.5rem] border border-white/70 bg-slate-950 p-4 text-sm text-slate-100 shadow-[0_18px_38px_rgba(15,23,42,0.16)]">
                <div class="mb-4 flex items-center justify-between gap-3">
                  <span
                    id="current-draft-kind"
                    data-value={(@draft && @draft["kind"]) || "none"}
                    class="rounded-full bg-white/10 px-3 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-200"
                  >
                    {if(@draft, do: @draft["kind"], else: "No draft")}
                  </span>
                  <span
                    id="draft-ready-flag"
                    data-value={if(@draft_completion.ready?, do: "ready", else: "incomplete")}
                    class={[
                      "rounded-full px-3 py-1 text-[10px] uppercase tracking-[0.24em]",
                      @draft_completion.ready? &&
                        "bg-emerald-400/15 text-emerald-200",
                      !@draft_completion.ready? &&
                        "bg-amber-400/15 text-amber-200"
                    ]}
                  >
                    {if(@draft_completion.ready?, do: "Ready", else: "Needs work")}
                  </span>
                </div>

                <pre
                  id="draft-json"
                  phx-no-curly-interpolation
                  class="overflow-x-auto whitespace-pre-wrap font-mono text-xs leading-6 text-slate-200"
                >{@draft_json}</pre>
              </div>

              <div :if={@draft_completion.missing != []} class="space-y-2">
                <p class="text-xs uppercase tracking-[0.24em] text-slate-500">Missing details</p>
                <ul id="draft-missing" class="space-y-2">
                  <li
                    :for={item <- @draft_completion.missing}
                    class="rounded-2xl border border-amber-200 bg-amber-50 px-3 py-3 text-sm text-amber-900"
                  >
                    {item}
                  </li>
                </ul>
              </div>
            </div>
          </section>

          <section class="tracker-panel overflow-hidden rounded-[2rem]">
            <div class="relative space-y-6 px-5 py-6 sm:px-6">
              <div>
                <p class="text-xs uppercase tracking-[0.24em] text-slate-500">Existing items</p>
                <h2 class="mt-2 font-heading text-3xl text-slate-950">Current tracker context</h2>
              </div>

              <div class="space-y-5">
                <div>
                  <div class="mb-3 flex items-center justify-between">
                    <h3 class="text-sm font-semibold uppercase tracking-[0.22em] text-slate-500">
                      Goals
                    </h3>
                    <span class="rounded-full border border-slate-200 bg-white px-2.5 py-1 text-xs text-slate-600">
                      {@goals_count}
                    </span>
                  </div>
                  <div id="goals-list" phx-update="stream" class="grid gap-3">
                    <p
                      id="goals-empty-state"
                      class="hidden rounded-2xl border border-dashed border-slate-300 bg-white/70 px-4 py-4 text-sm text-slate-500 only:block"
                    >
                      No goals yet.
                    </p>
                    <article
                      :for={{dom_id, goal} <- @streams.goals}
                      id={dom_id}
                      class="rounded-[1.5rem] border border-white/70 bg-white/85 px-4 py-4 shadow-[0_16px_34px_rgba(15,23,42,0.06)]"
                    >
                      <div class="flex items-start justify-between gap-3">
                        <div>
                          <h4 class="font-medium text-slate-950">{goal["title"]}</h4>
                          <p
                            :if={goal["success_criteria"]}
                            class="mt-1 text-sm leading-6 text-slate-600"
                          >
                            {goal["success_criteria"]}
                          </p>
                        </div>
                        <span class="rounded-full bg-slate-100 px-2.5 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-600">
                          {goal["status"] || "draft"}
                        </span>
                      </div>
                      <p
                        :if={goal["target_date"]}
                        class="mt-3 text-xs uppercase tracking-[0.22em] text-slate-500"
                      >
                        Target: {goal["target_date"]}
                      </p>
                    </article>
                  </div>
                </div>

                <div>
                  <div class="mb-3 flex items-center justify-between">
                    <h3 class="text-sm font-semibold uppercase tracking-[0.22em] text-slate-500">
                      Tasks
                    </h3>
                    <span class="rounded-full border border-slate-200 bg-white px-2.5 py-1 text-xs text-slate-600">
                      {@tasks_count}
                    </span>
                  </div>
                  <div id="tasks-list" phx-update="stream" class="grid gap-3">
                    <p
                      id="tasks-empty-state"
                      class="hidden rounded-2xl border border-dashed border-slate-300 bg-white/70 px-4 py-4 text-sm text-slate-500 only:block"
                    >
                      No tasks yet.
                    </p>
                    <article
                      :for={{dom_id, task} <- @streams.tasks}
                      id={dom_id}
                      class="rounded-[1.5rem] border border-white/70 bg-white/85 px-4 py-4 shadow-[0_16px_34px_rgba(15,23,42,0.06)]"
                    >
                      <div class="flex items-start justify-between gap-3">
                        <div>
                          <h4 class="font-medium text-slate-950">{task["title"]}</h4>
                          <p :if={task["details"]} class="mt-1 text-sm leading-6 text-slate-600">
                            {task["details"]}
                          </p>
                        </div>
                        <span class="rounded-full bg-slate-100 px-2.5 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-600">
                          {task["status"] || "planned"}
                        </span>
                      </div>
                      <div class="mt-3 flex flex-wrap gap-2 text-xs uppercase tracking-[0.2em] text-slate-500">
                        <span :if={task["due_date"]} class="rounded-full bg-rose-50 px-2.5 py-1">
                          Due {task["due_date"]}
                        </span>
                        <span :if={task["priority"]} class="rounded-full bg-sky-50 px-2.5 py-1">
                          {task["priority"]}
                        </span>
                        <span
                          :if={task["parent_goal_title"]}
                          class="rounded-full bg-emerald-50 px-2.5 py-1"
                        >
                          {task["parent_goal_title"]}
                        </span>
                      </div>
                    </article>
                  </div>
                </div>
              </div>
            </div>
          </section>
        </aside>
      </section>
    </Layouts.app>
    """
  end

  defp assign_snapshot(socket, snapshot) do
    assign(socket,
      draft: snapshot["active_draft"],
      draft_json: Jason.encode!(snapshot["active_draft"] || %{}, pretty: true),
      draft_completion: Draft.completion(snapshot["active_draft"]),
      goals_count: length(snapshot["goals"]),
      tasks_count: length(snapshot["tasks"])
    )
  end

  defp empty_form do
    to_form(%{"message" => ""}, as: :chat)
  end

  defp history_entries(user_message, assistant_message) do
    [
      %{"role" => "user", "content" => user_message},
      %{"role" => "assistant", "content" => assistant_message}
    ]
  end

  defp trim_history(history) do
    Enum.take(history, -10)
  end

  defp message(role, content, id, follow_up) do
    %{
      "id" => Integer.to_string(id),
      "role" => role,
      "content" => content,
      "follow_up" => follow_up
    }
  end

  defp error_message({:config_not_found, path}) do
    "Gemini config was not found at #{path}. Add your local JSON config and try again."
  end

  defp error_message({:missing_field, field}) do
    "Gemini config is missing the #{field} field."
  end

  defp error_message({:gemini_request_failed, _status, _body}) do
    "Gemini rejected the request. Check the configured model name and API key."
  end

  defp error_message(_reason) do
    "The assistant could not complete that turn."
  end
end
