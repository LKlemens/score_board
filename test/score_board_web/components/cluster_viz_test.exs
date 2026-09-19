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
               %{from: "a", to: "b", count: 4},
               %{from: "b", to: "a", count: 2}
             ]
    end

    test "a node that rejoins the cluster flushes what its peers queued" do
      was = %{a: up(b: 3), b: :unreachable}
      now = %{a: up(b: 0), b: up(a: 0)}

      assert ClusterViz.flush_streams(was, now) == [%{from: "a", to: "b", count: 3}]
    end

    test "a peer that is still offline is left out" do
      was = %{a: up(c: 3), b: blipped(c: 5), c: blipped(a: 0, b: 0)}
      now = %{a: up(c: 0), b: blipped(c: 5), c: up(a: 0, b: 0)}

      assert ClusterViz.flush_streams(was, now) == [%{from: "a", to: "c", count: 3}]
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

  describe "cluster_viz/1 rendering" do
    test "offline and online toggles use distinct colours" do
      html = render_viz(%{a: up(b: 6), b: blipped(a: 0)})

      assert html =~ ~r/<rect[^>]*class="fill-error"><\/rect>\s*<text[^>]*>\s*Go offline/
      assert html =~ ~r/<rect[^>]*class="fill-success"><\/rect>\s*<text[^>]*>\s*Back online/
    end

    test "the tooltip shows the missing count against the max capacity" do
      html = render_viz(%{a: up(b: 6), b: blipped(a: 0)})

      assert html =~ "missing_msg: 6, max_capacity: 20"
    end

    test "past the buffer the tooltip reads overflow" do
      html = render_viz(%{a: up(b: 25), b: blipped(a: 0)})

      assert html =~ "missing_msg: 25, capacity: overflow"
    end
  end

  defp render_viz(cluster) do
    nodes = cluster |> Map.keys() |> Enum.sort()
    render_component(&ClusterViz.cluster_viz/1, nodes: nodes, cluster: cluster, node: hd(nodes))
  end

  defp up(pending), do: %{@up | pending: Map.new(pending)}
  defp blipped(pending), do: %{@blipped | pending: Map.new(pending)}
end
