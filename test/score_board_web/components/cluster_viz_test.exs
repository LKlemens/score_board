defmodule ScoreBoardWeb.ClusterVizTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ScoreBoardWeb.ClusterViz

  @up %{blip: false, pending: %{}, capacity: 20}
  @blipped %{blip: true, pending: %{}, capacity: 20}

  describe "link_up?/3" do
    test "a link between two healthy nodes carries events" do
      assert ClusterViz.link_up?(%{a: @up, b: @up}, :a, :b)
    end

    test "a blipped node takes down every link that touches it" do
      cluster = %{a: @up, b: @blipped}

      refute ClusterViz.link_up?(cluster, :a, :b)
      refute ClusterViz.link_up?(cluster, :b, :a)
    end

    test "an unreachable node has no live links" do
      refute ClusterViz.link_up?(%{a: @up, b: :unreachable}, :a, :b)
    end

    test "a node missing from the snapshot counts as unreachable" do
      refute ClusterViz.link_up?(%{a: @up}, :a, :gone)
    end
  end

  describe "goal_hops/3" do
    test "a goal fans out from the node the match lives on" do
      cluster = %{a: @up, b: @up, c: @up}

      assert ClusterViz.goal_hops(cluster, [:a, :b, :c], :b) == [%{from: "b", to: ["a", "c"]}]
    end

    test "an offline node is left out of the fan-out" do
      cluster = %{a: @up, b: @up, c: @blipped}

      assert ClusterViz.goal_hops(cluster, [:a, :b, :c], :a) == [%{from: "a", to: ["b"]}]
    end

    test "nothing travels when the owner itself is offline" do
      cluster = %{a: @up, b: @blipped, c: @up}

      assert ClusterViz.goal_hops(cluster, [:a, :b, :c], :b) == []
    end

    test "a single-node cluster has nowhere to send the goal" do
      assert ClusterViz.goal_hops(%{a: @up}, [:a], :a) == []
    end
  end

  describe "flush_streams/2" do
    test "a node coming back replays the backlog in both directions" do
      was = %{a: up(b: 4), b: blipped(a: 2)}
      now = %{a: up(b: 0), b: up(a: 0)}

      assert ClusterViz.flush_streams(was, now) == [
               %{from: "a", to: "b", count: 4, mode: "replay"},
               %{from: "b", to: "a", count: 2, mode: "replay"}
             ]
    end

    test "a backlog past the buffer is a reload, not a replay" do
      was = %{a: up(b: 25), b: blipped(a: 2)}
      now = %{a: up(b: 0), b: up(a: 0)}

      assert ClusterViz.flush_streams(was, now) == [
               %{from: "a", to: "b", count: 25, mode: "reload"},
               %{from: "b", to: "a", count: 2, mode: "replay"}
             ]
    end

    test "a node that rejoins the cluster flushes what its peers queued" do
      was = %{a: up(b: 3), b: :unreachable}
      now = %{a: up(b: 0), b: up(a: 0)}

      assert ClusterViz.flush_streams(was, now) == [
               %{from: "a", to: "b", count: 3, mode: "replay"}
             ]
    end

    test "a peer that is still offline is left out" do
      was = %{a: up(c: 3), b: blipped(c: 5), c: blipped(a: 0, b: 0)}
      now = %{a: up(c: 0), b: blipped(c: 5), c: up(a: 0, b: 0)}

      assert ClusterViz.flush_streams(was, now) == [
               %{from: "a", to: "c", count: 3, mode: "replay"}
             ]
    end

    test "an empty backlog produces nothing to draw" do
      was = %{a: up(b: 0), b: blipped(a: 0)}
      now = %{a: up(b: 0), b: up(a: 0)}

      assert ClusterViz.flush_streams(was, now) == []
    end

    test "a cluster that did not change has nothing to flush" do
      now = %{a: up(b: 7), b: up(a: 7)}

      assert ClusterViz.flush_streams(now, now) == []
    end
  end

  describe "sustained/3" do
    test "a fresh backlog is not drawn yet, only remembered" do
      {drawn, since} = ClusterViz.sustained(%{a: up(b: 4)}, %{}, 0)

      assert Enum.empty?(drawn)
      assert since == %{{:a, :b} => 0}
    end

    test "a backlog held past the hold time is drawn" do
      {drawn, since} = ClusterViz.sustained(%{a: up(b: 4)}, %{{:a, :b} => 0}, 1_500)

      assert Enum.to_list(drawn) == [{:a, :b}]
      assert since == %{{:a, :b} => 0}
    end

    test "each peer is timed on its own" do
      since = %{{:a, :b} => 0}
      {drawn, since} = ClusterViz.sustained(%{a: up(b: 4, c: 2)}, since, 1_200)

      assert Enum.to_list(drawn) == [{:a, :b}]
      assert since == %{{:a, :b} => 0, {:a, :c} => 1_200}
    end

    test "a backlog that drained starts its clock over" do
      {_drawn, since} = ClusterViz.sustained(%{a: up(b: 0)}, %{{:a, :b} => 0}, 5_000)

      assert since == %{}

      {drawn, since} = ClusterViz.sustained(%{a: up(b: 3)}, since, 5_100)

      assert Enum.empty?(drawn)
      assert since == %{{:a, :b} => 5_100}
    end

    test "an unreachable node has no backlog to time" do
      {drawn, since} = ClusterViz.sustained(%{a: :unreachable}, %{}, 9_000)

      assert Enum.empty?(drawn)
      assert since == %{}
    end
  end

  describe "cluster_viz/1 rendering" do
    test "offline and online toggles use distinct colours" do
      html = render_viz(%{a: up(b: 6), b: blipped(a: 0)})

      assert html =~ ~r/<rect[^>]*class="fill-error"><\/rect>\s*<text[^>]*>\s*Go offline/
      assert html =~ ~r/<rect[^>]*class="fill-success"><\/rect>\s*<text[^>]*>\s*Back online/
    end

    test "each node is hoverable and names itself in full" do
      html = render_viz(%{:"board1@127.0.0.1" => up(), :"board2@127.0.0.1" => up()})

      assert html =~ "<title>board1@127.0.0.1</title>"
      assert html =~ "<title>board2@127.0.0.1</title>"
    end

    test "a heading above the graph says a circle is a node" do
      html = render_viz(%{a: up(), b: up()})

      assert html =~ "Each circle is one node - a separate BEAM VM with its own board state."
    end

    test "the tooltip shows the missing count against the max capacity" do
      html = render_viz(%{a: up(b: 6), b: blipped(a: 0)})

      assert html =~ "missing_msg: 6 to b, max_capacity: 20"
    end

    test "past the buffer the tooltip reads overflow" do
      html = render_viz(%{a: up(b: 25), b: blipped(a: 0)})

      assert html =~ "missing_msg: 25 to b, capacity: overflow"
    end

    test "an offline node counts its own stuck outbound backlog" do
      # b is offline and has buffered 5 of its own messages toward a; the box
      # shows on b even though no peer buffered anything toward it.
      html = render_viz(%{a: up(b: 0), b: blipped(a: 5)})

      assert html =~ "missing_msg: 5 to a, max_capacity: 20"
    end

    test "buffering for two offline peers draws one box per peer" do
      html = render_viz(%{a: up(b: 8, c: 25), b: blipped(a: 0), c: blipped(a: 0)})

      assert html =~ ~s(data-missing-box="a" data-missing-peer="b")
      assert html =~ ~s(data-missing-box="a" data-missing-peer="c")
      assert html =~ "missing_msg: 8 to b, max_capacity: 20"
      assert html =~ "missing_msg: 25 to c, capacity: overflow"
    end

    test "the two boxes of one node do not sit on top of each other" do
      html = render_viz(%{a: up(b: 8, c: 9), b: blipped(a: 0), c: blipped(a: 0)})

      boxes = Regex.scan(~r/<rect x="[^"]*" y="([^"]*)"[^>]*data-missing-box="a"/, html)

      assert length(boxes) == 2
      assert [y1, y2] = Enum.map(boxes, fn [_, y] -> String.to_integer(y) end)
      assert abs(y2 - y1) >= 24
    end

    test "a peer with nothing buffered for it gets no box" do
      html = render_viz(%{a: up(b: 0, c: 4), b: up(a: 0), c: blipped(a: 0)})

      refute html =~ ~s(data-missing-peer="b")
      assert html =~ ~s(data-missing-peer="c")
    end

    test "only buffers held long enough are drawn" do
      cluster = %{a: up(b: 8, c: 3), b: blipped(a: 0), c: up(a: 0)}
      html = render_viz(cluster, MapSet.new([{:a, :b}]))

      assert html =~ ~s(data-missing-peer="b")
      refute html =~ ~s(data-missing-peer="c")
    end

    test "a momentary backlog draws neither box nor card" do
      html = render_viz(%{a: up(b: 1), b: up(a: 0)}, MapSet.new())

      refute html =~ "data-missing-peer="
      refute html =~ "data-story="
      assert html =~ "data-story-empty"
    end
  end

  describe "cluster_viz/1 story cards" do
    test "an offline node is explained as a partition" do
      html = render_viz(%{a: up(b: 0), b: blipped(a: 0)})

      assert html =~ ~s(data-story="offline" data-story-node="b")
      assert html =~ "b is offline"
      assert html =~ "temporary network partition"
    end

    test "a buffer under capacity explains the wait and the replay" do
      html = render_viz(%{a: up(b: 8), b: blipped(a: 0)})

      assert html =~ ~s(data-story="buffered" data-story-node="a")
      assert html =~ "8 msgs buffered"
      assert html =~ "Waiting for b to be back"
    end

    test "a buffer past capacity explains cursor_expired and the DB reload" do
      html = render_viz(%{a: up(b: 25), b: blipped(a: 0)})

      assert html =~ ~s(data-story="overflow" data-story-node="a")
      assert html =~ "buffer overflowed (25)"
      assert html =~ "cursor_expired"
      assert html =~ "reloads its data from the DB"
    end

    test "two buffers get a card each" do
      html = render_viz(%{a: up(b: 8, c: 25), b: blipped(a: 0), c: blipped(a: 0)})

      assert html =~ "8 msgs buffered"
      assert html =~ "buffer overflowed (25)"
    end

    test "a healthy cluster tells no story" do
      html = render_viz(%{a: up(b: 0), b: up(a: 0)})

      refute html =~ "data-story="
    end
  end

  defp render_viz(cluster, sustained \\ :all) do
    nodes = cluster |> Map.keys() |> Enum.sort()

    render_component(&ClusterViz.cluster_viz/1,
      nodes: nodes,
      cluster: cluster,
      node: hd(nodes),
      sustained: sustained
    )
  end

  defp up, do: @up
  defp up(pending), do: %{@up | pending: Map.new(pending)}
  defp blipped(pending), do: %{@blipped | pending: Map.new(pending)}
end
