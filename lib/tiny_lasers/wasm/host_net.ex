defmodule TinyLasers.Wasm.HostNet do
  @moduledoc """
  The `net`/`dns` concern (wb-rfqv) — Node TCP sockets over Erlang `:gen_tcp`, the shared socket seam with
  WASIX §3. Idiomatic BEAM: a socket is opened in **active: :once** mode from the OWNING guest actor, which
  becomes the socket's controlling process — so incoming `{:tcp, sock, data}` / `{:tcp_closed, sock}` land
  directly in the actor mailbox (no reader Task) and the actor routes them to the guest's event channel
  (`reenter_event` → `wb_event`), emitting `'data'`/`'close'`. Per-message `active: :once` re-arm gives
  natural backpressure. State (id↔socket, socket→channel) lives in the actor's process dict — `call/2` and
  the actor's `handle_info` run in the SAME process, so the maps are shared without ETS.

  Routed here because import names are `net_*`. `dns` is folded in as `net_resolve` (one concern module).
  """

  @connect_timeout 10_000

  def call("net_open", [host, port, channel]) do
    opts = [:binary, active: :once, packet: :raw]

    case :gen_tcp.connect(to_charlist(host), port, opts, @connect_timeout) do
      {:ok, sock} ->
        id = next_id()
        put_sock(id, sock)
        put_channel(sock, channel)
        %{"ok" => true, "id" => id}

      {:error, reason} ->
        %{"ok" => false, "err" => inspect(reason)}
    end
  end

  def call("net_write", [id, b64]) do
    case get_sock(id) do
      nil -> %{"ok" => false, "err" => "ENOTCONN"}
      sock -> %{"ok" => :gen_tcp.send(sock, Base.decode64!(b64)) == :ok}
    end
  end

  def call("net_close", [id]) do
    case get_sock(id) do
      nil ->
        %{"ok" => true}

      sock ->
        :gen_tcp.close(sock)
        forget(sock)
        del_sock(id)
        %{"ok" => true}
    end
  end

  # net.Server.listen — open a listen socket + an acceptor that hands each accepted conn to the owning
  # actor (controlling process), which delivers a 'connection' event on ch_listen. The accepted conn stays
  # PASSIVE until the guest attaches its own data channel (net_attach), so no inbound bytes are lost.
  def call("net_listen", [port, ch_listen]) do
    actor = TinyLasers.Wasm.Actor.beam_self()

    case :gen_tcp.listen(port, [:binary, active: false, packet: :raw, reuseaddr: true]) do
      {:ok, lsock} ->
        id = next_id()
        put_sock(id, lsock)
        spawn_link(fn -> accept_loop(lsock, actor, ch_listen) end)
        {:ok, real} = :inet.port(lsock)
        %{"ok" => true, "id" => id, "port" => real}

      {:error, reason} ->
        %{"ok" => false, "err" => inspect(reason)}
    end
  end

  # bind an accepted connection (registered by the actor as `id`) to its guest data channel + arm it.
  def call("net_attach", [id, ch_data]) do
    case get_sock(id) do
      nil ->
        %{"ok" => false}

      conn ->
        put_channel(conn, ch_data)
        :inet.setopts(conn, active: :once)
        %{"ok" => true}
    end
  end

  defp accept_loop(lsock, actor, ch_listen) do
    case :gen_tcp.accept(lsock) do
      {:ok, conn} ->
        :gen_tcp.controlling_process(conn, actor)
        send(actor, {:net_conn, ch_listen, conn})
        accept_loop(lsock, actor, ch_listen)

      {:error, _} ->
        :ok
    end
  end

  @doc "Allocate a socket id for an accepted connection (called by the owning actor's handle_info)."
  def register_conn(conn) do
    id = next_id()
    put_sock(id, conn)
    id
  end

  # dns.lookup — resolve a hostname to its first address via the host resolver.
  def call("net_resolve", [host]) do
    case :inet.gethostbyname(to_charlist(host)) do
      {:ok, {:hostent, _n, _a, _f, _l, [addr | _]}} ->
        %{"ok" => true, "address" => addr |> :inet.ntoa() |> to_string()}

      _ ->
        %{"ok" => false, "err" => "ENOTFOUND"}
    end
  end

  # ── routing helpers used by the owning actor's handle_info ({:tcp,...}) ─────────────────────────────
  @doc "Guest event-channel id bound to `sock`, or nil."
  def channel_for(sock), do: Map.get(Process.get(:washy_net_chan, %{}), sock)

  @doc "Drop `sock` from the channel map (on close)."
  def forget(sock) do
    Process.put(:washy_net_chan, Map.delete(Process.get(:washy_net_chan, %{}), sock))
    :ok
  end

  # ── id ↔ socket ↔ channel maps in the owning actor's process dict ───────────────────────────────────
  defp next_id do
    n = Process.get(:washy_net_nextid, 1)
    Process.put(:washy_net_nextid, n + 1)
    n
  end

  defp put_sock(id, sock),
    do: Process.put(:washy_net_socks, Map.put(Process.get(:washy_net_socks, %{}), id, sock))

  defp get_sock(id), do: Map.get(Process.get(:washy_net_socks, %{}), id)

  defp del_sock(id),
    do: Process.put(:washy_net_socks, Map.delete(Process.get(:washy_net_socks, %{}), id))

  defp put_channel(sock, ch),
    do: Process.put(:washy_net_chan, Map.put(Process.get(:washy_net_chan, %{}), sock, ch))
end
