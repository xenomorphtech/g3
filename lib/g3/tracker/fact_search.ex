defmodule G3.Tracker.FactSearch do
  @moduledoc false

  @default_limit 5
  @k1 1.2
  @b 0.75

  def bm25(query, facts_or_snapshot, opts \\ []) when is_binary(query) do
    facts = facts_list(facts_or_snapshot)
    limit = Keyword.get(opts, :limit, @default_limit)
    query_tokens = query |> tokenize() |> Enum.uniq()

    documents = Enum.map(facts, &build_document/1)
    document_count = max(length(documents), 1)
    average_length = average_document_length(documents)
    document_frequencies = document_frequencies(documents, query_tokens)

    documents
    |> Enum.map(fn document ->
      score =
        bm25_score(document, query_tokens, document_frequencies, document_count, average_length)

      result(document.fact, score, best_snippet(document.fact, query_tokens))
    end)
    |> Enum.filter(&(&1["score"] > 0.0))
    |> Enum.sort_by(&{-&1["score"], &1["title"]})
    |> Enum.take(limit)
  end

  def grep(pattern, facts_or_snapshot, opts \\ []) when is_binary(pattern) do
    facts = facts_list(facts_or_snapshot)
    limit = Keyword.get(opts, :limit, @default_limit)
    regex = compile_pattern(pattern)

    facts
    |> Enum.reduce([], fn fact, acc ->
      case first_match(fact, regex) do
        nil ->
          acc

        %{field: field, snippet: snippet, matches: matches} ->
          [grep_result(fact, field, snippet, matches) | acc]
      end
    end)
    |> Enum.reverse()
    |> Enum.take(limit)
  end

  defp facts_list(%{"facts" => facts}) when is_list(facts), do: facts
  defp facts_list(facts) when is_list(facts), do: facts
  defp facts_list(_other), do: []

  defp build_document(fact) do
    tokens =
      weighted_tokens(fact["title"], 4) ++
        weighted_tokens(fact["summary"], 2) ++
        weighted_tokens(fact["details"], 3) ++
        weighted_tokens(fact["project_title"], 2)

    %{
      fact: fact,
      tokens: tokens,
      token_frequencies: Enum.frequencies(tokens),
      length: max(length(tokens), 1)
    }
  end

  defp weighted_tokens(nil, _weight), do: []

  defp weighted_tokens(text, weight) when is_binary(text) and weight > 0 do
    text
    |> tokenize()
    |> Enum.flat_map(fn token -> List.duplicate(token, weight) end)
  end

  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
  end

  defp tokenize(_text), do: []

  defp average_document_length([]), do: 1.0

  defp average_document_length(documents) do
    documents
    |> Enum.map(& &1.length)
    |> Enum.sum()
    |> Kernel./(length(documents))
  end

  defp document_frequencies(documents, query_tokens) do
    Enum.reduce(query_tokens, %{}, fn token, acc ->
      frequency =
        Enum.count(documents, fn document ->
          Map.has_key?(document.token_frequencies, token)
        end)

      Map.put(acc, token, frequency)
    end)
  end

  defp bm25_score(document, query_tokens, document_frequencies, document_count, average_length) do
    Enum.reduce(query_tokens, 0.0, fn token, score ->
      term_frequency = Map.get(document.token_frequencies, token, 0)

      if term_frequency == 0 do
        score
      else
        document_frequency = Map.get(document_frequencies, token, 0)

        idf =
          :math.log(1 + (document_count - document_frequency + 0.5) / (document_frequency + 0.5))

        numerator = term_frequency * (@k1 + 1)
        denominator = term_frequency + @k1 * (1 - @b + @b * document.length / average_length)

        score + idf * numerator / denominator
      end
    end)
  end

  defp result(fact, score, snippet) do
    %{
      "id" => fact["id"],
      "title" => fact["title"],
      "project_title" => fact["project_title"],
      "score" => Float.round(score, 4),
      "snippet" => snippet
    }
  end

  defp best_snippet(fact, query_tokens) do
    text =
      Enum.find_value(
        [fact["details"], fact["summary"], fact["title"], fact["project_title"]],
        fn value ->
          if is_binary(value) and
               Enum.any?(query_tokens, &String.contains?(String.downcase(value), &1)) do
            value
          end
        end
      ) || fact["details"] || fact["summary"] || fact["title"] || fact["project_title"] || ""

    snippet(text)
  end

  defp snippet(text) when is_binary(text) do
    if String.length(text) > 180 do
      String.slice(text, 0, 177) <> "..."
    else
      text
    end
  end

  defp compile_pattern(pattern) do
    case Regex.compile(pattern, "iu") do
      {:ok, regex} ->
        regex

      {:error, _reason} ->
        {:ok, regex} = Regex.compile(Regex.escape(pattern), "iu")
        regex
    end
  end

  defp first_match(fact, regex) do
    Enum.find_value(
      [
        {"title", fact["title"]},
        {"summary", fact["summary"]},
        {"details", fact["details"]},
        {"project_title", fact["project_title"]}
      ],
      fn
        {_field, nil} ->
          nil

        {field, value} ->
          matches = Regex.scan(regex, value) |> length()

          if matches > 0 do
            %{field: field, snippet: snippet(value), matches: matches}
          end
      end
    )
  end

  defp grep_result(fact, field, snippet, matches) do
    %{
      "id" => fact["id"],
      "title" => fact["title"],
      "project_title" => fact["project_title"],
      "field" => field,
      "matches" => matches,
      "snippet" => snippet
    }
  end
end
