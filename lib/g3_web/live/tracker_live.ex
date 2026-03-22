defmodule G3Web.TrackerLive do
  use G3Web, :live_view

  alias G3.Tracker.Assistant
  alias G3.Tracker.ConversationSummary
  alias G3.Tracker.Draft
  alias G3.Tracker.Hierarchy
  alias G3.Tracker.Workspace

  @welcome_message """
  Tell me about a goal you want to achieve, a subgoal that belongs under another goal, a task you need to finish, or a fact you want to retain. I’ll keep an in-graph object in `being_drafted` status as we talk and ask follow-up questions when key details are missing.
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
      |> assign(:items_panel_hidden, false)
      |> assign(:show_completed, false)
      |> assign(:selection_mode, :auto)
      |> assign(:selected_object, nil)
      |> assign_snapshot(snapshot)
      |> stream_configure(:messages, dom_id: &"message-#{&1["id"]}")
      |> stream_configure(:goals, dom_id: &"goal-#{&1["id"]}")
      |> stream_configure(:tasks, dom_id: &"task-#{&1["id"]}")
      |> stream_configure(:facts, dom_id: &"fact-#{&1["id"]}")
      |> sync_chat_from_selection()

    socket =
      socket
      |> stream(:goals, socket.assigns.visible_goals, reset: true)
      |> stream(:tasks, socket.assigns.visible_tasks, reset: true)
      |> stream(:facts, socket.assigns.facts, reset: true)

    {:ok, socket}
  end

  @impl true
  def handle_event("send_message", %{"chat" => %{"message" => raw_message}}, socket) do
    message_text = String.trim(raw_message)

    if message_text == "" do
      {:noreply, socket}
    else
      _snapshot = maybe_activate_selected_draft(socket.assigns.selected_object)
      user_message = message("user", message_text, socket.assigns.message_counter + 1, false)

      socket =
        socket
        |> assign(:form, empty_form())
        |> assign(:message_counter, socket.assigns.message_counter + 1)
        |> stream_insert(:messages, user_message, at: -1)

      case Assistant.respond(
             message_text,
             history: socket.assigns.history,
             focus_object: socket.assigns.selected_object
           ) do
        {:ok, result} ->
          next_history =
            trim_history(
              socket.assigns.history ++
                history_entries(message_text, result.message, result.needs_follow_up)
            )

          {snapshot, selected_object, selection_mode} =
            persist_origin_conversation(
              result.snapshot,
              result.actions,
              socket.assigns.selected_object,
              socket.assigns.selection_mode,
              next_history
            )

          {:noreply,
           socket
           |> sync_snapshot(
             snapshot,
             selected_object: selected_object,
             selection_mode: selection_mode
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, error_message(reason))}
      end
    end
  end

  def handle_event("clear_draft", _params, socket) do
    snapshot = Workspace.clear_draft()

    {:noreply, sync_snapshot(socket, snapshot)}
  end

  def handle_event("save_draft", _params, socket) do
    case Workspace.save_draft() do
      {:ok, snapshot} ->
        {:noreply,
         socket
         |> sync_snapshot(snapshot)
         |> put_flash(:info, "Draft saved.")}

      {:error, {:draft_incomplete, missing}} ->
        {:noreply, put_flash(socket, :error, Enum.join(missing, " "))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "There isn’t a ready draft to save yet.")}
    end
  end

  def handle_event("select_object", %{"id" => id, "kind" => kind}, socket) do
    selected_object =
      find_object(socket.assigns.goals, socket.assigns.tasks, socket.assigns.facts, kind, id)

    snapshot =
      if drafting_object?(selected_object) do
        Workspace.activate_draft(kind, id)
      else
        Workspace.snapshot()
      end

    {:noreply, sync_snapshot(socket, snapshot, selected_object: selected_object)}
  end

  def handle_event("clear_selection", _params, socket) do
    snapshot = Workspace.snapshot()

    {:noreply, sync_snapshot(socket, snapshot, selected_object: nil, selection_mode: :cleared)}
  end

  def handle_event("toggle_items_panel", _params, socket) do
    {:noreply,
     socket
     |> assign(:items_panel_hidden, !socket.assigns.items_panel_hidden)
     |> refresh_item_streams()}
  end

  def handle_event("toggle_show_completed", _params, socket) do
    show_completed = !socket.assigns.show_completed
    snapshot = Workspace.snapshot()

    selected_object =
      if selected_object_visible?(socket.assigns.selected_object, snapshot, show_completed) do
        socket.assigns.selected_object
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:show_completed, show_completed)
     |> sync_snapshot(
       snapshot,
       selected_object: selected_object,
       selection_mode: if(selected_object, do: :manual, else: :cleared)
     )}
  end

  def handle_event("set_selected_status", %{"status" => status}, socket) do
    case socket.assigns.selected_object do
      %{"kind" => kind, "id" => "draft-current"} when kind in ["goal", "task"] ->
        case Workspace.save_draft_as(status) do
          {:ok, snapshot} ->
            saved_object = latest_saved_object(snapshot, kind)

            resolved_selected_object =
              if selected_object_visible?(saved_object, snapshot, socket.assigns.show_completed) do
                saved_object
              else
                nil
              end

            {:noreply,
             socket
             |> sync_snapshot(
               snapshot,
               selected_object: resolved_selected_object,
               selection_mode: if(resolved_selected_object, do: :manual, else: :cleared)
             )
             |> put_flash(:info, status_flash_message(kind, status))}

          {:error, {:draft_incomplete, missing}} ->
            {:noreply, put_flash(socket, :error, Enum.join(missing, " "))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "That draft cannot be saved yet.")}
        end

      %{"kind" => kind, "id" => id} = selected_object when kind in ["goal", "task"] ->
        snapshot = Workspace.set_object_status(kind, id, status)

        resolved_selected_object =
          if selected_object_visible?(selected_object, snapshot, socket.assigns.show_completed) do
            find_object(snapshot["goals"], snapshot["tasks"], snapshot["facts"], kind, id)
          else
            nil
          end

        {:noreply,
         socket
         |> sync_snapshot(
           snapshot,
           selected_object: resolved_selected_object,
           selection_mode: if(resolved_selected_object, do: :manual, else: :cleared)
         )
         |> put_flash(:info, status_flash_message(kind, status))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("reorder_goals", %{"ids" => ids}, socket) when is_list(ids) do
    snapshot = Workspace.reorder_goals(ids)

    {:noreply, sync_snapshot(socket, snapshot)}
  end

  def handle_event("summarize_conversation", _params, socket) do
    case selected_history(socket.assigns.selected_object) do
      [] ->
        {:noreply,
         put_flash(socket, :error, "There isn’t a saved conversation to summarize yet.")}

      history ->
        case ConversationSummary.summarize(history) do
          {:ok, summary} ->
            snapshot =
              Workspace.put_object_summary(
                socket.assigns.selected_object["kind"],
                socket.assigns.selected_object["id"],
                summary
              )

            {:noreply,
             socket
             |> sync_snapshot(snapshot, selected_object: socket.assigns.selected_object)
             |> put_flash(:info, "Conversation summarized.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "The conversation could not be summarized.")}
        end
    end
  end

  def handle_event("clear_conversation", _params, socket) do
    if socket.assigns.selected_object do
      snapshot =
        Workspace.clear_object_conversation(
          socket.assigns.selected_object["kind"],
          socket.assigns.selected_object["id"]
        )

      {:noreply,
       socket
       |> sync_snapshot(snapshot, selected_object: socket.assigns.selected_object)
       |> put_flash(:info, "Conversation cleared.")}
    else
      {:noreply, put_flash(socket, :error, "Select an object first.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section
        id="tracker-page"
        phx-hook="PreventInitialFocus"
        class={tracker_page_class(@items_panel_hidden)}
      >
        <%= if @items_panel_hidden do %>
          <section
            id="items-panel-rail"
            class="tracker-panel order-1 overflow-hidden rounded-[2rem]"
          >
            <div class="flex h-full flex-col items-center justify-between gap-6 px-3 py-5">
              <button
                id="show-items-panel"
                type="button"
                phx-click="toggle_items_panel"
                class="inline-flex items-center gap-2 rounded-full border border-white/10 bg-slate-950/75 px-3 py-2 text-xs font-medium uppercase tracking-[0.2em] text-slate-200 transition hover:border-emerald-400/40 hover:text-emerald-100"
              >
                <.icon name="hero-chevron-double-right" class="size-4" /> Show
              </button>
              <div class="grid w-full gap-3">
                <div class="rounded-2xl border border-white/10 bg-slate-950/70 px-3 py-3 text-center">
                  <p class="text-[10px] uppercase tracking-[0.22em] text-slate-400">Goals</p>
                  <p class="mt-1 font-heading text-2xl text-slate-50">{@goals_count}</p>
                </div>
                <div class="rounded-2xl border border-white/10 bg-slate-950/70 px-3 py-3 text-center">
                  <p class="text-[10px] uppercase tracking-[0.22em] text-slate-400">Tasks</p>
                  <p class="mt-1 font-heading text-2xl text-slate-50">{@tasks_count}</p>
                </div>
                <div class="rounded-2xl border border-white/10 bg-slate-950/70 px-3 py-3 text-center">
                  <p class="text-[10px] uppercase tracking-[0.22em] text-slate-400">Facts</p>
                  <p class="mt-1 font-heading text-2xl text-slate-50">{@facts_count}</p>
                </div>
              </div>
            </div>
          </section>
        <% else %>
          <section
            id="existing-items-panel"
            class="tracker-panel order-1 overflow-hidden rounded-[2rem]"
          >
            <div class="relative space-y-6 px-5 py-6 sm:px-6">
              <div class="space-y-4">
                <div class="flex items-start justify-between gap-4">
                  <div class="space-y-2">
                    <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Existing items</p>
                    <h2 class="font-heading text-3xl text-slate-50">Current tracker context</h2>
                    <p class="text-sm leading-7 text-slate-300">
                      Pick a goal, task, or fact to focus the conversation. Draft objects stay in the same graph as saved items.
                    </p>
                  </div>
                  <div class="flex flex-wrap items-center justify-end gap-2">
                    <button
                      id="toggle-show-completed"
                      type="button"
                      phx-click="toggle_show_completed"
                      data-value={to_string(@show_completed)}
                      class="inline-flex items-center gap-2 rounded-full border border-white/10 bg-slate-950/75 px-3 py-2 text-xs font-medium uppercase tracking-[0.2em] text-slate-200 transition hover:border-emerald-400/40 hover:text-emerald-100"
                    >
                      <.icon name="hero-eye" class="size-4" />
                      {if(@show_completed, do: "Hide completed", else: "Show completed")}
                    </button>
                    <button
                      id="hide-items-panel"
                      type="button"
                      phx-click="toggle_items_panel"
                      class="inline-flex items-center gap-2 rounded-full border border-white/10 bg-slate-950/75 px-3 py-2 text-xs font-medium uppercase tracking-[0.2em] text-slate-200 transition hover:border-emerald-400/40 hover:text-emerald-100"
                    >
                      <.icon name="hero-chevron-double-left" class="size-4" /> Hide
                    </button>
                  </div>
                </div>

                <div class="grid gap-3 sm:grid-cols-3 xl:grid-cols-1 2xl:grid-cols-3">
                  <div class="rounded-3xl border border-white/10 bg-slate-950/70 px-4 py-4 shadow-[0_18px_38px_rgba(15,23,42,0.08)]">
                    <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Goals</p>
                    <p id="goals-count" class="mt-2 font-heading text-3xl text-slate-50">
                      {@goals_count}
                    </p>
                  </div>
                  <div class="rounded-3xl border border-white/10 bg-slate-950/70 px-4 py-4 shadow-[0_18px_38px_rgba(15,23,42,0.08)]">
                    <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Tasks</p>
                    <p id="tasks-count" class="mt-2 font-heading text-3xl text-slate-50">
                      {@tasks_count}
                    </p>
                  </div>
                  <div class="rounded-3xl border border-white/10 bg-slate-950/70 px-4 py-4 shadow-[0_18px_38px_rgba(15,23,42,0.08)]">
                    <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Facts</p>
                    <p id="facts-count" class="mt-2 font-heading text-3xl text-slate-50">
                      {@facts_count}
                    </p>
                  </div>
                </div>
              </div>

              <div class="space-y-5">
                <div class="rounded-[1.75rem] border border-white/10 bg-slate-950/60 px-4 py-4 shadow-[0_18px_38px_rgba(15,23,42,0.07)]">
                  <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
                    <div class="space-y-2">
                      <h3 class="text-sm font-semibold uppercase tracking-[0.22em] text-slate-400">
                        Hierarchy map
                      </h3>
                      <p class="max-w-2xl text-sm leading-7 text-slate-300">
                        The graph now lives on its own page so you can inspect the full structure without squeezing the tracker.
                      </p>
                    </div>
                    <.link
                      navigate={~p"/graph"}
                      class="inline-flex items-center gap-2 rounded-full border border-white/10 bg-slate-900/80 px-4 py-2 text-xs font-medium uppercase tracking-[0.2em] text-slate-100 transition hover:border-emerald-400/40 hover:text-emerald-100"
                    >
                      <.icon name="hero-share" class="size-4" /> Open dedicated graph
                    </.link>
                  </div>
                </div>

                <div>
                  <div class="mb-3 flex items-center justify-between">
                    <h3 class="text-sm font-semibold uppercase tracking-[0.22em] text-slate-400">
                      Goals
                    </h3>
                    <span class="rounded-full border border-white/10 bg-slate-900/80 px-2.5 py-1 text-xs text-slate-300">
                      {@goals_count}
                    </span>
                  </div>
                  <div
                    id="goals-list"
                    phx-update="stream"
                    phx-hook="GoalsSorter"
                    class="grid gap-3"
                  >
                    <p
                      id="goals-empty-state"
                      class="hidden rounded-2xl border border-dashed border-white/15 bg-slate-950/55 px-4 py-4 text-sm text-slate-400 only:block"
                    >
                      No goals yet.
                    </p>
                    <article
                      :for={{dom_id, goal} <- @streams.goals}
                      id={dom_id}
                      phx-click="select_object"
                      phx-value-kind="goal"
                      phx-value-id={goal["id"]}
                      data-goal-id={goal["id"]}
                      data-selected={to_string(selected?(@selected_object, goal))}
                      draggable="true"
                      class={[
                        "cursor-pointer rounded-[1.5rem] border bg-slate-950/65 px-5 py-5 shadow-[0_16px_34px_rgba(4,12,8,0.22)] transition duration-200 hover:-translate-y-0.5 hover:border-emerald-400 hover:shadow-[0_20px_38px_rgba(16,185,129,0.14)]",
                        "cursor-grab active:cursor-grabbing",
                        selected?(@selected_object, goal) &&
                          "border-emerald-400 ring-4 ring-emerald-500/20",
                        !selected?(@selected_object, goal) && "border-white/10"
                      ]}
                      style={goal_card_style(@goal_depths, goal)}
                    >
                      <div class="flex items-start justify-between gap-3">
                        <div>
                          <h4 class="font-medium text-slate-50">{goal["title"]}</h4>
                        </div>
                        <span class="rounded-full bg-slate-800/80 px-2.5 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-300">
                          {goal["status"] || "draft"}
                        </span>
                      </div>
                      <div class="mt-3 flex flex-wrap gap-2 text-xs uppercase tracking-[0.22em] text-slate-400">
                        <span
                          :if={goal["parent_goal_title"]}
                          class="rounded-full bg-emerald-500/10 px-2.5 py-1 text-emerald-100"
                        >
                          Under {goal["parent_goal_title"]}
                        </span>
                        <span
                          :if={goal["target_date"]}
                          class="rounded-full bg-white/5 px-2.5 py-1"
                        >
                          Target: {goal["target_date"]}
                        </span>
                      </div>
                    </article>
                  </div>
                </div>

                <div>
                  <div class="mb-3 flex items-center justify-between">
                    <h3 class="text-sm font-semibold uppercase tracking-[0.22em] text-slate-400">
                      Tasks
                    </h3>
                    <span class="rounded-full border border-white/10 bg-slate-900/80 px-2.5 py-1 text-xs text-slate-300">
                      {@tasks_count}
                    </span>
                  </div>
                  <div id="tasks-list" phx-update="stream" class="grid gap-3">
                    <p
                      id="tasks-empty-state"
                      class="hidden rounded-2xl border border-dashed border-white/15 bg-slate-950/55 px-4 py-4 text-sm text-slate-400 only:block"
                    >
                      No tasks yet.
                    </p>
                    <article
                      :for={{dom_id, task} <- @streams.tasks}
                      id={dom_id}
                      phx-click="select_object"
                      phx-value-kind="task"
                      phx-value-id={task["id"]}
                      data-selected={to_string(selected?(@selected_object, task))}
                      class={[
                        "cursor-pointer rounded-[1.5rem] border bg-slate-950/65 px-5 py-5 shadow-[0_16px_34px_rgba(4,12,8,0.22)] transition duration-200 hover:-translate-y-0.5 hover:border-emerald-400 hover:shadow-[0_20px_38px_rgba(16,185,129,0.14)]",
                        selected?(@selected_object, task) &&
                          "border-emerald-400 ring-4 ring-emerald-500/20",
                        !selected?(@selected_object, task) && "border-white/10"
                      ]}
                    >
                      <div class="flex items-start justify-between gap-3">
                        <div>
                          <h4 class="font-medium text-slate-50">{task["title"]}</h4>
                        </div>
                        <span class="rounded-full bg-slate-800/80 px-2.5 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-300">
                          {task["status"] || "planned"}
                        </span>
                      </div>
                      <div class="mt-3 flex flex-wrap gap-2 text-xs uppercase tracking-[0.2em] text-slate-400">
                        <span :if={task["due_date"]} class="rounded-full bg-rose-500/10 px-2.5 py-1">
                          Due {task["due_date"]}
                        </span>
                        <span
                          :if={task["priority"]}
                          class="rounded-full bg-emerald-500/10 px-2.5 py-1 text-emerald-200"
                        >
                          {task["priority"]}
                        </span>
                        <span
                          :if={task["parent_goal_title"]}
                          class="rounded-full bg-emerald-500/10 px-2.5 py-1"
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
        <% end %>

        <div
          id="chat-panel"
          class="tracker-panel tracker-grid order-3 overflow-hidden rounded-[2rem]"
        >
          <div class="relative space-y-8 px-5 py-6 sm:px-8 sm:py-8">
            <div class="space-y-2">
              <div class="space-y-2">
                <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Studio chat</p>
                <div class="flex flex-wrap items-start justify-between gap-4">
                  <div class="space-y-2">
                    <h1 class="font-heading text-4xl leading-none text-slate-50 sm:text-5xl">
                      Talk through it
                    </h1>
                    <p class="max-w-2xl text-sm leading-7 text-slate-300 sm:text-base">
                      Shape goals, tasks, and facts in natural language. The active object is updated as the conversation progresses.
                    </p>
                  </div>
                  <.link
                    id="open-graph-page"
                    navigate={~p"/graph"}
                    class="inline-flex items-center gap-2 rounded-full border border-white/10 bg-slate-950/75 px-4 py-2 text-xs font-medium uppercase tracking-[0.2em] text-slate-200 transition hover:border-emerald-400/40 hover:text-emerald-100"
                  >
                    <.icon name="hero-share" class="size-4" /> Open graph page
                  </.link>
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
                    "border-white/10 bg-slate-950/85 text-slate-100",
                  entry["role"] == "user" &&
                    "ml-auto max-w-[90%] border-emerald-400/20 bg-emerald-500 text-[#07110d]"
                ]}
              >
                <div class="mb-2 flex items-center justify-between gap-3 text-xs uppercase tracking-[0.22em]">
                  <span class={[
                    entry["role"] == "assistant" && "text-slate-400",
                    entry["role"] == "user" && "text-emerald-100"
                  ]}>
                    {if(entry["role"] == "assistant", do: "Studio", else: "You")}
                  </span>
                  <span
                    :if={entry["follow_up"]}
                    class="rounded-full bg-amber-500/15 px-2 py-1 text-[10px] text-amber-200"
                  >
                    Needs details
                  </span>
                </div>
                <p class="whitespace-pre-wrap text-sm leading-7">{entry["content"]}</p>
              </article>
            </div>

            <div class="rounded-[1.75rem] border border-white/10 bg-slate-950/70 p-4 shadow-[0_18px_38px_rgba(15,23,42,0.07)]">
              <.form
                for={@form}
                id="chat-composer"
                phx-submit="send_message"
                phx-hook="ClearOnSubmit"
                class="space-y-4"
              >
                <.input
                  field={@form[:message]}
                  type="textarea"
                  rows="4"
                  placeholder="Examples: “I want to launch my portfolio site by June” or “Create a task to send the Q2 planning deck tomorrow.”"
                  aria-label="Chat message"
                  phx-hook="SubmitOnCtrlEnter"
                  data-submit-target="chat-composer"
                  class="min-h-32 w-full rounded-[1.5rem] border border-white/10 bg-slate-950/90 px-4 py-4 text-sm leading-7 text-slate-100 outline-none transition focus:border-emerald-400 focus:ring-4 focus:ring-emerald-500/20"
                  error_class="border-rose-400 ring-4 ring-rose-500/20"
                />

                <div class="flex flex-wrap items-center justify-end gap-3">
                  <button
                    id="send-message"
                    type="submit"
                    phx-disable-with="Thinking..."
                    class="tracker-action inline-flex items-center gap-2 rounded-full bg-emerald-500 px-5 py-3 text-sm font-semibold text-[#07110d]"
                  >
                    <.icon name="hero-paper-airplane" class="size-4" /> Send to studio
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>

        <section
          id="tracker-draft"
          class="tracker-panel order-2 overflow-hidden rounded-[2rem]"
        >
          <div class="relative space-y-5 px-5 py-6 sm:px-6">
            <%= if @selected_object do %>
              <div
                id="selected-object-panel"
                data-selected-id={@selected_object["id"]}
                data-selected-kind={@selected_object["kind"]}
                class="space-y-3"
              >
                <% action = status_action(@selected_object) %>
                <div class="flex flex-wrap items-center gap-2">
                  <span class="rounded-full bg-emerald-500/15 px-3 py-1 text-[10px] uppercase tracking-[0.24em] text-emerald-200">
                    {selected_label(@selected_object)}
                  </span>
                  <span class="rounded-full bg-slate-800/80 px-3 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-200">
                    {humanize_status(@selected_object["status"])}
                  </span>
                  <button
                    :if={action}
                    id="toggle-selected-completion"
                    type="button"
                    phx-click="set_selected_status"
                    phx-value-status={action.status}
                    class="rounded-full border border-white/10 bg-slate-950/70 px-3 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-300 transition hover:border-emerald-400/30 hover:text-emerald-50"
                  >
                    {action.label}
                  </button>
                  <button
                    id="clear-selection"
                    type="button"
                    phx-click="clear_selection"
                    class="rounded-full border border-white/10 bg-slate-950/70 px-3 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-300 transition hover:border-emerald-400/30 hover:text-emerald-50"
                  >
                    Clear focus
                  </button>
                  <button
                    id="summarize-conversation"
                    type="button"
                    phx-click="summarize_conversation"
                    class="rounded-full border border-white/10 bg-slate-950/70 px-3 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-300 transition hover:border-emerald-400/30 hover:text-emerald-50"
                  >
                    Summarize
                  </button>
                  <button
                    id="clear-conversation"
                    type="button"
                    phx-click="clear_conversation"
                    class="rounded-full border border-white/10 bg-slate-950/70 px-3 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-300 transition hover:border-emerald-400/30 hover:text-emerald-50"
                  >
                    Clear convo
                  </button>
                </div>
                <div
                  :if={@selected_object["origin_summary"]}
                  id="selected-object-summary"
                  class="max-w-3xl rounded-[1.5rem] border border-amber-400/20 bg-amber-500/10 px-4 py-3 text-sm leading-7 text-amber-100 shadow-[0_14px_28px_rgba(217,119,6,0.08)]"
                >
                  {@selected_object["origin_summary"]}
                </div>
              </div>
            <% else %>
              <div class="space-y-3">
                <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Selected context</p>
                <h1
                  id="selected-object-title"
                  class="font-heading text-4xl leading-none text-slate-50 sm:text-5xl"
                >
                  Object memory
                </h1>
                <p
                  id="selected-object-empty"
                  class="max-w-2xl text-sm leading-7 text-slate-300 sm:text-base"
                >
                  Select a goal, task, or fact to inspect its details, related project context, and stored facts here.
                </p>
              </div>
            <% end %>

            <div class="flex items-start justify-between gap-4">
              <div>
                <p class="text-xs uppercase tracking-[0.24em] text-slate-400">
                  {memory_heading(@memory_object, @memory_object_active)}
                </p>
                <h2 class="mt-2 font-heading text-3xl text-slate-50">Object memory</h2>
                <p class="mt-2 max-w-sm text-sm leading-7 text-slate-300">
                  Readable memory for the focused object, not raw transport JSON.
                </p>
              </div>
              <%= if @memory_object_active do %>
                <div class="flex gap-2">
                  <button
                    id="save-draft"
                    type="button"
                    phx-click="save_draft"
                    class="tracker-action rounded-full border border-white/10 bg-slate-900/80 px-4 py-2 text-sm font-medium text-slate-100"
                  >
                    Save
                  </button>
                  <button
                    id="clear-draft"
                    type="button"
                    phx-click="clear_draft"
                    class="tracker-action rounded-full border border-white/10 bg-slate-900/80 px-4 py-2 text-sm font-medium text-slate-100"
                  >
                    Clear
                  </button>
                </div>
              <% else %>
                <p
                  id="memory-selected-note"
                  class="max-w-[13rem] rounded-2xl border border-white/10 bg-slate-950/70 px-3 py-2 text-xs leading-6 text-slate-400"
                >
                  You’re viewing this object for context. Save and Clear only affect the active draft.
                </p>
              <% end %>
            </div>

            <div
              :if={show_project_context?(@selected_object, @goals)}
              id="project-context"
              class="rounded-[1.5rem] border border-white/10 bg-slate-950/65 p-4 shadow-[0_18px_38px_rgba(15,23,42,0.07)]"
            >
              <% goal = project_context(@selected_object, @goals) %>
              <div class="space-y-3">
                <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Project details</p>
                <h3 class="font-heading text-3xl leading-tight text-slate-50">{goal["title"]}</h3>
                <p
                  :if={goal["success_criteria"] || goal["details"] || goal["summary"]}
                  class="text-sm leading-7 text-slate-300"
                >
                  {goal["success_criteria"] || goal["details"] || goal["summary"]}
                </p>
                <div class="flex flex-wrap gap-2">
                  <span
                    :if={goal["target_date"]}
                    class="rounded-full bg-emerald-500/10 px-3 py-1 text-[11px] uppercase tracking-[0.18em] text-emerald-200"
                  >
                    Target: {goal["target_date"]}
                  </span>
                  <span class="rounded-full bg-slate-900/80 px-3 py-1 text-[11px] uppercase tracking-[0.18em] text-slate-300">
                    {humanize_status(goal["status"])}
                  </span>
                </div>
              </div>
            </div>

            <% related_tasks = selected_goal_tasks(@visible_tasks, @goals, @selected_object) %>
            <div
              :if={related_tasks != []}
              id="related-tasks"
              class="space-y-3"
            >
              <div class="flex items-center justify-between gap-3">
                <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Linked tasks</p>
                <span
                  id="related-tasks-count"
                  class="rounded-full border border-white/10 bg-slate-900/80 px-2.5 py-1 text-xs text-slate-300"
                >
                  {length(related_tasks)}
                </span>
              </div>
              <div class="grid gap-3">
                <article
                  :for={task_item <- related_tasks}
                  id={"related-task-#{task_item["id"]}"}
                  phx-click="select_object"
                  phx-value-kind="task"
                  phx-value-id={task_item["id"]}
                  class="cursor-pointer rounded-[1.5rem] border border-white/10 bg-slate-950/65 px-4 py-4 shadow-[0_16px_34px_rgba(4,12,8,0.22)] transition duration-200 hover:-translate-y-0.5 hover:border-emerald-400 hover:shadow-[0_20px_38px_rgba(16,185,129,0.14)]"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="space-y-1">
                      <h4 class="font-medium text-slate-50">{task_item["title"]}</h4>
                      <p
                        :if={task_item["details"] || task_item["summary"]}
                        class="text-sm leading-6 text-slate-300"
                      >
                        {task_item["details"] || task_item["summary"]}
                      </p>
                    </div>
                    <span class="rounded-full bg-slate-800/80 px-2.5 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-300">
                      {task_item["status"] || "planned"}
                    </span>
                  </div>
                  <div class="mt-3 flex flex-wrap gap-2 text-xs uppercase tracking-[0.2em] text-slate-400">
                    <span
                      :if={task_item["due_date"]}
                      class="rounded-full bg-rose-500/10 px-2.5 py-1"
                    >
                      Due {task_item["due_date"]}
                    </span>
                    <span
                      :if={task_item["priority"]}
                      class="rounded-full bg-emerald-500/10 px-2.5 py-1 text-emerald-200"
                    >
                      {task_item["priority"]}
                    </span>
                  </div>
                </article>
              </div>
            </div>

            <div class="rounded-[1.5rem] border border-white/10 bg-slate-950/65 p-4 shadow-[0_18px_38px_rgba(15,23,42,0.07)]">
              <div class="mb-4 flex flex-wrap items-center justify-between gap-3">
                <span
                  id="current-draft-kind"
                  data-value={(@memory_object && @memory_object["kind"]) || "none"}
                  class="rounded-full bg-emerald-500/15 px-3 py-1 text-[10px] uppercase tracking-[0.24em] text-emerald-100"
                >
                  {if(@memory_object, do: @memory_object["kind"], else: "No draft")}
                </span>
                <span
                  id="draft-ready-flag"
                  data-value={if(@memory_completion.ready?, do: "ready", else: "incomplete")}
                  class={[
                    "rounded-full px-3 py-1 text-[10px] uppercase tracking-[0.24em]",
                    @memory_completion.ready? &&
                      "bg-emerald-500/15 text-emerald-200",
                    !@memory_completion.ready? &&
                      "bg-amber-500/15 text-amber-100"
                  ]}
                >
                  {if(@memory_completion.ready?, do: "Ready", else: "Needs work")}
                </span>
              </div>

              <%= if @memory_object do %>
                <div class="space-y-4">
                  <div class="space-y-3">
                    <h3 id="draft-title" class="font-heading text-3xl leading-tight text-slate-50">
                      {@memory_object["title"] || "Untitled draft"}
                    </h3>
                    <p
                      :if={draft_lead(@memory_object)}
                      id="draft-description"
                      class="text-sm leading-7 text-slate-300"
                    >
                      {draft_lead(@memory_object)}
                    </p>
                    <div
                      :if={draft_fact_pills(@memory_object, @facts, @goals) != []}
                      id="draft-facts"
                      class="flex flex-wrap gap-2"
                    >
                      <span
                        :for={fact <- draft_fact_pills(@memory_object, @facts, @goals)}
                        class="rounded-full border border-white/10 bg-slate-900/80 px-3 py-1 text-[11px] uppercase tracking-[0.18em] text-slate-300"
                      >
                        {fact}
                      </span>
                    </div>
                  </div>

                  <div :if={draft_memory_rows(@memory_object) != []} class="space-y-3">
                    <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Known details</p>
                    <dl id="draft-memory-rows" class="grid gap-3">
                      <div
                        :for={{label, value} <- draft_memory_rows(@memory_object)}
                        class="rounded-2xl border border-white/10 bg-slate-900/75 px-4 py-3"
                      >
                        <dt class="text-[11px] uppercase tracking-[0.22em] text-slate-400">
                          {label}
                        </dt>
                        <dd class="mt-1 text-sm leading-7 text-slate-100">{value}</dd>
                      </div>
                    </dl>
                  </div>
                </div>
              <% else %>
                <div
                  id="draft-empty-state"
                  class="rounded-[1.5rem] border border-dashed border-white/15 bg-slate-900/65 px-4 py-5 text-sm leading-7 text-slate-300"
                >
                  {draft_empty_message(@draft)}
                </div>
              <% end %>
            </div>

            <div :if={@memory_object && @memory_completion.missing != []} class="space-y-2">
              <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Missing details</p>
              <ul id="draft-missing" class="space-y-2">
                <li
                  :for={item <- @memory_completion.missing}
                  class="rounded-2xl border border-amber-400/20 bg-amber-500/10 px-3 py-3 text-sm text-amber-100"
                >
                  {item}
                </li>
              </ul>
            </div>

            <div
              :if={selected_project_facts(@facts, @selected_object) != []}
              id="related-facts"
              class="space-y-3"
            >
              <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Project facts</p>
              <div class="grid gap-3">
                <article
                  :for={fact_item <- selected_project_facts(@facts, @selected_object)}
                  class="rounded-[1.5rem] border border-white/10 bg-slate-950/65 px-4 py-4 shadow-[0_16px_34px_rgba(4,12,8,0.22)]"
                >
                  <div class="flex items-start justify-between gap-3">
                    <div>
                      <h4 class="font-medium text-slate-50">{fact_item["title"]}</h4>
                      <p :if={fact_item["details"]} class="mt-1 text-sm leading-6 text-slate-300">
                        {fact_item["details"]}
                      </p>
                    </div>
                    <span class="rounded-full bg-slate-800/80 px-2.5 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-300">
                      {fact_item["status"] || "known"}
                    </span>
                  </div>
                </article>
              </div>
            </div>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  defp assign_snapshot(socket, snapshot) do
    selection_mode = socket.assigns[:selection_mode] || :auto
    show_completed = socket.assigns[:show_completed] || false
    visible_items = Hierarchy.visible_items(snapshot["goals"], snapshot["tasks"], show_completed)
    goal_depths = Hierarchy.goal_depths(visible_items.goals)

    selected_object =
      resolve_selected_object(snapshot, socket.assigns[:selected_object], selection_mode)
      |> maybe_hide_selected_object(snapshot, show_completed)

    memory_object = resolve_memory_object(snapshot, selected_object, selection_mode)

    assign(socket,
      goals: snapshot["goals"],
      tasks: snapshot["tasks"],
      facts: snapshot["facts"],
      visible_goals: visible_items.goals,
      visible_tasks: visible_items.tasks,
      goal_depths: goal_depths,
      draft: snapshot["active_draft"],
      draft_completion: Draft.completion(snapshot["active_draft"]),
      memory_object: memory_object,
      memory_completion: Draft.completion(memory_object),
      memory_object_active: same_object?(memory_object, snapshot["active_draft"]),
      goals_count: length(visible_items.goals),
      tasks_count: length(visible_items.tasks),
      facts_count: length(snapshot["facts"]),
      show_completed: show_completed,
      selection_mode: selection_mode,
      selected_object: selected_object
    )
  end

  defp sync_snapshot(socket, snapshot, opts \\ []) do
    socket =
      socket
      |> maybe_assign_selected_object(opts)
      |> maybe_assign_selection_mode(opts)

    socket
    |> assign_snapshot(snapshot)
    |> refresh_item_streams()
    |> sync_chat_from_selection()
  end

  defp refresh_item_streams(socket) do
    socket
    |> stream(:goals, socket.assigns.visible_goals, reset: true)
    |> stream(:tasks, socket.assigns.visible_tasks, reset: true)
    |> stream(:facts, socket.assigns.facts, reset: true)
  end

  defp sync_chat_from_selection(socket) do
    history = selected_history(socket.assigns.selected_object)
    messages = history_messages(history)

    socket
    |> assign(:history, history)
    |> assign(:message_counter, max(length(messages), 1))
    |> stream(:messages, messages, reset: true)
  end

  defp empty_form do
    to_form(%{"message" => ""}, as: :chat)
  end

  defp maybe_assign_selected_object(socket, opts) do
    case Keyword.fetch(opts, :selected_object) do
      {:ok, selected_object} -> assign(socket, :selected_object, selected_object)
      :error -> socket
    end
  end

  defp maybe_assign_selection_mode(socket, opts) do
    case Keyword.fetch(opts, :selection_mode) do
      {:ok, selection_mode} ->
        assign(socket, :selection_mode, selection_mode)

      :error ->
        case Keyword.fetch(opts, :selected_object) do
          {:ok, nil} -> assign(socket, :selection_mode, :cleared)
          {:ok, _selected_object} -> assign(socket, :selection_mode, :manual)
          :error -> socket
        end
    end
  end

  defp resolve_selected_object(snapshot, _selected_object, :auto), do: snapshot["active_draft"]
  defp resolve_selected_object(_snapshot, nil, :cleared), do: nil
  defp resolve_selected_object(_snapshot, nil, _selection_mode), do: nil

  defp resolve_selected_object(snapshot, selected_object, _selection_mode) do
    candidates = snapshot["goals"] ++ snapshot["tasks"] ++ snapshot["facts"]

    Enum.find(candidates, &same_object?(&1, selected_object))
  end

  defp resolve_memory_object(snapshot, nil, :auto), do: snapshot["active_draft"]
  defp resolve_memory_object(_snapshot, nil, _selection_mode), do: nil
  defp resolve_memory_object(_snapshot, selected_object, _selection_mode), do: selected_object

  defp same_object?(candidate, selected_object) do
    if is_nil(candidate) or is_nil(selected_object) do
      false
    else
      candidate["kind"] == selected_object["kind"] and
        (candidate["id"] == selected_object["id"] or
           candidate["title"] == selected_object["title"])
    end
  end

  defp find_object(goals, tasks, facts, kind, id) do
    Enum.find(goals ++ tasks ++ facts, fn item ->
      item["kind"] == kind and item["id"] == id
    end)
  end

  defp selected?(nil, _item), do: false

  defp selected?(selected_object, item) do
    selected_object["kind"] == item["kind"] and selected_object["id"] == item["id"]
  end

  defp drafting_object?(%{"status" => "being_drafted"}), do: true
  defp drafting_object?(_item), do: false

  defp status_action(%{"kind" => "goal", "status" => "being_drafted"}) do
    %{label: "Achieve and save", status: "achieved"}
  end

  defp status_action(%{"kind" => "goal", "status" => "achieved", "id" => id})
       when id != "draft-current" do
    %{label: "Restore goal", status: "draft"}
  end

  defp status_action(%{"kind" => "goal", "id" => id}) when id != "draft-current" do
    %{label: "Mark achieved", status: "achieved"}
  end

  defp status_action(%{"kind" => "task", "status" => "being_drafted"}) do
    %{label: "Complete and save", status: "completed"}
  end

  defp status_action(%{"kind" => "task", "status" => "completed", "id" => id})
       when id != "draft-current" do
    %{label: "Restore task", status: "planned"}
  end

  defp status_action(%{"kind" => "task", "id" => id}) when id != "draft-current" do
    %{label: "Mark completed", status: "completed"}
  end

  defp status_action(_item), do: nil

  defp selected_label(%{"kind" => "goal"}), do: "Selected goal"
  defp selected_label(%{"kind" => "task"}), do: "Selected task"
  defp selected_label(%{"kind" => "fact"}), do: "Selected fact"
  defp selected_label(_item), do: "Selected item"

  defp tracker_page_class(true) do
    "grid gap-6 xl:grid-cols-[4.75rem_minmax(26rem,1.42fr)_minmax(0,1.18fr)] 2xl:grid-cols-[5rem_minmax(32rem,1.54fr)_minmax(24rem,1.14fr)]"
  end

  defp tracker_page_class(false) do
    "grid gap-6 xl:grid-cols-[minmax(20rem,0.94fr)_minmax(24rem,1.38fr)_minmax(0,1.18fr)] 2xl:grid-cols-[minmax(22rem,0.94fr)_minmax(30rem,1.52fr)_minmax(24rem,1.14fr)]"
  end

  defp memory_heading(nil, _memory_object_active), do: "No focus"
  defp memory_heading(_item, true), do: "Being drafted"
  defp memory_heading(_item, false), do: "Selected object"

  defp draft_fact_pills(item, facts, goals) do
    [
      fact("Status", humanize_status(item["status"])),
      fact("Target", item["target_date"]),
      fact("Due", item["due_date"]),
      fact("Priority", item["priority"]),
      fact("Parent", item["parent_goal_title"]),
      fact("Project", item["project_title"]),
      fact("Linked facts", project_fact_count(facts, item, goals))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp draft_memory_rows(item) do
    [
      {"Summary", item["summary"]},
      {"Details", item["details"]},
      {"Success criteria", item["success_criteria"]}
    ]
    |> Enum.reject(fn {_label, value} -> blank_value?(value) end)
  end

  defp fact(_label, nil), do: nil
  defp fact(label, value), do: "#{label}: #{value}"

  defp draft_lead(item) do
    item["summary"] || item["details"] || item["success_criteria"]
  end

  defp draft_empty_message(nil) do
    "No object is being drafted right now. Start from chat or select a graph item to inspect it."
  end

  defp draft_empty_message(_draft) do
    "No object is focused right now. The active draft still exists on the graph, but it is not pinned here."
  end

  defp blank_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_value?(nil), do: true
  defp blank_value?(_value), do: false

  defp humanize_status(nil), do: "Unknown"

  defp humanize_status(status) do
    status
    |> String.replace("_", " ")
  end

  defp history_entries(user_message, assistant_message, follow_up) do
    [
      %{"role" => "user", "content" => user_message, "follow_up" => false},
      %{"role" => "assistant", "content" => assistant_message, "follow_up" => follow_up}
    ]
  end

  defp trim_history(history) do
    Enum.take(history, -10)
  end

  defp project_context(nil, _goals), do: nil

  defp project_context(%{"kind" => "goal"} = item, goals) do
    Hierarchy.parent_goal(item, goals)
  end

  defp project_context(%{"parent_goal_title" => _title} = item, goals) do
    Hierarchy.parent_goal(item, goals)
  end

  defp project_context(%{"project_title" => title}, goals) when is_binary(title) do
    Enum.find(goals, &(&1["title"] == title))
  end

  defp project_context(_item, _goals), do: nil

  defp show_project_context?(%{"kind" => "goal"} = selected_object, goals) do
    project_context(selected_object, goals) != nil
  end

  defp show_project_context?(selected_object, goals) do
    project_context(selected_object, goals) != nil
  end

  defp selected_project_facts(_facts, nil), do: []

  defp selected_project_facts(facts, %{"kind" => "goal", "title" => title}) do
    Enum.filter(facts, &(&1["project_title"] == title))
  end

  defp selected_project_facts(_facts, _selected_object), do: []

  defp selected_goal_tasks(_tasks, _goals, nil), do: []

  defp selected_goal_tasks(tasks, goals, %{"kind" => "goal", "id" => goal_id})
       when is_list(tasks) and is_list(goals) do
    Enum.filter(tasks, fn task ->
      case Hierarchy.parent_goal(task, goals) do
        %{"id" => ^goal_id} -> true
        _ -> false
      end
    end)
  end

  defp selected_goal_tasks(_tasks, _goals, _selected_object), do: []

  defp project_fact_count(facts, item, goals) do
    cond do
      item["kind"] == "goal" and is_binary(item["title"]) ->
        Enum.count(facts, &(&1["project_title"] == item["title"]))

      true ->
        case project_context(item, goals) do
          %{"title" => title} -> Enum.count(facts, &(&1["project_title"] == title))
          _ -> nil
        end
    end
  end

  defp selected_history(nil), do: []

  defp selected_history(selected_object) do
    selected_object["origin_conversation"] || []
  end

  defp history_messages([]) do
    [message("assistant", @welcome_message, 1, false)]
  end

  defp history_messages(history) do
    Enum.with_index(history, 1)
    |> Enum.map(fn {entry, index} ->
      message(entry["role"], entry["content"], index, entry["follow_up"] || false)
    end)
  end

  defp persist_origin_conversation(snapshot, actions, selected_object, selection_mode, history) do
    case conversation_target(snapshot, actions, selected_object) do
      nil ->
        {snapshot, selected_object, selection_mode}

      target ->
        updated_snapshot =
          Workspace.put_object_conversation(target["kind"], target["id"], history)

        resolved_target =
          find_object(
            updated_snapshot["goals"],
            updated_snapshot["tasks"],
            updated_snapshot["facts"],
            target["kind"],
            target["id"]
          )

        if selection_mode == :cleared do
          {updated_snapshot, nil, :cleared}
        else
          {updated_snapshot, resolved_target, :manual}
        end
    end
  end

  defp conversation_target(snapshot, actions, selected_object) do
    cond do
      snapshot["active_draft"] != nil ->
        snapshot["active_draft"]

      save_requested?(actions) ->
        latest_saved_object(snapshot, conversation_kind(actions, selected_object))

      selected_object ->
        find_object(
          snapshot["goals"],
          snapshot["tasks"],
          snapshot["facts"],
          selected_object["kind"],
          selected_object["id"]
        )

      true ->
        nil
    end
  end

  defp conversation_kind(_actions, %{"kind" => kind}) when kind in ["goal", "task", "fact"],
    do: kind

  defp conversation_kind(actions, _selected_object) do
    Enum.reduce(actions, nil, fn action, acc ->
      case action["kind"] do
        kind when kind in ["goal", "task", "fact"] -> kind
        _ -> acc
      end
    end)
  end

  defp latest_saved_object(snapshot, "goal") do
    Enum.find(snapshot["goals"], &(&1["status"] != "being_drafted"))
  end

  defp latest_saved_object(snapshot, "task") do
    Enum.find(snapshot["tasks"], &(&1["status"] != "being_drafted"))
  end

  defp latest_saved_object(snapshot, "fact") do
    Enum.find(snapshot["facts"], &(&1["status"] != "being_drafted"))
  end

  defp latest_saved_object(_snapshot, _kind), do: nil

  defp maybe_hide_selected_object(nil, _snapshot, _show_completed), do: nil

  defp maybe_hide_selected_object(selected_object, snapshot, show_completed) do
    if selected_object_visible?(selected_object, snapshot, show_completed) do
      selected_object
    else
      nil
    end
  end

  defp selected_object_visible?(nil, _snapshot, _show_completed), do: false

  defp selected_object_visible?(selected_object, snapshot, show_completed) do
    Hierarchy.visible?(selected_object, snapshot["goals"], snapshot["tasks"], show_completed)
  end

  defp status_flash_message("goal", "achieved"), do: "Goal marked as achieved."
  defp status_flash_message("goal", "draft"), do: "Goal restored."
  defp status_flash_message("task", "completed"), do: "Task marked as completed."
  defp status_flash_message("task", "planned"), do: "Task restored."
  defp status_flash_message(_kind, _status), do: "Status updated."

  defp save_requested?(actions) do
    Enum.any?(actions, &(Map.get(&1, "tool") == "save_draft"))
  end

  defp maybe_activate_selected_draft(selected_object) do
    if drafting_object?(selected_object) do
      Workspace.activate_draft(selected_object["kind"], selected_object["id"])
    else
      Workspace.snapshot()
    end
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
    "Model config was not found at #{path}. Add your local JSON config and try again."
  end

  defp error_message({:missing_field, field}) do
    "Model config is missing the #{field} field."
  end

  defp error_message({:gemini_request_failed, _status, _body}) do
    "The model provider rejected the request. Check the configured model name and API key."
  end

  defp error_message({:openrouter_request_failed, _status, _body}) do
    "The model provider rejected the request. Check the configured model name and API key."
  end

  defp error_message({:gemini_transport_error, _reason}) do
    "The model provider could not be reached."
  end

  defp error_message({:openrouter_transport_error, _reason}) do
    "The model provider could not be reached."
  end

  defp error_message(_reason) do
    "The assistant could not complete that turn."
  end

  defp goal_card_style(goal_depths, goal) do
    depth = Map.get(goal_depths, goal["id"], 0)
    "padding-left: calc(1.25rem + #{depth * 1.15}rem);"
  end
end
