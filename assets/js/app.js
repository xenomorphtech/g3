// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/g3"
import topbar from "../vendor/topbar"

const SubmitOnCtrlEnter = {
  mounted() {
    this.handleKeyDown = (event) => {
      if (event.key !== "Enter" || !event.ctrlKey) return

      event.preventDefault()
      const form = document.getElementById(this.el.dataset.submitTarget)
      if (form) form.requestSubmit()
    }

    this.el.addEventListener("keydown", this.handleKeyDown)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this.handleKeyDown)
  },
}

const ClearOnSubmit = {
  mounted() {
    this.handleSubmit = () => {
      window.requestAnimationFrame(() => {
        const composer = this.el.querySelector("#chat_message")
        if (!composer) return

        composer.value = ""
        composer.dispatchEvent(new Event("input", {bubbles: true}))
      })
    }

    this.el.addEventListener("submit", this.handleSubmit)
  },

  destroyed() {
    this.el.removeEventListener("submit", this.handleSubmit)
  },
}

const PreventInitialFocus = {
  mounted() {
    this.focusGuardActive = true
    this.guardTimers = []

    this.preventFocus = () => {
      if (!this.focusGuardActive) return

      const active = document.activeElement
      if (!active || active === document.body || !this.el.contains(active)) return

      if (active.matches("input, textarea, select, button, [tabindex]")) {
        active.blur()
      }
    }

    this.disarmFocusGuard = () => {
      if (!this.focusGuardActive) return

      this.focusGuardActive = false
      this.guardTimers.forEach(timer => window.clearTimeout(timer))
      this.guardTimers = []
    }

    this.handlePageShow = () => this.preventFocus()
    this.handleUserIntent = () => this.disarmFocusGuard()

    ;[0, 50, 150, 300, 500].forEach(delay => {
      this.guardTimers.push(window.setTimeout(() => this.preventFocus(), delay))
    })

    window.addEventListener("pageshow", this.handlePageShow)
    window.addEventListener("pointerdown", this.handleUserIntent, true)
    window.addEventListener("keydown", this.handleUserIntent, true)
  },

  updated() {
    this.preventFocus()
  },

  destroyed() {
    this.disarmFocusGuard()
    window.removeEventListener("pageshow", this.handlePageShow)
    window.removeEventListener("pointerdown", this.handleUserIntent, true)
    window.removeEventListener("keydown", this.handleUserIntent, true)
  },
}

const GoalsSorter = {
  mounted() {
    this.draggedId = null
    this.dropTargetId = null
    this.dropPosition = "after"

    this.clearDropState = () => {
      this.el.querySelectorAll("[data-goal-id]").forEach(card => {
        card.classList.remove("opacity-60", "ring-4", "ring-slate-200", "border-sky-400", "border-slate-300")
      })
    }

    this.findCard = (event) => event.target.closest("[data-goal-id]")

    this.handleDragStart = (event) => {
      const card = this.findCard(event)
      if (!card) return

      this.draggedId = card.dataset.goalId
      this.dropTargetId = null
      this.clearDropState()
      card.classList.add("opacity-60", "ring-4", "ring-slate-200")

      if (event.dataTransfer) {
        event.dataTransfer.effectAllowed = "move"
        event.dataTransfer.setData("text/plain", this.draggedId)
      }
    }

    this.handleDragOver = (event) => {
      const card = this.findCard(event)
      if (!card || !this.draggedId || card.dataset.goalId === this.draggedId) return

      event.preventDefault()

      const rect = card.getBoundingClientRect()
      const beforeMidpoint = event.clientY < rect.top + rect.height / 2

      this.dropTargetId = card.dataset.goalId
      this.dropPosition = beforeMidpoint ? "before" : "after"

      this.clearDropState()

      const draggedCard = this.el.querySelector(`[data-goal-id="${this.draggedId}"]`)
      if (draggedCard) draggedCard.classList.add("opacity-60", "ring-4", "ring-slate-200")

      card.classList.add(beforeMidpoint ? "border-sky-400" : "border-slate-300")

      if (event.dataTransfer) event.dataTransfer.dropEffect = "move"
    }

    this.handleDrop = (event) => {
      const card = this.findCard(event)
      if (!card || !this.draggedId) return

      event.preventDefault()

      const orderedIds = Array.from(this.el.querySelectorAll("[data-goal-id]")).map(
        item => item.dataset.goalId
      )

      const draggedIndex = orderedIds.indexOf(this.draggedId)
      const targetIndex = orderedIds.indexOf(card.dataset.goalId)

      if (draggedIndex < 0 || targetIndex < 0 || draggedIndex === targetIndex) {
        this.handleDragEnd()
        return
      }

      const nextIds = orderedIds.filter(id => id !== this.draggedId)
      const insertionIndex =
        this.dropPosition === "before"
          ? targetIndex - (draggedIndex < targetIndex ? 1 : 0)
          : targetIndex + (draggedIndex < targetIndex ? 0 : 1)

      nextIds.splice(insertionIndex, 0, this.draggedId)
      this.pushEvent("reorder_goals", {ids: nextIds})
      this.handleDragEnd()
    }

    this.handleDragEnd = () => {
      this.draggedId = null
      this.dropTargetId = null
      this.clearDropState()
    }

    this.el.addEventListener("dragstart", this.handleDragStart)
    this.el.addEventListener("dragover", this.handleDragOver)
    this.el.addEventListener("drop", this.handleDrop)
    this.el.addEventListener("dragend", this.handleDragEnd)
  },

  destroyed() {
    this.el.removeEventListener("dragstart", this.handleDragStart)
    this.el.removeEventListener("dragover", this.handleDragOver)
    this.el.removeEventListener("drop", this.handleDrop)
    this.el.removeEventListener("dragend", this.handleDragEnd)
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, SubmitOnCtrlEnter, ClearOnSubmit, PreventInitialFocus, GoalsSorter},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
