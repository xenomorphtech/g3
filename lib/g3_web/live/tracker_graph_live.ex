defmodule G3Web.TrackerGraphLive do
  use G3Web, :live_view

  alias G3.Tracker.Hierarchy
  alias G3.Tracker.Workspace

  @impl true
  def mount(_params, _session, socket) do
    snapshot = Workspace.snapshot()

    {:ok,
     socket
     |> assign(:page_title, "Goal Graph")
     |> assign(:show_completed, false)
     |> assign_snapshot(snapshot, :auto)}
  end

  @impl true
  def handle_event("select_object", %{"id" => id, "kind" => kind}, socket) do
    snapshot = Workspace.snapshot()
    selected_object = find_object(snapshot, kind, id)

    {:noreply, assign_snapshot(socket, snapshot, selected_object)}
  end

  def handle_event("refresh_graph", _params, socket) do
    snapshot = Workspace.snapshot()

    {:noreply, assign_snapshot(socket, snapshot, socket.assigns.selected_object)}
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
     |> assign_snapshot(snapshot, selected_object)}
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
             |> assign_snapshot(snapshot, resolved_selected_object)
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
            find_object(snapshot, kind, id)
          else
            nil
          end

        {:noreply,
         socket
         |> assign_snapshot(snapshot, resolved_selected_object)
         |> put_flash(:info, status_flash_message(kind, status))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="tracker-graph-page" class="mx-auto max-w-7xl px-4 py-6 sm:px-6 lg:px-8">
        <div class="space-y-6">
          <div class="tracker-panel rounded-[2rem] px-6 py-6 sm:px-8">
            <div class="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
              <div class="space-y-3">
                <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Dedicated graph</p>
                <h1 class="font-heading text-4xl text-slate-50 sm:text-5xl">Goal relationship map</h1>
                <p class="max-w-3xl text-sm leading-7 text-slate-300 sm:text-base">
                  Browse the goal and task hierarchy on its own page so the full structure stays readable.
                </p>
              </div>

              <div class="flex flex-wrap items-center gap-3">
                <button
                  id="refresh-graph"
                  type="button"
                  phx-click="refresh_graph"
                  class="rounded-full border border-white/10 bg-slate-950/75 px-4 py-2 text-xs font-medium uppercase tracking-[0.2em] text-slate-200 transition hover:border-emerald-400/40 hover:text-emerald-100"
                >
                  Refresh
                </button>
                <button
                  id="toggle-show-completed-graph"
                  type="button"
                  phx-click="toggle_show_completed"
                  data-value={to_string(@show_completed)}
                  class="rounded-full border border-white/10 bg-slate-950/75 px-4 py-2 text-xs font-medium uppercase tracking-[0.2em] text-slate-200 transition hover:border-emerald-400/40 hover:text-emerald-100"
                >
                  {if(@show_completed, do: "Hide completed", else: "Show completed")}
                </button>
                <.link
                  id="back-to-tracker"
                  navigate={~p"/"}
                  class="tracker-action inline-flex items-center gap-2 rounded-full bg-emerald-500 px-5 py-3 text-sm font-semibold text-[#07110d]"
                >
                  <.icon name="hero-arrow-left" class="size-4" /> Back to tracker
                </.link>
              </div>
            </div>

            <div class="mt-6 grid gap-3 sm:grid-cols-3">
              <div class="rounded-3xl border border-white/10 bg-slate-950/70 px-4 py-4 shadow-[0_18px_38px_rgba(15,23,42,0.08)]">
                <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Goals</p>
                <p id="graph-goals-count" class="mt-2 font-heading text-3xl text-slate-50">
                  {@goals_count}
                </p>
              </div>
              <div class="rounded-3xl border border-white/10 bg-slate-950/70 px-4 py-4 shadow-[0_18px_38px_rgba(15,23,42,0.08)]">
                <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Tasks</p>
                <p id="graph-tasks-count" class="mt-2 font-heading text-3xl text-slate-50">
                  {@tasks_count}
                </p>
              </div>
              <div class="rounded-3xl border border-white/10 bg-slate-950/70 px-4 py-4 shadow-[0_18px_38px_rgba(15,23,42,0.08)]">
                <p class="text-xs uppercase tracking-[0.24em] text-slate-400">Connections</p>
                <p id="graph-edges-count" class="mt-2 font-heading text-3xl text-slate-50">
                  {@edges_count}
                </p>
              </div>
            </div>
          </div>

          <div class="tracker-panel rounded-[2rem] px-5 py-5 sm:px-6 sm:py-6">
            <G3Web.TrackerGraph.graph
              graph={@hierarchy_graph}
              selected_object={@selected_object}
            />
          </div>

          <%= if @selected_object do %>
            <section
              id="graph-selected-panel"
              data-selected-id={@selected_object["id"]}
              data-selected-kind={@selected_object["kind"]}
              class="tracker-panel rounded-[2rem] px-6 py-6 sm:px-8"
            >
              <% action = status_action(@selected_object) %>
              <div class="space-y-4">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="rounded-full bg-emerald-500/15 px-3 py-1 text-[10px] uppercase tracking-[0.24em] text-emerald-200">
                    {selected_kind_label(@selected_object)}
                  </span>
                  <span class="rounded-full bg-slate-800/80 px-3 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-200">
                    {humanize_status(@selected_object["status"])}
                  </span>
                  <button
                    :if={action}
                    id="toggle-graph-selected-completion"
                    type="button"
                    phx-click="set_selected_status"
                    phx-value-status={action.status}
                    class="rounded-full border border-white/10 bg-slate-950/70 px-3 py-1 text-[10px] uppercase tracking-[0.24em] text-slate-300 transition hover:border-emerald-400/30 hover:text-emerald-50"
                  >
                    {action.label}
                  </button>
                </div>

                <div class="space-y-3">
                  <h2
                    id="graph-selected-title"
                    class="font-heading text-3xl leading-tight text-slate-50"
                  >
                    {@selected_object["title"] || "Untitled"}
                  </h2>
                  <p
                    :if={selected_summary(@selected_object)}
                    id="graph-selected-summary"
                    class="max-w-3xl text-sm leading-7 text-slate-300"
                  >
                    {selected_summary(@selected_object)}
                  </p>
                </div>

                <dl
                  :if={selected_detail_rows(@selected_object) != []}
                  id="graph-selected-details"
                  class="grid gap-3 sm:grid-cols-2"
                >
                  <div
                    :for={{label, value} <- selected_detail_rows(@selected_object)}
                    class="rounded-2xl border border-white/10 bg-slate-950/65 px-4 py-3"
                  >
                    <dt class="text-[11px] uppercase tracking-[0.22em] text-slate-400">{label}</dt>
                    <dd class="mt-1 text-sm leading-7 text-slate-100">{value}</dd>
                  </div>
                </dl>
              </div>
            </section>
          <% else %>
            <section
              id="graph-selected-empty"
              class="tracker-panel rounded-[2rem] border border-dashed border-white/10 px-6 py-6 text-sm leading-7 text-slate-300"
            >
              Select a node to inspect its details here.
            </section>
          <% end %>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp assign_snapshot(socket, snapshot, selected_object) do
    show_completed = socket.assigns[:show_completed] || false
    visible_items = Hierarchy.visible_items(snapshot["goals"], snapshot["tasks"], show_completed)
    hierarchy_graph = Hierarchy.graph(visible_items.goals, visible_items.tasks)

    selected_object =
      resolve_selected_object(snapshot, selected_object)
      |> maybe_hide_selected_object(snapshot, show_completed)

    assign(socket,
      hierarchy_graph: hierarchy_graph,
      goals_count: length(visible_items.goals),
      tasks_count: length(visible_items.tasks),
      edges_count: length(hierarchy_graph.edges),
      show_completed: show_completed,
      selected_object: selected_object
    )
  end

  defp resolve_selected_object(snapshot, :auto), do: snapshot["active_draft"]
  defp resolve_selected_object(_snapshot, nil), do: nil

  defp resolve_selected_object(snapshot, %{"kind" => kind, "id" => id}) do
    find_object(snapshot, kind, id)
  end

  defp resolve_selected_object(_snapshot, _selected_object), do: nil

  defp find_object(snapshot, kind, id) do
    Enum.find(snapshot["goals"] ++ snapshot["tasks"] ++ snapshot["facts"], fn item ->
      item["kind"] == kind and item["id"] == id
    end)
  end

  defp selected_kind_label(%{"kind" => "goal", "parent_goal_title" => title})
       when is_binary(title),
       do: "Subgoal"

  defp selected_kind_label(%{"kind" => "goal"}), do: "Goal"
  defp selected_kind_label(%{"kind" => "task"}), do: "Task"
  defp selected_kind_label(%{"kind" => "fact"}), do: "Fact"
  defp selected_kind_label(_item), do: "Item"

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

  defp selected_summary(%{"kind" => "goal"} = item) do
    item["success_criteria"] || item["details"] || item["summary"]
  end

  defp selected_summary(item) do
    item["details"] || item["summary"]
  end

  defp selected_detail_rows(%{"kind" => "goal"} = item) do
    [
      {"Target date", item["target_date"]},
      {"Parent goal", item["parent_goal_title"]}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
  end

  defp selected_detail_rows(%{"kind" => "task"} = item) do
    [
      {"Due date", item["due_date"]},
      {"Priority", item["priority"]},
      {"Parent goal", item["parent_goal_title"]}
    ]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
  end

  defp selected_detail_rows(%{"kind" => "fact"} = item) do
    [{"Project", item["project_title"]}]
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
  end

  defp selected_detail_rows(_item), do: []

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

  defp humanize_status(nil), do: "Unknown"

  defp humanize_status(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_flash_message("goal", "achieved"), do: "Goal marked as achieved."
  defp status_flash_message("goal", "draft"), do: "Goal restored."
  defp status_flash_message("task", "completed"), do: "Task marked as completed."
  defp status_flash_message("task", "planned"), do: "Task restored."
  defp status_flash_message(_kind, _status), do: "Status updated."
end
