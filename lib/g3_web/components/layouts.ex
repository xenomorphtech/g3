defmodule G3Web.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use G3Web, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="tracker-shell min-h-screen">
      <div class="absolute inset-x-0 top-0 h-72 bg-[radial-gradient(circle_at_top_left,_rgba(255,255,255,0.92),_transparent_58%),radial-gradient(circle_at_top_right,_rgba(255,210,196,0.56),_transparent_36%)]" />
      <header class="relative border-b border-white/50 bg-white/75 backdrop-blur-xl">
        <div class="mx-auto flex max-w-7xl items-center justify-between gap-6 px-4 py-5 sm:px-6 lg:px-8">
          <a href="/" class="flex items-center gap-4">
            <span class="tracker-logo">
              <.icon name="hero-sparkles" class="size-5 text-white" />
            </span>
            <span>
              <span class="block font-heading text-lg leading-none text-slate-950">Goal Studio</span>
              <span class="mt-1 block text-xs uppercase tracking-[0.28em] text-slate-500">
                Natural-Language Planning
              </span>
            </span>
          </a>

          <div class="hidden items-center gap-3 text-sm text-slate-600 md:flex">
            <span class="rounded-full border border-white/70 bg-white/70 px-3 py-1.5 shadow-[0_12px_36px_rgba(15,23,42,0.08)]">
              Persistent draft memory
            </span>
            <span class="rounded-full border border-white/70 bg-white/70 px-3 py-1.5 shadow-[0_12px_36px_rgba(15,23,42,0.08)]">
              Gemini-backed chat orchestration
            </span>
          </div>
        </div>
      </header>

      <main class="relative px-4 py-8 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-7xl space-y-6">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
