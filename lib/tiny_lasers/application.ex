defmodule TinyLasers.Application do
  @moduledoc """
  Boots the runtime's long-lived processes — the same set nexus's supervisor starts for
  Wasm today: the module pool, the JIT cache, the actor children, plus the lock-free
  metrics tables. Lazy ETS tables (`:tl_futex`, `:tl_threads`, ...) are created
  on-demand inside a run, so they need no supervision here.
  """
  use Application

  @impl true
  def start(_type, _args) do
    TinyLasers.Wasm.Metrics.ensure()

    children =
      [
        TinyLasers.Wasm.ModulePool,
        TinyLasers.Wasm.JitCache
      ] ++ TinyLasers.Wasm.Actor.child_specs()

    Supervisor.start_link(children, strategy: :one_for_one, name: TinyLasers.Supervisor)
  end
end
