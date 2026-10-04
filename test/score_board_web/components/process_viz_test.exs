defmodule ScoreBoardWeb.ProcessVizTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ScoreBoardWeb.ProcessViz

  @nodes [:board1@host, :board2@host]

  defp render_map(matches, boards) do
    render_component(&ProcessViz.process_map/1,
      nodes: @nodes,
      matches: matches,
      boards: boards,
      node: :board1@host
    )
  end

  defp boards(rows) do
    Map.new(rows, fn
      {node, :unreachable} -> {node, :unreachable}
      {node, ids} -> {node, Map.new(ids, &{&1, %{home: 0, away: 0}})}
    end)
  end

  test "a match pill shows the score the process holds" do
    html =
      render_map(
        [%{id: "POL-GER", owner: :board1@host, true_score: %{home: 2, away: 1}}],
        boards([{:board1@host, ["POL-GER"]}, {:board2@host, ["POL-GER"]}])
      )

    assert html =~ "POL-GER  2:1"
  end

  test "a match whose score is not known yet shows just its id" do
    html =
      render_map(
        [%{id: "POL-GER", owner: :board1@host, true_score: nil}],
        boards([{:board1@host, []}, {:board2@host, []}])
      )

    assert html =~ "POL-GER"
    refute html =~ "POL-GER  "
  end

  test "a match is drawn in the column of the node it runs on" do
    html =
      render_map(
        [%{id: "POL-GER", owner: :board2@host}],
        boards([{:board1@host, ["POL-GER"]}, {:board2@host, ["POL-GER"]}])
      )

    assert html =~ "POL-GER"
    # board2 is the second of two columns, so its pills sit in the right half.
    [[_, x]] = Regex.scan(~r/<rect x="(\d+)"[^>]*rx="13"/, html)
    assert String.to_integer(x) > 360
  end

  test "every VM shows its board and the rows that board holds" do
    html =
      render_map(
        [%{id: "POL-GER", owner: :board1@host}],
        boards([{:board1@host, ["POL-GER"]}, {:board2@host, ["POL-GER", "ESP-FRA"]}])
      )

    assert html =~ "board1 (this) · BEAM VM"
    assert html =~ "board2 · BEAM VM"
    assert html =~ "board process"
    assert html =~ "POL-GER  0:0"
    assert html =~ "ESP-FRA  0:0"
  end

  test "an unreachable node says so instead of a count" do
    html =
      render_map(
        [%{id: "POL-GER", owner: :board1@host}],
        boards([{:board1@host, ["POL-GER"]}, {:board2@host, :unreachable}])
      )

    assert html =~ "unreachable"
    assert html =~ "stroke-error"
  end

  test "a VM running no matches says so" do
    html =
      render_map(
        [%{id: "POL-GER", owner: :board1@host}],
        boards([{:board1@host, ["POL-GER"]}, {:board2@host, ["POL-GER"]}])
      )

    assert html =~ "no match process here"
  end

  test "a match still being placed is listed separately" do
    html = render_map([%{id: "NEW-ONE", owner: nil}], boards([{:board1@host, []}]))

    assert html =~ "being placed: NEW-ONE"
  end

  test "nodes are linked to each other, not to the processes inside them" do
    html =
      render_map(
        [%{id: "POL-GER", owner: :board1@host}],
        boards([{:board1@host, ["POL-GER"]}, {:board2@host, ["POL-GER"]}])
      )

    # One bus line plus one stub per node - nothing touching a pill.
    assert length(Regex.scan(~r/<line /, html)) == 3
    assert html =~ "goals broadcast between nodes"
  end

  test "a single-node cluster draws no links at all" do
    html =
      render_component(&ProcessViz.process_map/1,
        nodes: [:board1@host],
        matches: [%{id: "POL-GER", owner: :board1@host}],
        boards: %{board1@host: %{"POL-GER" => %{home: 0, away: 0}}},
        node: :board1@host
      )

    refute html =~ "<line "
    refute html =~ "goals broadcast between nodes"
  end

  test "each board names its node in full on hover" do
    html = render_map([], boards([{:board1@host, []}, {:board2@host, []}]))

    assert html =~ "<title>board1@host</title>"
    assert html =~ "<title>board2@host</title>"
  end
end
