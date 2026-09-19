// Draws cluster traffic that is worth watching.
//
// Two events arrive from the server. "goal-flight" carries the one hop a
// goal takes - out from the node the match lives on to its peers, with
// peers behind a downed link already removed. "cluster-flush" carries the
// backlog a node that just came back online exchanges with its peers. Each
// stream is one of two kinds: a "replay" (the backlog fit in the ring
// buffer) is drawn as a staggered train of dots down the link; a "reload"
// (the sender overran its buffer, so the receiver's cursor expired and it
// reloads from the DB instead) is drawn as rings collapsing into the
// receiving node - no link train, because nothing was replayed in order.
//
// All read the link geometry straight out of the rendered SVG and draw
// into the #cluster-fx group, which LiveView is told to ignore so a
// re-render cannot delete an element mid-flight.

const SVG_NS = "http://www.w3.org/2000/svg"
const HOP_MS = 520
const TRAIL = 6
const TRAIL_GAP = 7
const RIPPLE_MS = 650
const FLUSH_MS = 360
const FLUSH_GAP_MS = 90
const FLUSH_MAX = 8
const RELOAD_MS = 700
const RELOAD_RINGS = 3
const RELOAD_GAP_MS = 140

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

  // A "replay" backlog leaves in a staggered train (delivered in order, only
  // the last lands hard enough to ripple). A "reload" backlog is not replayed
  // at all - the receiver's cursor expired, so it pulls fresh state from the
  // DB, drawn as rings collapsing into that node. Each reloaded node is drawn
  // once even when several peers overran it.
  flush({streams}) {
    const reloaded = new Set()

    ;(streams || []).forEach(({from, to, count, mode}) => {
      if (mode === "reload") {
        if (!reloaded.has(to)) {
          reloaded.add(to)
          this.reloadNode(to)
        }
        return
      }

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

  // Overflow recovery: the node reloads from the DB. Rings collapse inward
  // onto it, distinct from the outward ripple a delivered message throws.
  reloadNode(name) {
    const dot = this.el.querySelector(`circle[data-node-dot="${name}"]`)
    const fx = this.overlay()
    if (!dot || !fx) return

    for (let index = 0; index < RELOAD_RINGS; index++) {
      const ring = document.createElementNS(SVG_NS, "circle")
      ring.setAttribute("class", "fx-reload")
      ring.setAttribute("cx", dot.getAttribute("cx"))
      ring.setAttribute("cy", dot.getAttribute("cy"))
      ring.setAttribute("r", "20")
      ring.style.animationDelay = `${index * RELOAD_GAP_MS}ms`

      fx.appendChild(ring)
      this.drawn.add(ring)

      setTimeout(() => {
        this.drawn.delete(ring)
        ring.remove()
      }, RELOAD_MS + index * RELOAD_GAP_MS)
    }
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
