// Draws cluster traffic that is worth watching.
//
// Two events arrive from the server. "goal-flight" carries the one hop a
// single goal takes - a comet streak out from the node the match lives on to
// its peers (peers behind a downed link are already removed). "cluster-flush"
// carries the backlog a node that just came back online exchanges with its
// peers, drawn deliberately differently: a "replay" (the backlog fit in the
// ring buffer) is a convoy of dots travelling together down the link (see
// syncStream); a "reload" (the sender overran its buffer, so the receiver's
// cursor expired) is rings collapsing into the receiving node - no convoy,
// because nothing was replayed in order. Both label the node they land on with
// a caption saying what the motion means, so the animation is not the only
// explanation.
//
// All read the link geometry straight out of the rendered SVG and draw into
// the #cluster-fx group, which LiveView is told to ignore so a re-render
// cannot delete an element mid-flight. Captions are plain HTML in the
// #cluster-captions layer over the SVG, placed in percentages of the viewBox
// so they follow their node as the picture scales.

const SVG_NS = "http://www.w3.org/2000/svg"
const HOP_MS = 520
const TRAIL = 6
const TRAIL_GAP = 7
const RIPPLE_MS = 650
const RELOAD_MS = 1100
const RELOAD_RINGS = 3
const RELOAD_GAP_MS = 200
const BATCH_MS = 2200
const BATCH_MAX = 12
const BATCH_SPREAD = 20
const DRAIN_MS = 900
// How long a caption stays up after the animation it explains has finished.
const CAPTION_LINGER_MS = 2600
const CAPTION_LIFT = 34
const CAPTION_STACK = 28

export const ClusterFx = {
  mounted() {
    this.alive = true
    this.drawn = new Set()
    // How many captions each node currently carries, so a second one stacks
    // above the first instead of covering it.
    this.captions = new Map()
    this.handleEvent("goal-flight", payload => this.play(payload))
    this.handleEvent("cluster-flush", payload => this.flush(payload))
  },

  destroyed() {
    this.alive = false
    this.drawn.forEach(element => element.remove())
    this.drawn.clear()
    this.captions.clear()
  },

  async play({hops, team}) {
    for (const hop of hops || []) {
      if (!this.alive) return
      await Promise.all(hop.to.map(target => this.comet(hop.from, target, team)))
    }
  },

  // A "replay" backlog flushes as one convoy of dots moving together down the
  // link (see syncStream) - deliberately unlike a single goal's comet streak.
  // A "reload" backlog is not replayed at all - the receiver's cursor expired,
  // so it pulls fresh state from the DB, drawn as rings collapsing into that
  // node. Each reloaded node is drawn once even when several peers overran it.
  flush({streams}) {
    const reloaded = new Set()
    const captioned = new Set()

    ;(streams || []).forEach(({from, to, count, mode}) => {
      if (mode === "reload") {
        if (!reloaded.has(to)) {
          reloaded.add(to)
          this.reloadNode(to)
        }
      } else {
        // Each peer has its own box, so the one that held this backlog drains.
        this.drainBox(from, to)

        // One caption per receiving node even when several peers sync to it.
        if (!captioned.has(to)) {
          captioned.add(to)
          this.caption(to, "all buffered msgs arrive as one package", BATCH_MS)
        }

        this.syncStream(from, to, count)
      }
    })
  },

  // The count box popping and fading as the backlog it held drains out. Cloned
  // into the ignored overlay so LiveView's next poll (which removes the real
  // box) cannot cut the animation short.
  drainBox(node, peer) {
    const box = this.el.querySelector(
      `[data-missing-box="${node}"][data-missing-peer="${peer}"]`
    )
    const fx = this.overlay()
    if (!box || !fx) return

    const clone = box.cloneNode(false)
    clone.setAttribute("class", "fx-drain")
    fx.appendChild(clone)
    this.drawn.add(clone)

    setTimeout(() => {
      this.drawn.delete(clone)
      clone.remove()
    }, DRAIN_MS)
  },

  // The buffered backlog draining on reconnect: a whole packet of dots spaced
  // out and travelling together as a convoy, in its own colour, landing with a
  // firm ripple. Reads as "a batch syncing", distinct from the single comet a
  // live goal draws.
  syncStream(from, to, count) {
    const link = this.link(from, to)
    const fx = this.overlay()
    if (!link || !fx || link.path.dataset.healthy !== "true") return

    const total = link.path.getTotalLength()
    const n = Math.max(2, Math.min(count, BATCH_MAX))
    const group = document.createElementNS(SVG_NS, "g")
    group.setAttribute("class", "fx-comet fx-sync")

    const dots = []
    for (let index = 0; index < n; index++) {
      const dot = document.createElementNS(SVG_NS, "circle")
      dot.setAttribute("r", "3.5")
      group.appendChild(dot)
      dots.push(dot)
    }

    fx.appendChild(group)
    this.drawn.add(group)

    const started = performance.now()

    const step = now => {
      if (!this.alive || !group.isConnected) return

      const fraction = Math.min(1, (now - started) / BATCH_MS)
      const eased = fraction * fraction * (3 - 2 * fraction)

      dots.forEach((dot, index) => {
        const travelled = eased * total - index * BATCH_SPREAD
        if (travelled < 0 || travelled > total) {
          dot.setAttribute("opacity", "0")
        } else {
          dot.setAttribute("opacity", "0.95")
          const at = link.path.getPointAtLength(link.reverse ? total - travelled : travelled)
          dot.setAttribute("cx", at.x)
          dot.setAttribute("cy", at.y)
        }
      })

      if (fraction < 1) return requestAnimationFrame(step)

      this.drawn.delete(group)
      group.remove()
      this.ripple(to, "sync")
    }

    requestAnimationFrame(step)
  },

  // Overflow recovery: the node reloads from the DB. Rings collapse inward
  // onto it, distinct from the outward ripple a delivered message throws.
  reloadNode(name) {
    const dot = this.el.querySelector(`circle[data-node-dot="${name}"]`)
    const fx = this.overlay()
    if (!dot || !fx) return

    this.caption(name, "cursor expired - fetching data from DB", RELOAD_MS)

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

  // A caption pinned beside a node, saying what the animation on it means. It
  // is an HTML element in the layer over the SVG, positioned in percentages of
  // the viewBox so it keeps its place as the picture scales, and it outlives
  // the animation by a beat so there is time to read it.
  caption(name, text, ms) {
    const dot = this.el.querySelector(`circle[data-node-dot="${name}"]`)
    const layer = this.captionLayer()
    if (!dot || !layer) return

    const view = this.el.viewBox.baseVal
    const stacked = this.captions.get(name) || 0
    this.captions.set(name, stacked + 1)

    const element = document.createElement("div")
    element.className = "cluster-caption"
    element.textContent = text
    element.style.left = `${(Number(dot.getAttribute("cx")) / view.width) * 100}%`
    element.style.top = `${(Number(dot.getAttribute("cy")) / view.height) * 100}%`
    element.style.setProperty("--caption-lift", `${CAPTION_LIFT + stacked * CAPTION_STACK}px`)

    const total = ms + CAPTION_LINGER_MS
    element.style.animationDuration = `${total}ms`

    layer.appendChild(element)
    this.drawn.add(element)

    setTimeout(() => {
      this.captions.set(name, Math.max(0, (this.captions.get(name) || 1) - 1))
      this.drawn.delete(element)
      element.remove()
    }, total)
  },

  captionLayer() {
    return this.el.parentElement && this.el.parentElement.querySelector("#cluster-captions")
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
