defmodule G3.Tracker.FactSearchTest do
  use ExUnit.Case, async: true

  alias G3.Tracker.FactSearch

  test "bm25 ranks the most relevant fact first" do
    facts = [
      %{
        "id" => "fact-1",
        "title" => "Launch copy needs legal approval",
        "details" => "Initial launch messaging must be approved by legal before publishing.",
        "project_title" => "Launch portfolio site"
      },
      %{
        "id" => "fact-2",
        "title" => "Debugger runs on the BEAM first",
        "details" => "The first debugger milestone should stay entirely on the BEAM runtime.",
        "project_title" => "Build debugger"
      }
    ]

    [top_result | _rest] = FactSearch.bm25("legal approval for launch copy", facts)

    assert top_result["id"] == "fact-1"
    assert top_result["project_title"] == "Launch portfolio site"
    assert top_result["score"] > 0.0
  end

  test "grep returns regex-style matches with field and snippet information" do
    facts = [
      %{
        "id" => "fact-1",
        "title" => "Launch copy needs legal approval",
        "details" => "Initial launch messaging must be approved by legal before publishing.",
        "project_title" => "Launch portfolio site"
      },
      %{
        "id" => "fact-2",
        "title" => "Debugger runs on the BEAM first",
        "details" => "The first debugger milestone should stay entirely on the BEAM runtime.",
        "project_title" => "Build debugger"
      }
    ]

    [match | _rest] = FactSearch.grep("BEAM\\s+first", facts)

    assert match["id"] == "fact-2"
    assert match["field"] in ["title", "details"]
    assert match["matches"] >= 1
    assert String.contains?(match["snippet"], "BEAM")
  end
end
