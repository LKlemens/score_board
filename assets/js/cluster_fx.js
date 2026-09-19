// Draws cluster traffic that is worth watching.
//
// Two events arrive from the server. "goal-flight" carries the one hop a
// goal takes - out from the node the match lives on to its peers, with
// peers behind a downed link already removed. "cluster-flush" carries the
// backlog a node that just came back online is about to exchange with its
// peers, and is drawn as a burst of smaller dots.
//
// Both read the link geometry straight out of the rendered SVG and walk
// dots along it, drawing into the #cluster-fx group, which LiveView is
// told to ignore so a re-render cannot delete a dot mid-flight.

const SVG_NS = "http://www.w3.org/2000/svg"
const HOP_MS = 520
const TRAIL = 6
const TRAIL_GAP = 7
const RIPPLE_MS = 650
const FLUSH_MS = 360
const FLUSH_GAP_MS = 90
const FLUSH_MAX = 8

export const ClusterFx = {
  mounted() {
    this.alive = true
    this.drawn = new Set()
    this.handleEvent("goal-flight", payload => this.play(payload))
    this.handleEvent("cluster-flush", payload => this.flush(payload))
  },

  destroyed() {
    this.alive = false
    this.drawn.forEach(element => element.remove())
    this.drawn.clear()
  },

  async play({hops, team}) {
    for (const hop of hops || []) {
      if (!this.alive) return
      await Promise.all(hop.to.map(target => this.comet(hop.from, target, team)))
    }
  },

  // A recovered node replays its backlog in order, so the dots leave in a
  // staggered train rather than all at once. Only the last one lands hard
  // enough to ripple.
  flush({streams}) {
    (streams || []).forEach(({from, to, count}) => {
      const burst = Math.min(count, FLUSH_MAX)

      for (let index = 0; index < burst; index++) {
        setTimeout(() => {
          if (!this.alive) return
          this.comet(from, to, "flush", {
            size: 4,
            ms: FLUSH_MS,
            ripple: index === burst - 1
          })
        }, index * FLUSH_GAP_MS)
      }
    })
  },

  // The graph draws one path per unordered pair, so a hop may have to be
  // walked backwards along the path it was rendered from.
  link(from, to) {
    const forward = this.el.querySelector(
      `path[data-link-from="${from}"][data-link-to="${to}"]`
    )
    if (forward) return {path: forward, reverse: false}

    const backward = this.el.querySelector(
      `path[data-link-from="${to}"][data-link-to="${from}"]`
    )
    if (backward) return {path: backward, reverse: true}

    return null
  },

  overlay() {
    return this.el.querySelector("#cluster-fx")
  },

  comet(from, to, tone, {size = 6, ms = HOP_MS, ripple = true} = {}) {
    const link = this.link(from, to)
    const fx = this.overlay()
    if (!link || !fx || link.path.dataset.healthy !== "true") return Promise.resolve()

    const total = link.path.getTotalLength()
    const group = document.createElementNS(SVG_NS, "g")
    group.setAttribute("class", `fx-comet fx-${tone}`)

    const dots = []
    for (let index = 0; index < TRAIL; index++) {
      const dot = document.createElementNS(SVG_NS, "circle")
      dot.setAttribute("r", String(size - index * (size / TRAIL)))
      dot.setAttribute("opacity", String(1 - index / TRAIL))
      group.appendChild(dot)
      dots.push(dot)
    }

    fx.appendChild(group)
    this.drawn.add(group)

    return new Promise(resolve => {
      const started = performance.now()

      const step = now => {
        if (!this.alive || !group.isConnected) return resolve()

        const fraction = Math.min(1, (now - started) / ms)
        const eased = fraction * fraction * (3 - 2 * fraction)

        dots.forEach((dot, index) => {
          const travelled = Math.max(0, eased * total - index * TRAIL_GAP)
          const at = link.path.getPointAtLength(link.reverse ? total - travelled : travelled)
          dot.setAttribute("cx", at.x)
          dot.setAttribute("cy", at.y)
        })

        if (fraction < 1) return requestAnimationFrame(step)

        this.drawn.delete(group)
        group.remove()
        if (ripple) this.ripple(to, tone)
        resolve()
      }

      requestAnimationFrame(step)
    })
  },

  ripple(name, tone) {
    const dot = this.el.querySelector(`circle[data-node-dot="${name}"]`)
    const fx = this.overlay()
    if (!dot || !fx) return

    const ring = document.createElementNS(SVG_NS, "circle")
    ring.setAttribute("class", `fx-ripple fx-${tone}`)
    ring.setAttribute("cx", dot.getAttribute("cx"))
    ring.setAttribute("cy", dot.getAttribute("cy"))
    ring.setAttribute("r", "20")

    fx.appendChild(ring)
    this.drawn.add(ring)

    setTimeout(() => {
      this.drawn.delete(ring)
      ring.remove()
    }, RIPPLE_MS)
  }
}
