defmodule TinyLasers.Wasm.Actor do
  @moduledoc """
  **JS↔OTP interop — the persistent guest actor.** This turns a one-shot Wasm run into a long-lived,
  supervised BEAM process that participates in the actor model: it has a stable handle (pid), a mailbox,
  a registered `onMessage` callback, and the ability to `spawn` / `send` / `call`. This is the host-side
  mechanism behind the `Beam.*` global a QuickJS guest will call into (see
  `reference/beam/JS-OTP-INTEROP-DESIGN.md` for the full design + the `harness_run.c` changes that wire
  the JS side).

  ## The model
  Each guest is ONE `GenServer` under a `DynamicSupervisor`. The GenServer holds the guest's *durable*
  state between messages — its script and (in the real wiring) its QuickJS module state. A message
  arriving in the BEAM mailbox is delivered to the guest by **re-entering JS**: the guest runs
  run-to-completion for that one message (exactly like a `GenServer.handle_cast`), invoking the JS
  callback that `Beam.onMessage` registered, then yields and waits for the next message. A crash in one
  guest is contained by the BEAM process boundary + the supervisor — it never touches its siblings.

  ## Host primitives (what a `Beam.*` host-import dispatches to)
  - `Beam.self()`   → `beam_self/0`   — the running guest's handle.
  - `Beam.spawn(s)` → `beam_spawn/1`  — start a new supervised guest actor; returns its handle.
  - `Beam.send(p,m)`→ `beam_send/2`   — deliver `m` to actor `p`'s mailbox (cast).
  - `Beam.call(n,a)`→ `beam_call/2`   — invoke a registered Elixir handler synchronously, get the result.
  - `Beam.processInfo/systemInfo`     → `process_info/1` / `system_info/0`.

  ## The JS↔Erlang term bridge
  Messages cross the boundary as Erlang terms via `TinyLasers.Wasm.Actor.Term` (a JSON-equivalent
  STRUCTURAL mapping — number/string/bool/nil/list/map of those, recursively). The prototype carries
  Elixir terms directly; the real JS path serializes a JS value to this same restricted term shape on
  the way out and reconstructs a JS value on the way in. Round-tripping is bit-stable for any value in
  the shared shape (see `Term.normalize/1`).

  ## Driving the guest
  Two execution backends, selected by what the actor is given:
    * `{:fun, fun}`  — an Elixir handler `(message, state) -> {reply, new_state}`. Proves the actor
      mechanism end-to-end with NO JS side (deliverable #2). Also how Elixir-registered handlers run.
    * `{:js, script}` — a JS guest. Until `qjs-run.wasm` is rebuilt with the `Beam` global, this
      executes the guest through the existing Wasm seam for an effect (e.g. it can `Beam.send` via a
      host import); the message→callback re-entry is the documented wiring point. See design doc.
  """

  use GenServer
  require Logger

  alias TinyLasers.Wasm.Actor.Term

  @registry TinyLasers.Wasm.Actor.Registry
  @supervisor TinyLasers.Wasm.Actor.Supervisor

  # ── child specs the application supervisor must add (parent wires these — see integration notes) ──
  @doc """
  Supervision children for `application.ex`. The parent adds these to its child list:

      TinyLasers.Wasm.Actor.child_specs() ++ ...

  This starts the name registry + the dynamic supervisor that owns every guest actor (crash-isolated,
  `:one_for_one`, transient — a normal-exit guest is not restarted, a crashed one is per its policy).
  """
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]
  end

  # ── public host primitives (a Beam.* host import calls these) ────────────────────────────────────

  @doc """
  `Beam.spawn` — start a new supervised guest actor. `spec` is one of:
    * `{:fun, fun}`     — an Elixir `(msg, state) -> {reply, state}` handler (prototype / Elixir actors).
    * `{:js, script}`   — a JS guest script (real wiring; see module doc).
    * a bare function    — shorthand for `{:fun, fun}`.
  Opts: `:name` (register under a name for `Beam.send(name, …)` / `Beam.call`), `:state` (initial state),
  `:restart` (`:temporary` default — crash stays dead; `:transient`/`:permanent` to auto-restart).
  Returns `{:ok, handle}` where the handle is the actor's pid.
  """
  def beam_spawn(spec, opts \\ []) do
    spec = normalize_spec(spec)
    restart = Keyword.get(opts, :restart, :temporary)
    # the child notifies us when its (async, handle_continue) boot completes, so beam_spawn keeps
    # synchronous-spawn semantics (returns a READY actor) WITHOUT booting in init — booting in init would
    # deadlock the DynamicSupervisor when a guest spawns during its own boot (the supervisor is blocked
    # starting the parent). Parent + child boot in separate handle_continues, so the supervisor is free.
    opts = Keyword.put(opts, :boot_notify, self())

    child = %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [spec, opts]},
      restart: restart,
      type: :worker
    }

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, pid} -> wait_boot(pid); {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      err -> err
    end
  end

  # block until the freshly-spawned `pid` signals its boot is done (or a generous ceiling, so a pathological
  # guest can't wedge the spawner forever). Selective receive — other mailbox messages stay queued.
  defp wait_boot(pid) do
    receive do
      {:booted, ^pid} -> :ok
    after
      60_000 -> :ok
    end
  end

  @doc "`Beam.self()` — the running guest's handle. Inside an actor it's the actor pid; outside, the caller pid."
  def beam_self, do: Process.get(:tl_actor_self, self())

  @doc """
  `Beam.link(target)` — monitor `target` (pid handle or registered name) from the CALLING actor. When the
  peer dies, the caller receives a system message `%{"__exit" => handle, "reason" => reason}` into its
  handler (Erlang `trap_exit` semantics, surfaced to the guest as an ordinary delivery). Returns `:ok`.

  Implemented as a cast to the caller's own GenServer so the monitor is owned by the long-lived actor
  process (not the transient run context) and survives across messages.
  """
  def beam_link(target) do
    case beam_self() do
      pid when is_pid(pid) -> GenServer.cast(pid, {:beam_link, target}); :ok
      _ -> :error
    end
  end

  @doc """
  `setTimeout`/`setInterval` host hook — arm a BEAM timer `id` for `ms` ms on the CALLING actor. On fire
  the actor re-enters the guest via the `wb_timer` export (the async-completion contract, wb-5q8w).
  Cast to the owning GenServer so the timer is owned by the long-lived actor, not the run context.
  """
  def timer_set(id, ms) do
    case beam_self() do
      pid when is_pid(pid) -> GenServer.cast(pid, {:arm_timer, id, ms}); :ok
      _ -> :error
    end
  end

  @doc "`clearTimeout`/`clearInterval` host hook — cancel pending timer `id` on the calling actor."
  def timer_clear(id) do
    case beam_self() do
      pid when is_pid(pid) -> GenServer.cast(pid, {:disarm_timer, id}); :ok
      _ -> :error
    end
  end

  @doc """
  Resolve/reject async completion `id` on actor `pid` with `value` — the generic async-completion entry
  every I/O concern module (HostFs/HostNet/…) calls when its host op finishes. `ok?: true` resolves the
  guest promise, `false` rejects it. Safe to call from a Task (slow op) or inline (fast op); it just
  messages the owning actor, which re-enters the guest at wb_complete on its next mailbox turn.
  """
  def io_complete(pid, id, value, ok? \\ true) when is_pid(pid) do
    send(pid, {:io_complete, id, ok?, value})
    :ok
  end

  @doc """
  Deliver one STREAMING event to guest channel `channel` on actor `pid` (socket 'data'/'close', a file
  watcher, …) — the repeated-delivery sibling of `io_complete`. The actor re-enters the guest at the
  wb_event export, routing `{channel, event, value}` to the channel's handler. `value` is JSON-able
  (binary payloads come pre-base64'd by the concern).
  """
  def io_event(pid, channel, event, value) when is_pid(pid) do
    send(pid, {:io_event, channel, event, value})
    :ok
  end

  @doc """
  `Beam.send(pid, message)` — deliver `message` to actor `target`'s mailbox (asynchronous cast). `target`
  is a pid/handle or a registered name. The message is normalized to the shared term shape so what the
  receiver sees is exactly the JS-bridgeable value. Returns `:ok` (fire-and-forget, like `send/2`).
  """
  def beam_send(target, message) do
    case resolve(target) do
      nil -> {:error, :no_such_actor}
      pid -> GenServer.cast(pid, {:beam_msg, Term.normalize(message), beam_self()}); :ok
    end
  end

  @doc """
  `Beam.call(name, ...args)` — invoke a registered handler (an Elixir handler or another actor) and get
  the reply SYNCHRONOUSLY. `name` resolves through the registry; the args list is normalized across the
  boundary; the reply is normalized back. Times out (`5s` default) into `{:error, :timeout}` rather than
  hanging the caller.
  """
  def beam_call(name, args, timeout \\ 5_000) when is_list(args) do
    case resolve(name) do
      nil ->
        {:error, :no_such_handler}

      pid ->
        try do
          reply = GenServer.call(pid, {:beam_call, Enum.map(args, &Term.normalize/1), beam_self()}, timeout)
          {:ok, Term.normalize(reply)}
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, reason -> {:error, reason}
        end
    end
  end

  @doc "`Beam.processInfo()` — introspect a guest actor (reductions/memory/mailbox)."
  def process_info(target \\ nil) do
    pid = if target, do: resolve(target), else: beam_self()

    case pid && Process.info(pid, [:reductions, :memory, :message_queue_len]) do
      nil -> %{}
      info -> Map.new(info)
    end
  end

  @doc "`Beam.systemInfo()` — VM-wide introspection (process count, atom count, run queue)."
  def system_info do
    %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      atom_count: :erlang.system_info(:atom_count),
      run_queue: :erlang.statistics(:run_queue)
    }
  end

  @doc "List currently-registered actor names (introspection / tests)."
  def registered do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  # ── GenServer ─────────────────────────────────────────────────────────────────────────────────

  @doc false
  def start_link(spec, opts) do
    GenServer.start_link(__MODULE__, {spec, opts})
  end

  @impl true
  def init({spec, opts}) do
    case Keyword.get(opts, :name) do
      nil -> :ok
      name -> Registry.register(@registry, name, nil)
    end

    state = %{
      spec: spec,
      user: Keyword.get(opts, :state),
      on_message: nil,
      name: Keyword.get(opts, :name),
      # persistent guest instance (the JS backend's live QuickJS state); nil for fun-actors / unprovisioned JS
      instance: nil,
      # `Beam.link` monitors: monitor-ref => peer handle. On the peer's :DOWN we deliver a system
      # `%{"__exit" => handle, "reason" => ...}` message into the guest — Erlang trap_exit, JS-side.
      monitors: %{},
      # active JS timers: guest timer id => the Process.send_after ref (so clearTimeout can cancel).
      timers: %{},
      # who to notify ({:booted, self()}) when the deferred (handle_continue) boot finishes — lets the
      # spawner block until the actor is ready without booting in init (which would deadlock the supervisor).
      boot_notify: Keyword.get(opts, :boot_notify)
    }

    # Boot the guest in a continuation, NOT in init: a JS boot runs the full prelude (slow), and doing it
    # in init blocks the spawner's DynamicSupervisor.start_child — so a guest that calls Beam.spawn (e.g.
    # worker_threads) would stall/deadlock waiting on the child's boot. handle_continue runs immediately
    # after init returns (before any cast/call), so ordering is preserved while spawning stays instant.
    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    booted = boot(state)
    if state.boot_notify, do: send(state.boot_notify, {:booted, self()})
    {:noreply, booted}
  end

  @impl true
  def terminate(_reason, %{instance: inst}) when inst != nil do
    TinyLasers.Wasm.instance_free(inst)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_cast({:beam_msg, msg, from}, state) do
    {_reply, state} = deliver(state, msg, from)
    {:noreply, state}
  end

  @impl true
  def handle_call({:beam_call, args, from}, _gen_from, state) do
    {reply, state} = deliver(state, args, from)
    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:beam_link, target}, state) do
    case resolve(target) do
      nil ->
        {:noreply, state}

      pid ->
        ref = Process.monitor(pid)
        {:noreply, %{state | monitors: Map.put(state.monitors, ref, pid_handle(pid))}}
    end
  end

  @impl true
  def handle_cast({:arm_timer, id, ms}, state) do
    # re-arm (interval / re-set) cancels any prior ref for this id first
    case Map.get(state.timers, id) do
      nil -> :ok
      old -> Process.cancel_timer(old)
    end

    ref = Process.send_after(self(), {:timer_fire, id}, max(ms, 0))
    {:noreply, %{state | timers: Map.put(state.timers, id, ref)}}
  end

  @impl true
  def handle_cast({:disarm_timer, id}, state) do
    case Map.pop(state.timers, id) do
      {nil, _} -> {:noreply, state}
      {ref, timers} -> Process.cancel_timer(ref); {:noreply, %{state | timers: timers}}
    end
  end

  @impl true
  def handle_info({:timer_fire, id}, %{instance: inst} = state) when inst != nil do
    # the timer fired: drop its ref (a repeat timer re-arms itself from JS via __host_timer_set → arm_timer)
    # and re-enter the guest at wb_timer(id) — runs the JS callback, drains microtasks, threads the instance.
    state = %{state | timers: Map.delete(state.timers, id)}
    {:noreply, reenter_timer(state, id)}
  end

  def handle_info({:timer_fire, id}, state),
    do: {:noreply, %{state | timers: Map.delete(state.timers, id)}}

  @impl true
  def handle_info({:io_complete, id, ok?, value}, %{instance: inst} = state) when inst != nil do
    {:noreply, reenter_complete(state, id, ok?, value)}
  end

  def handle_info({:io_complete, _id, _ok?, _value}, state), do: {:noreply, state}

  @impl true
  def handle_info({:io_event, channel, event, value}, %{instance: inst} = state) when inst != nil do
    {:noreply, reenter_event(state, channel, event, value)}
  end

  def handle_info({:io_event, _channel, _event, _value}, state), do: {:noreply, state}

  # a server acceptor handed us a new connection: register it (→ socket id) and deliver a 'connection'
  # event on the listen channel; the guest then attaches a data channel (net_attach) which arms the conn.
  @impl true
  def handle_info({:net_conn, ch_listen, conn}, %{instance: inst} = state) when inst != nil do
    id = TinyLasers.Wasm.HostNet.register_conn(conn)
    {:noreply, reenter_event(state, ch_listen, "connection", %{"id" => id})}
  end

  def handle_info({:net_conn, _ch, conn}, state) do
    :gen_tcp.close(conn)
    {:noreply, state}
  end

  # :gen_tcp active-mode messages land here because the actor is the socket's controlling process. Route
  # them to the guest socket's event channel (sock→channel map kept by HostNet in this actor's pdict).
  @impl true
  def handle_info({:tcp, sock, data}, state) do
    case TinyLasers.Wasm.HostNet.channel_for(sock) do
      nil ->
        {:noreply, state}

      ch ->
        :inet.setopts(sock, active: :once)
        {:noreply, reenter_event(state, ch, "data", Base.encode64(data))}
    end
  end

  @impl true
  def handle_info({:tcp_closed, sock}, state) do
    ch = TinyLasers.Wasm.HostNet.channel_for(sock)
    TinyLasers.Wasm.HostNet.forget(sock)
    if ch, do: {:noreply, reenter_event(state, ch, "close", nil)}, else: {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_error, sock, reason}, state) do
    ch = TinyLasers.Wasm.HostNet.channel_for(sock)
    if ch, do: {:noreply, reenter_event(state, ch, "error", inspect(reason))}, else: {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {handle, monitors} ->
        # surface the peer's death to the guest as a normal delivery it can pattern-match on
        msg = %{"__exit" => handle, "reason" => inspect(reason)}
        {_reply, state} = deliver(%{state | monitors: monitors}, msg, self())
        {:noreply, state}
    end
  end

  # ── guest execution ─────────────────────────────────────────────────────────────────────────────

  # Boot is a no-op for the prototype backends. For the JS backend it runs the guest's setup ONCE and KEEPS
  # the instance alive: `_start` creates the QuickJS runtime/context, registers the `Beam` global, and evals
  # the script (which calls `Beam.onMessage(cb)` to register the callback) — then RETURNS WITHOUT freeing the
  # runtime (the rebuilt qjs-run.wasm stashes the JSContext* in a static; see JS-PERSISTENCE-DESIGN.md). The
  # captured `%Wasm.Instance{}` is the guest's durable QuickJS heap; per-message we re-enter it via
  # `wb_dispatch` so `let count=0` and closures survive across deliveries. Until qjs-run.wasm is rebuilt the
  # module won't export `wb_dispatch`; boot then leaves `instance: nil` and deliver falls back (see below).
  defp boot(%{spec: {:js, script}} = state) do
    prev = Process.get(:tl_actor_self)
    Process.put(:tl_actor_self, self())

    try do
      case qjs_run_mod() do
        nil ->
          state

        _mod ->
          # FAST BOOT (wb-8mdz.4): clone the shared template (QuickJS + the full prelude, booted ONCE) and
          # eval just THIS actor's script into the clone via wb_eval — instead of re-evaluating the whole
          # 25-module prelude per spawn. The script (registering Beam.onMessage etc.) is fed via the clone's
          # VFS at /work/main. Falls back to a from-scratch instance_start if wb_eval/template isn't available.
          case js_template() do
            nil ->
              set_js_ctx(script)

              case TinyLasers.Wasm.instance_start(qjs_run_mod(), "_start", [], fuel: 5_000_000_000) do
                {:ok, inst, _out} -> %{state | instance: inst}
                _ -> state
              end

            template ->
              inst = %{TinyLasers.Wasm.instance_clone(template) | vfs: %{"main" => script}}
              set_js_ctx(script)

              case TinyLasers.Wasm.instance_invoke(inst, "wb_eval", [], fuel: 5_000_000_000) do
                {:ok, _r, _o, inst2} -> %{state | instance: inst2}
                {:exit, _c, _o, inst2} -> %{state | instance: inst2}
                {:trap, _r, inst2} -> %{state | instance: inst2}
              end
          end
      end
    after
      if prev, do: Process.put(:tl_actor_self, prev), else: Process.delete(:tl_actor_self)
      clear_js_ctx()
    end
  end

  # The shared post-prelude TEMPLATE instance: boot qjs-run ONCE (QuickJS + every node module, empty
  # script), cache it, and clone it per actor (wb-8mdz.4). Cached in :persistent_term (the :atomics refs are
  # shared read-only; clone copies them). Returns nil if the wasm lacks wb_eval (falls back to full boot).
  defp js_template do
    case :persistent_term.get({__MODULE__, :js_template}, :none) do
      :none ->
        t =
          case qjs_run_mod() do
            nil ->
              nil

            mod ->
              if Map.has_key?(mod.exports, "wb_eval") do
                set_js_ctx("")

                case TinyLasers.Wasm.instance_start(mod, "_start", [], fuel: 5_000_000_000) do
                  {:ok, inst, _} -> inst
                  _ -> nil
                end
              end
          end

        :persistent_term.put({__MODULE__, :js_template}, t)
        t

      t ->
        t
    end
  end

  defp boot(state), do: state

  # Deliver one message run-to-completion. This is the GenServer-per-guest re-entry: set the process-dict
  # self handle (so a nested Beam.self/Beam.spawn/Beam.send inside the handler resolves correctly), run
  # the guest's handler, restore. Mirrors call_io's process-dict discipline.
  defp deliver(%{spec: {:fun, fun}} = state, msg, from) do
    prev = Process.get(:tl_actor_self)
    Process.put(:tl_actor_self, self())
    Process.put(:tl_actor_from, from)

    try do
      case apply_handler(fun, msg, state.user) do
        {reply, new_user} -> {Term.normalize(reply), %{state | user: new_user}}
        reply -> {Term.normalize(reply), state}
      end
    after
      if prev, do: Process.put(:tl_actor_self, prev), else: Process.delete(:tl_actor_self)
      Process.delete(:tl_actor_from)
    end
  end

  # JS backend: the documented wiring point. Until qjs-run.wasm carries the Beam global, we re-enter the
  # guest through Wasm with the message placed where the guest reads it. The MECHANISM (mailbox →
  # re-enter JS → run-to-completion → yield) is identical; only the in-guest callback dispatch awaits the
  # wasm rebuild. We expose the same self handle so a guest's Beam.send host import works today.
  defp deliver(%{spec: {:js, script}} = state, msg, from) do
    prev = Process.get(:tl_actor_self)
    Process.put(:tl_actor_self, self())
    Process.put(:tl_actor_from, from)
    # the delivered message is stashed where the guest's beam_recv host import reads it, so wb_dispatch()
    # pulls it and invokes the onMessage cb. We run the invoke IN THIS (owner) process, so the dict is read
    # directly (no Sandbox Task copy needed for the persistent path).
    Process.put(:tl_beam_inbox, Term.to_json(msg))
    set_js_ctx(script)

    try do
      case state.instance do
        # PERSISTENT PATH: re-enter the live QuickJS instance via the wb_dispatch export — NO script re-run,
        # so the guest's heap (vars/closures registered at boot) persists across messages. Thread the
        # (possibly memory-grown) instance handle forward.
        %TinyLasers.Wasm.Instance{} = inst ->
          case TinyLasers.Wasm.instance_invoke(inst, "wb_dispatch", [], fuel: 5_000_000_000) do
            {:ok, _r, _out, inst2} -> {Term.normalize(msg), %{state | instance: inst2}}
            {:exit, _c, _out, inst2} -> {Term.normalize(msg), %{state | instance: inst2}}
            {:trap, _reason, inst2} -> {Term.normalize(msg), %{state | instance: inst2}}
          end

        # FALLBACK (qjs-run.wasm not yet rebuilt with persistent setup): re-run the whole script per message
        # via the Sandbox. State does NOT persist on this path (documented limitation until the rebuild).
        nil ->
          qjs = qjs_run_wasm()

          if qjs do
            TinyLasers.Wasm.Sandbox.run_command(
              {:interp, qjs, script <> "\n;__beam_dispatch();"},
              "",
              fuel: 5_000_000_000,
              timeout_ms: 30_000
            )
          end

          {Term.normalize(msg), state}
      end
    after
      Process.delete(:tl_beam_inbox)
      clear_js_ctx()
      if prev, do: Process.put(:tl_actor_self, prev), else: Process.delete(:tl_actor_self)
      Process.delete(:tl_actor_from)
    end
  end

  # Re-enter the live guest instance at the wb_timer(id) export when a BEAM timer fires. Same process-dict
  # discipline as deliver/3's instance path (self handle + js ctx so a callback's Beam.*/setTimeout resolve),
  # threading the (possibly memory-grown) instance forward. No-op if the wasm lacks the wb_timer export.
  defp reenter_timer(%{spec: {:js, script}, instance: %TinyLasers.Wasm.Instance{} = inst} = state, id) do
    prev = Process.get(:tl_actor_self)
    Process.put(:tl_actor_self, self())
    set_js_ctx(script)

    try do
      case TinyLasers.Wasm.instance_invoke(inst, "wb_timer", [id], fuel: 5_000_000_000) do
        {:ok, _r, _out, inst2} -> %{state | instance: inst2}
        {:exit, _c, _out, inst2} -> %{state | instance: inst2}
        {:trap, _reason, inst2} -> %{state | instance: inst2}
      end
    after
      clear_js_ctx()
      if prev, do: Process.put(:tl_actor_self, prev), else: Process.delete(:tl_actor_self)
    end
  end

  defp reenter_timer(state, _id), do: state

  # Re-enter the live guest at wb_complete to resolve/reject async completion `id` with `value`. Stashes
  # the {id,ok,value} envelope where __io_recv reads it, then invokes the export (same discipline as
  # reenter_timer). This is the host side of the generic async-completion contract (wb-5q8w).
  defp reenter_complete(%{spec: {:js, script}, instance: %TinyLasers.Wasm.Instance{} = inst} = state, id, ok?, value) do
    envelope = Term.to_json(%{"id" => id, "ok" => ok?, "value" => value})
    prev = Process.get(:tl_actor_self)
    Process.put(:tl_actor_self, self())
    Process.put(:tl_io_inbox, envelope)
    set_js_ctx(script)

    try do
      case TinyLasers.Wasm.instance_invoke(inst, "wb_complete", [], fuel: 5_000_000_000) do
        {:ok, _r, _out, inst2} -> %{state | instance: inst2}
        {:exit, _c, _out, inst2} -> %{state | instance: inst2}
        {:trap, _reason, inst2} -> %{state | instance: inst2}
      end
    after
      Process.delete(:tl_io_inbox)
      clear_js_ctx()
      if prev, do: Process.put(:tl_actor_self, prev), else: Process.delete(:tl_actor_self)
    end
  end

  defp reenter_complete(state, _id, _ok?, _value), do: state

  # Re-enter the live guest at wb_event to deliver one streaming event to channel `channel`. Mirrors
  # reenter_complete; the host side of the event-channel contract (wb-5q8w). Net 'data'/'close' use this.
  defp reenter_event(%{spec: {:js, script}, instance: %TinyLasers.Wasm.Instance{} = inst} = state, channel, event, value) do
    envelope = Term.to_json(%{"channel" => channel, "event" => event, "value" => value})
    prev = Process.get(:tl_actor_self)
    Process.put(:tl_actor_self, self())
    Process.put(:tl_io_inbox, envelope)
    set_js_ctx(script)

    try do
      case TinyLasers.Wasm.instance_invoke(inst, "wb_event", [], fuel: 5_000_000_000) do
        {:ok, _r, _out, inst2} -> %{state | instance: inst2}
        {:exit, _c, _out, inst2} -> %{state | instance: inst2}
        {:trap, _reason, inst2} -> %{state | instance: inst2}
      end
    after
      Process.delete(:tl_io_inbox)
      clear_js_ctx()
      if prev, do: Process.put(:tl_actor_self, prev), else: Process.delete(:tl_actor_self)
    end
  end

  defp reenter_event(state, _channel, _event, _value), do: state

  # set / clear the per-run guest context a Wasm run needs (argv/stdin/vfs/fds) when we drive the guest
  # IN-PROCESS (instance_start / instance_invoke), not via the Sandbox harness. The script is the program.
  defp set_js_ctx(script) do
    Process.put(:tl_stdin, "")
    Process.put(:tl_argv, ["qjs", "/work/main"])
    Process.put(:tl_vfs, %{"main" => script})
    Process.put(:tl_backend, :map)
    Process.put(:tl_fds, %{})
    Process.put(:tl_nextfd, 4)
  end

  defp clear_js_ctx do
    Enum.each([:tl_stdin, :tl_argv, :tl_vfs, :tl_backend, :tl_fds, :tl_nextfd], &Process.delete/1)
  end

  # the generic QuickJS runner module the JS actor re-enters (decoded); nil if the JS lane isn't provisioned.
  defp qjs_run_mod do
    case qjs_run_wasm() do
      nil -> nil
      bytes -> case TinyLasers.Wasm.decode_cached(bytes), do: ({:ok, m} -> m; _ -> nil)
    end
  end

  # the generic QuickJS runner (qjs-run.wasm) the JS actor re-enters; nil if the JS lane isn't provisioned.
  defp qjs_run_wasm do
    [Path.join([:code.priv_dir(:nexus), "..", "compilers", "js", "qjs-run.wasm"]), "compilers/js/qjs-run.wasm"]
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> nil
      path -> File.read!(path)
    end
  end

  defp apply_handler(fun, msg, user) when is_function(fun, 2), do: fun.(msg, user)
  defp apply_handler(fun, msg, _user) when is_function(fun, 1), do: fun.(msg)

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────────

  defp normalize_spec(fun) when is_function(fun), do: {:fun, fun}
  defp normalize_spec({:fun, _} = s), do: s
  defp normalize_spec({:js, _} = s), do: s

  # encode a pid as a stable string handle (same scheme as TinyLasers.Wasm.pid_handle, so handles are
  # interchangeable across the host bridge and the actor layer).
  defp pid_handle(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> to_string()
  defp pid_handle(other), do: to_string(other)

  defp resolve(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid, else: nil)

  defp resolve(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
