defmodule G3.Tracker.Hierarchy do
  @moduledoc false

  @goal_width 224
  @task_width 208
  @node_height 108
  @horizontal_gap 88
  @vertical_gap 28
  @padding 28

  def parent_goal(item, goals) when is_map(item) and is_list(goals) do
    indexes = build_goal_indexes(goals)

    case resolve_parent_goal_id(item, indexes) do
      nil -> nil
      parent_id -> indexes.goal_by_id[parent_id]
    end
  end

  def parent_goal(_item, _goals), do: nil

  def goal_depths(goals) when is_list(goals) do
    indexes = build_goal_indexes(goals)

    {_memo, depths} =
      Enum.reduce(goals, {%{}, %{}}, fn goal, {memo, acc} ->
        {depth, memo} = depth_for(goal["id"], indexes.parent_ids, memo, MapSet.new())
        {memo, Map.put(acc, goal["id"], depth)}
      end)

    depths
  end

  def goal_depths(_goals), do: %{}

  def visible_items(goals, tasks, show_completed? \\ false)

  def visible_items(goals, tasks, true) when is_list(goals) and is_list(tasks) do
    %{goals: goals, tasks: tasks}
  end

  def visible_items(goals, tasks, false) when is_list(goals) and is_list(tasks) do
    indexes = build_goal_indexes(goals)
    hidden_goal_ids = hidden_goal_ids(goals, indexes)

    visible_goals =
      Enum.reject(goals, fn goal ->
        MapSet.member?(hidden_goal_ids, goal["id"])
      end)

    visible_tasks =
      Enum.reject(tasks, fn task ->
        task["status"] == "completed" or hidden_task_parent?(task, hidden_goal_ids, indexes)
      end)

    %{goals: visible_goals, tasks: visible_tasks}
  end

  def visible_items(_goals, _tasks, _show_completed?), do: %{goals: [], tasks: []}

  def visible?(item, goals, tasks, show_completed? \\ false)

  def visible?(%{"kind" => "fact"}, _goals, _tasks, _show_completed?), do: true

  def visible?(%{"kind" => kind, "id" => id}, goals, tasks, show_completed?)
      when kind in ["goal", "task"] and is_binary(id) do
    visible_items = visible_items(goals, tasks, show_completed?)
    items = if(kind == "goal", do: visible_items.goals, else: visible_items.tasks)

    Enum.any?(items, &(&1["id"] == id))
  end

  def visible?(_item, _goals, _tasks, _show_completed?), do: false

  def graph(goals, tasks) when is_list(goals) and is_list(tasks) do
    goal_indexes = build_goal_indexes(goals)
    child_goals = group_goal_children(goals, goal_indexes.parent_ids)
    task_parents = Map.new(tasks, &{&1["id"], resolve_parent_goal_id(&1, goal_indexes)})
    child_tasks = group_task_children(tasks, task_parents)

    root_items =
      Enum.map(root_goals(goals, goal_indexes.parent_ids), &{:goal, &1}) ++
        Enum.map(standalone_tasks(tasks, task_parents), &{:task, &1})

    {layouts, next_y} =
      Enum.map_reduce(root_items, @padding, fn item, y_cursor ->
        layout = layout_item(item, 0, y_cursor, child_goals, child_tasks)
        {layout, layout.next_y}
      end)

    nodes =
      layouts
      |> Enum.flat_map(& &1.nodes)
      |> Enum.sort_by(fn node -> {node.x, node.y} end)

    edges = Enum.flat_map(layouts, & &1.edges)

    width =
      nodes
      |> Enum.reduce(@padding * 2 + @goal_width, fn node, acc ->
        max(acc, node.x + node.width + @padding)
      end)

    height =
      max(next_y - @vertical_gap + @padding, @node_height + @padding * 2)

    %{nodes: nodes, edges: edges, width: width, height: height}
  end

  def graph(_goals, _tasks), do: %{nodes: [], edges: [], width: 0, height: 0}

  defp layout_item({:task, task}, depth, y_cursor, _child_goals, _child_tasks) do
    node = node(task, :task, depth, y_cursor)

    %{
      root: node,
      nodes: [node],
      edges: [],
      next_y: y_cursor + @node_height + @vertical_gap
    }
  end

  defp layout_item({:goal, goal}, depth, y_cursor, child_goals, child_tasks) do
    children =
      Enum.map(Map.get(child_goals, goal["id"], []), &{:goal, &1}) ++
        Enum.map(Map.get(child_tasks, goal["id"], []), &{:task, &1})

    {child_layouts, next_y} =
      Enum.map_reduce(children, y_cursor, fn child, cursor ->
        layout = layout_item(child, depth + 1, cursor, child_goals, child_tasks)
        {layout, layout.next_y}
      end)

    child_roots = Enum.map(child_layouts, & &1.root)

    node_y =
      case child_roots do
        [] ->
          y_cursor

        roots ->
          top = roots |> List.first() |> Map.fetch!(:center_y)
          bottom = roots |> List.last() |> Map.fetch!(:center_y)
          round((top + bottom) / 2 - @node_height / 2)
      end

    root = node(goal, :goal, depth, node_y)

    edges =
      child_layouts
      |> Enum.flat_map(& &1.edges)
      |> Kernel.++(Enum.map(child_roots, &edge(root, &1)))

    nodes = [root] ++ Enum.flat_map(child_layouts, & &1.nodes)

    %{
      root: root,
      nodes: nodes,
      edges: edges,
      next_y: max(next_y, y_cursor + @node_height + @vertical_gap)
    }
  end

  defp node(item, kind, depth, y) do
    width = if(kind == :goal, do: @goal_width, else: @task_width)
    x = @padding + depth * (max(@goal_width, @task_width) + @horizontal_gap)

    %{
      item: item,
      kind: kind,
      x: x,
      y: y,
      width: width,
      height: @node_height,
      center_x: x + width,
      center_y: y + div(@node_height, 2)
    }
  end

  defp edge(from, to) do
    start_x = from.x + from.width
    start_y = from.center_y
    end_x = to.x
    end_y = to.center_y
    control_x = start_x + round((end_x - start_x) * 0.5)

    %{
      id: "#{from.item["id"]}-#{to.item["id"]}",
      kind: to.kind,
      path:
        "M #{start_x} #{start_y} C #{control_x} #{start_y}, #{control_x} #{end_y}, #{end_x} #{end_y}"
    }
  end

  defp root_goals(goals, parent_ids) do
    Enum.filter(goals, &(Map.get(parent_ids, &1["id"]) == nil))
  end

  defp standalone_tasks(tasks, task_parents) do
    Enum.filter(tasks, &(Map.get(task_parents, &1["id"]) == nil))
  end

  defp group_goal_children(goals, parent_ids) do
    goals
    |> Enum.reject(&(Map.get(parent_ids, &1["id"]) == nil))
    |> Enum.group_by(&Map.get(parent_ids, &1["id"]))
  end

  defp group_task_children(tasks, task_parents) do
    tasks
    |> Enum.reject(&(Map.get(task_parents, &1["id"]) == nil))
    |> Enum.group_by(&Map.get(task_parents, &1["id"]))
  end

  defp build_goal_indexes(goals) do
    goal_by_id = Map.new(goals, &{&1["id"], &1})
    title_index = title_index(goals)

    parent_ids =
      Map.new(goals, fn goal ->
        {goal["id"], resolve_goal_parent_id(goal, goal_by_id, title_index)}
      end)

    %{goal_by_id: goal_by_id, title_index: title_index, parent_ids: parent_ids}
  end

  defp hidden_goal_ids(goals, indexes) do
    {_memo, hidden_goal_ids} =
      Enum.reduce(goals, {%{}, MapSet.new()}, fn goal, {memo, acc} ->
        {hidden?, memo} = hidden_goal?(goal["id"], indexes, memo, MapSet.new())

        if hidden? do
          {memo, MapSet.put(acc, goal["id"])}
        else
          {memo, acc}
        end
      end)

    hidden_goal_ids
  end

  defp hidden_goal?(goal_id, indexes, memo, seen) do
    case memo do
      %{^goal_id => hidden?} ->
        {hidden?, memo}

      _ ->
        cond do
          MapSet.member?(seen, goal_id) ->
            {false, Map.put(memo, goal_id, false)}

          true ->
            goal = indexes.goal_by_id[goal_id]
            achieved? = is_map(goal) and goal["status"] == "achieved"

            case Map.get(indexes.parent_ids, goal_id) do
              nil ->
                {achieved?, Map.put(memo, goal_id, achieved?)}

              parent_id ->
                {parent_hidden?, memo} =
                  hidden_goal?(parent_id, indexes, memo, MapSet.put(seen, goal_id))

                hidden? = achieved? or parent_hidden?
                {hidden?, Map.put(memo, goal_id, hidden?)}
            end
        end
    end
  end

  defp hidden_task_parent?(task, hidden_goal_ids, indexes) do
    case resolve_parent_goal_id(task, indexes) do
      nil -> false
      parent_id -> MapSet.member?(hidden_goal_ids, parent_id)
    end
  end

  defp title_index(goals) do
    Enum.reduce(goals, %{}, fn goal, acc ->
      case title_key(goal["title"]) do
        nil -> acc
        key -> Map.put_new(acc, key, goal)
      end
    end)
  end

  defp resolve_parent_goal_id(item, %{goal_by_id: goal_by_id, title_index: title_index}) do
    cond do
      not is_map(item) ->
        nil

      goal_by_id[item["id"]] != nil ->
        resolve_goal_parent_id(item, goal_by_id, title_index)

      true ->
        resolve_parent_candidate(item, title_index)
        |> case do
          %{"id" => parent_id} -> parent_id
          _ -> nil
        end
    end
  end

  defp resolve_goal_parent_id(goal, goal_by_id, title_index) do
    case resolve_parent_candidate(goal, title_index) do
      %{"id" => parent_id} ->
        if parent_id == goal["id"] do
          nil
        else
          maybe_parent_goal_id(goal["id"], parent_id, goal_by_id, title_index)
        end

      _ ->
        nil
    end
  end

  defp maybe_parent_goal_id(goal_id, parent_id, goal_by_id, title_index) do
    if cycle?(goal_id, parent_id, goal_by_id, title_index, MapSet.new()) do
      nil
    else
      parent_id
    end
  end

  defp resolve_parent_candidate(item, title_index) do
    case title_key(item["parent_goal_title"]) do
      nil -> nil
      key -> Map.get(title_index, key)
    end
  end

  defp cycle?(root_id, current_id, goal_by_id, title_index, seen) do
    cond do
      current_id == root_id ->
        true

      MapSet.member?(seen, current_id) ->
        true

      true ->
        case goal_by_id[current_id] do
          nil ->
            false

          current_goal ->
            case resolve_parent_candidate(current_goal, title_index) do
              %{"id" => next_id} ->
                cycle?(root_id, next_id, goal_by_id, title_index, MapSet.put(seen, current_id))

              _ ->
                false
            end
        end
    end
  end

  defp depth_for(nil, _parent_ids, memo, _seen), do: {0, memo}

  defp depth_for(goal_id, parent_ids, memo, seen) do
    case memo do
      %{^goal_id => depth} ->
        {depth, memo}

      _ ->
        cond do
          MapSet.member?(seen, goal_id) ->
            {0, Map.put(memo, goal_id, 0)}

          true ->
            case Map.get(parent_ids, goal_id) do
              nil ->
                {0, Map.put(memo, goal_id, 0)}

              parent_id ->
                {parent_depth, memo} =
                  depth_for(parent_id, parent_ids, memo, MapSet.put(seen, goal_id))

                depth = parent_depth + 1
                {depth, Map.put(memo, goal_id, depth)}
            end
        end
    end
  end

  defp title_key(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      key -> key
    end
  end

  defp title_key(_value), do: nil
end
