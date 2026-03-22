defmodule G3Web.TrackerGraph do
  use G3Web, :html

  attr :graph, :map, required: true
  attr :selected_object, :map, default: nil

  def graph(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between gap-3">
        <div>
          <h3 class="text-sm font-semibold uppercase tracking-[0.22em] text-slate-400">
            Hierarchy map
          </h3>
          <p class="mt-1 max-w-xl text-sm leading-6 text-slate-300">
            Goals, subgoals, and tasks render as one relationship map so the full structure stays visible.
          </p>
        </div>
        <div class="flex flex-wrap gap-2 text-[10px] uppercase tracking-[0.22em] text-slate-400">
          <span class="rounded-full border border-emerald-400/30 bg-emerald-500/10 px-2.5 py-1 text-emerald-100">
            Goal
          </span>
          <span class="rounded-full border border-sky-400/30 bg-sky-500/10 px-2.5 py-1 text-sky-100">
            Task
          </span>
        </div>
      </div>

      <div
        id="goals-graph"
        class="overflow-x-auto rounded-[1.75rem] border border-white/10 bg-[radial-gradient(circle_at_top_left,rgba(16,185,129,0.18),transparent_34%),linear-gradient(180deg,rgba(2,6,23,0.74),rgba(15,23,42,0.86))] p-3 shadow-[0_22px_48px_rgba(2,6,23,0.32)]"
      >
        <%= if @graph.nodes == [] do %>
          <div
            id="goals-graph-empty-state"
            class="flex min-h-56 items-center justify-center rounded-[1.4rem] border border-dashed border-white/10 bg-slate-950/35 px-6 text-center text-sm leading-7 text-slate-300"
          >
            Goals and tasks will appear here once you start drafting them.
          </div>
        <% else %>
          <div
            class="relative rounded-[1.4rem] border border-white/8 bg-slate-950/30"
            style={graph_canvas_style(@graph)}
          >
            <svg
              id="goals-graph-edges"
              class="absolute inset-0"
              viewBox={"0 0 #{@graph.width} #{@graph.height}"}
              width={@graph.width}
              height={@graph.height}
              aria-hidden="true"
            >
              <path
                :for={edge <- @graph.edges}
                id={"graph-edge-#{edge.id}"}
                d={edge.path}
                class={graph_edge_class(edge)}
              />
            </svg>

            <button
              :for={node <- @graph.nodes}
              id={"graph-#{node.item["kind"]}-#{node.item["id"]}"}
              type="button"
              phx-click="select_object"
              phx-value-kind={node.item["kind"]}
              phx-value-id={node.item["id"]}
              data-selected={to_string(selected?(@selected_object, node.item))}
              class={graph_node_class(node, @selected_object)}
              style={graph_node_style(node)}
            >
              <div class="min-w-0">
                <h4 class="line-clamp-2 text-left text-sm font-semibold leading-6 text-slate-50">
                  {node.item["title"] || "Untitled"}
                </h4>
              </div>
              <div
                :if={graph_node_pills(node.item) != []}
                class="mt-3 flex flex-wrap gap-2 text-[10px] uppercase tracking-[0.2em] text-slate-300"
              >
                <span
                  :for={pill <- graph_node_pills(node.item)}
                  class="rounded-full border border-white/10 bg-white/5 px-2.5 py-1"
                >
                  {pill}
                </span>
              </div>
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp same_object?(candidate, selected_object) do
    candidate &&
      selected_object &&
      candidate["kind"] == selected_object["kind"] &&
      candidate["id"] == selected_object["id"]
  end

  defp selected?(nil, _item), do: false
  defp selected?(selected_object, item), do: same_object?(item, selected_object)

  defp graph_canvas_style(graph) do
    "width: #{graph.width}px; height: #{graph.height}px; min-width: 100%;"
  end

  defp graph_node_style(node) do
    "left: #{node.x}px; top: #{node.y}px; width: #{node.width}px; height: #{node.height}px;"
  end

  defp graph_node_class(node, selected_object) do
    [
      "absolute rounded-[1.35rem] border p-4 text-left shadow-[0_20px_42px_rgba(2,6,23,0.26)] transition duration-200 hover:-translate-y-0.5 hover:shadow-[0_24px_48px_rgba(15,23,42,0.34)]",
      node.kind == :goal &&
        "border-emerald-400/30 bg-[linear-gradient(180deg,rgba(2,6,23,0.94),rgba(6,78,59,0.54))]",
      node.kind == :task &&
        "border-sky-400/30 bg-[linear-gradient(180deg,rgba(2,6,23,0.94),rgba(14,116,144,0.44))]",
      selected?(selected_object, node.item) && "ring-4 ring-amber-300/30",
      !selected?(selected_object, node.item) && "ring-1 ring-white/5"
    ]
  end

  defp graph_edge_class(edge) do
    [
      "fill-none stroke-[2.25]",
      edge.kind == :goal && "stroke-emerald-300/55",
      edge.kind == :task && "stroke-sky-300/55"
    ]
  end

  defp graph_node_pills(%{"kind" => "goal"} = item) do
    [
      item["parent_goal_title"] && "Under #{item["parent_goal_title"]}",
      item["target_date"] && "Target #{item["target_date"]}"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp graph_node_pills(%{"kind" => "task"} = item) do
    [
      item["due_date"] && "Due #{item["due_date"]}",
      item["priority"] && item["priority"],
      item["parent_goal_title"] && "For #{item["parent_goal_title"]}"
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp graph_node_pills(_item), do: []
end
