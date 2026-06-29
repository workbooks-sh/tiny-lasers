defmodule TinyLasers.Wasm.HostSock do
  @moduledoc """
  The WASIX §3 BSD-socket surface (wb-j9op) — the `sock_*` host ABI that native C/Rust crates
  (tokio / mio / hyper / std::net on `wasm32-wasix`) lower to. This is the HOST half of the socket
  syscalls; the guest call-site (interpreter OR asm lane) lowers to `call_ext invoke_host`, so one
  impl here serves both lanes.

  ## State model — ONE home: the unified FdTable + a `:washy_sockstate` map
  A socket fd is `FdTable.alloc(%{kind: :socket, ref: id})` where `ref` is an integer id into the
  process-dict `:washy_sockstate` map. The state lives in the map (not in the desc) because the
  transport is a `:gen_tcp`/`:gen_udp` **port** that must be *shared* across `dup`'d fds and only
  torn down on the LAST close — exactly the refcount the FdTable desc already tracks. Keeping the
  port behind a stable id lets several descs alias one transport without copying the port.

  A socket-state entry:
      %{transport: port | nil,          # the :gen_tcp / :gen_udp socket, nil until bound/connected
        kind: :stream | :dgram,         # tcp / udp
        state: :unbound|:bound|:listening|:connected,
        rbuf: binary,                   # bytes peeked by poll_oneoff, drained first by sock_recv
        laddr: {ip, port} | nil,        # local addr (filled at bind/listen/connect)
        raddr: {ip, port} | nil,        # remote addr (filled at connect/accept)
        backlog: int,
        acceptq: [port]}                # accepted transports peeked by poll, consumed by sock_accept

  FdTable's teardown hook (`:washy_sock`) closes the transport on last close — we install it from
  `TinyLasers.Wasm.HostSock.install/0` so `FdTable.close/1` frees the port without knowing our internals.

  ## `__wasi_addr_port_t` memory layout (VERIFIED against wasix-libc — DOCUMENTED)
  `__wasi_addr_port_t { uint8_t tag; __wasi_addr_port_u_t u; }` with `_Alignof == 2`, so the union
  (which contains `__wasi_addr_ip4_port_t { __wasi_ip_port_t port@0; __wasi_addr_ip4_t addr@2; }`,
  itself align-2) starts at byte 2 — a 1-byte pad@1. Hence:
      off 0  : u8  tag        — 0 = UNSPEC, 1 = INET4, 2 = INET6 (the `__WASI_ADDRESS_FAMILY_*`
                                enum values — NOT the BSD AF_INET/AF_INET6 numbers; getsockname's
                                libc shim drops the addr to port 0 unless tag is exactly 1/2)
      off 2  : u16 port       — host byte order; libc applies htons/ntohs to/from sin_port
      off 4  : 16 bytes addr  — IPv4 uses the first 4 bytes (a.b.c.d), IPv6 uses all 16
  Round-trip verified by a non-threaded C getsockname probe (bind 0 → getsockname → port>0 ? 42 : 3).
  If a guest disagrees we adjust the offsets/tags in ONE place (`read_addr/2` + `write_addr/3`).

  ## errno values — the WASIX/wasi-libc integers already used across washy.ex
      EBADF 8 · EINVAL 28 · EAGAIN/EWOULDBLOCK 6 · ECONNREFUSED 14 · ENOTCONN 53 ·
      EADDRNOTAVAIL 3 · ETIMEDOUT 73 · success 0
  Bounded timeouts ONLY (never an infinite block — project rule): accept/recv cap at @block_ms.
  """

  alias TinyLasers.Wasm.FdTable
  import TinyLasers.Wasm, only: [read_bytes: 3, write_bytes: 3]

  # ── errno (WASIX) ────────────────────────────────────────────────────────────────────────────
  @e_ok 0
  @e_again 6
  @e_badf 8
  @e_inval 28
  @e_connrefused 14
  @e_timedout 73

  # bounded blocking cap for accept/recv/connect (never hang the BEAM process).
  @block_ms 30_000
  @connect_ms 10_000

  @sockstate :washy_sockstate
  @socknext :washy_socknext

  # ── install the FdTable teardown hook so close() frees our transport on last ref ───────────────
  @doc "Install the `:washy_sock` teardown hook used by FdTable.close/1 (idempotent)."
  def install do
    Process.put(:washy_sock, fn
      {:close, id} -> teardown(id)
      _ -> :ok
    end)

    :ok
  end

  # ── socket-state store (process dict, one map keyed by id) ────────────────────────────────────
  defp store, do: Process.get(@sockstate, %{})
  defp put_store(m), do: Process.put(@sockstate, m)

  defp new_state(attrs) do
    id = Process.get(@socknext, 0)
    Process.put(@socknext, id + 1)

    s =
      Map.merge(
        %{transport: nil, kind: :stream, state: :unbound, rbuf: "", laddr: nil, raddr: nil,
          backlog: 0, acceptq: []},
        attrs
      )

    put_store(Map.put(store(), id, s))
    id
  end

  defp get_state(id), do: Map.get(store(), id)
  defp put_state(id, s), do: put_store(Map.put(store(), id, s))

  # state behind a socket fd, with its id, or nil.
  defp fd_state(fd) do
    case FdTable.get(fd) do
      %{kind: :socket, ref: id} -> (s = get_state(id)) && {id, s}
      _ -> nil
    end
  end

  defp teardown(id) do
    case get_state(id) do
      %{transport: t, kind: kind} when t != nil ->
        if kind == :dgram, do: :gen_udp.close(t), else: :gen_tcp.close(t)

      _ ->
        :ok
    end

    put_store(Map.delete(store(), id))
    :ok
  end

  # ── sock_open(af, socktype, protocol, fd_out_ptr) ─────────────────────────────────────────────
  # socktype 1 = STREAM (tcp), 2 = DGRAM (udp). Allocates an UNBOUND socket fd, no transport yet.
  def open(mem, _af, socktype, _protocol, fd_out_ptr) do
    install()
    kind = if socktype == 2, do: :dgram, else: :stream
    id = new_state(%{kind: kind, state: :unbound})
    fd = FdTable.alloc(%{kind: :socket, ref: id})
    store32(mem, fd_out_ptr, fd)
    @e_ok
  end

  # ── sock_bind(fd, addr_ptr) ───────────────────────────────────────────────────────────────────
  # TCP: record laddr (the real bind happens at listen/connect via gen_tcp opts).
  # UDP: open the dgram socket NOW on the requested port (so recvfrom works on an unconnected dgram).
  def bind(mem, fd, addr_ptr) do
    with {id, s} <- fd_state(fd),
         {_tag, ip, port} <- read_addr(mem, addr_ptr) do
      case s.kind do
        :dgram ->
          case :gen_udp.open(port, [:binary, active: false, reuseaddr: true]) do
            {:ok, t} ->
              {:ok, real} = :inet.port(t)
              put_state(id, %{s | transport: t, state: :bound, laddr: {ip, real}})
              @e_ok

            {:error, _} ->
              @e_inval
          end

        :stream ->
          # TCP defers the OS bind to listen, but getsockname/sock_addr_local after bind(0) must report
          # the ASSIGNED ephemeral port (loopback servers bind 0 → getsockname → connect). Eagerly open the
          # listen socket here to reserve the port (port 0 → OS-assigned ephemeral); listen/2 just activates
          # it. (Found by the §8 oracle: a C TCP-loopback server got port 0 from getsockname.)
          case :gen_tcp.listen(port, [:binary, active: false, packet: :raw, reuseaddr: true]) do
            {:ok, lsock} ->
              {:ok, real} = :inet.port(lsock)
              put_state(id, %{s | transport: lsock, state: :bound, laddr: {ip, real}})
              @e_ok

            {:error, _} ->
              @e_inval
          end
      end
    else
      _ -> @e_badf
    end
  end

  # ── sock_listen(fd, backlog) ──────────────────────────────────────────────────────────────────
  def listen(_mem, fd, backlog) do
    case fd_state(fd) do
      # bind already opened the listen socket (to reserve the ephemeral port) — just activate it.
      {id, %{kind: :stream, transport: t} = s} when t != nil ->
        put_state(id, %{s | state: :listening, backlog: backlog})
        @e_ok

      {id, %{kind: :stream, laddr: laddr} = s} ->
        port = (laddr && elem(laddr, 1)) || 0
        opts = [:binary, active: false, packet: :raw, reuseaddr: true, backlog: max(backlog, 0)]

        case :gen_tcp.listen(port, opts) do
          {:ok, lsock} ->
            {:ok, real} = :inet.port(lsock)
            put_state(id, %{s | transport: lsock, state: :listening, backlog: backlog,
                            laddr: {laddr && elem(laddr, 0) || {0, 0, 0, 0}, real}})
            @e_ok

          {:error, _} ->
            @e_inval
        end

      _ ->
        @e_badf
    end
  end

  # ── sock_accept(fd, fd_flags, ro_fd_ptr, ro_addr_ptr) ─────────────────────────────────────────
  # NONBLOCK + no pending conn → EAGAIN; else bounded accept. Consumes the poll-peeked acceptq first.
  def accept(mem, fd, _fd_flags, ro_fd_ptr, ro_addr_ptr) do
    case fd_state(fd) do
      {id, %{kind: :stream, transport: lsock, state: :listening, acceptq: q} = s} when lsock != nil ->
        nb = FdTable.nonblock?(fd)

        {conn, q2} =
          case q do
            [c | rest] -> {{:ok, c}, rest}
            [] -> {:gen_tcp.accept(lsock, if(nb, do: 0, else: @block_ms)), []}
          end

        put_state(id, %{s | acceptq: q2})

        case conn do
          {:ok, c} ->
            {:ok, {rip, rport}} = :inet.peername(c)
            cid = new_state(%{kind: :stream, transport: c, state: :connected, raddr: {rip, rport}})
            cfd = FdTable.alloc(%{kind: :socket, ref: cid})
            store32(mem, ro_fd_ptr, cfd)
            if ro_addr_ptr != 0, do: write_addr(mem, ro_addr_ptr, {rip, rport})
            @e_ok

          {:error, :timeout} ->
            if nb, do: @e_again, else: @e_timedout

          {:error, _} ->
            @e_again
        end

      _ ->
        @e_badf
    end
  end

  # ── sock_connect(fd, addr_ptr) ────────────────────────────────────────────────────────────────
  def connect(mem, fd, addr_ptr) do
    with {id, s} <- fd_state(fd),
         {_tag, ip, port} <- read_addr(mem, addr_ptr) do
      if s.kind == :dgram do
        # "connecting" a dgram socket just fixes its default peer (raddr) for send/recv.
        put_state(id, %{s | state: :connected, raddr: {ip, port}})
        @e_ok
      else
        do_connect(id, s, ip, port)
      end
    else
      _ -> @e_badf
    end
  end

  defp do_connect(id, s, ip, port) do
    host = ip_to_connect_arg(ip)

    case :gen_tcp.connect(host, port, [:binary, active: false, packet: :raw], @connect_ms) do
        {:ok, t} ->
          {:ok, laddr} = :inet.sockname(t)
          put_state(id, %{s | transport: t, state: :connected, raddr: {ip, port}, laddr: laddr})
          @e_ok

        {:error, :econnrefused} ->
          @e_connrefused

        {:error, :timeout} ->
          @e_timedout

        {:error, _} ->
          @e_inval
      end
  end

  # ── sock_send(fd, si_data_ptr, si_data_len, si_flags, ro_datalen_ptr) ─────────────────────────
  # si_data is an array of __wasi_ciovec_t {buf:u32, len:u32} — same 8-byte iovec layout as fd_write.
  def send(mem, fd, si_data_ptr, si_data_len, _si_flags, ro_datalen_ptr) do
    case fd_state(fd) do
      {_id, %{transport: t, kind: kind, raddr: raddr} = _s} when t != nil ->
        data = gather(mem, si_data_ptr, si_data_len)

        res =
          case kind do
            :dgram ->
              case raddr do
                {ip, port} -> :gen_udp.send(t, ip, port, data)
                _ -> {:error, :enotconn}
              end

            :stream ->
              :gen_tcp.send(t, data)
          end

        case res do
          :ok -> store32(mem, ro_datalen_ptr, byte_size(data)); @e_ok
          {:error, _} -> @e_inval
        end

      _ ->
        @e_badf
    end
  end

  # ── POSIX write()/read() on a socket fd (fd_write/fd_read route here) ─────────────────────────
  # Native code treats a connected socket fd interchangeably with send()/recv(). These mirror the
  # send/recv transport paths but take/return a raw binary (the fd_write/fd_read host clauses own the
  # iovec gather/scatter + nwritten/nread store). DRY: same :gen_tcp/:gen_udp calls as send/2 & recv/2.
  @doc "Send a raw binary on socket `fd`'s transport (POSIX write() on a socket)."
  def fd_send(_mem, fd, data) do
    case fd_state(fd) do
      {_id, %{transport: t, kind: :dgram, raddr: {ip, port}}} when t != nil ->
        :gen_udp.send(t, ip, port, data)

      {_id, %{transport: t, kind: :stream}} when t != nil ->
        :gen_tcp.send(t, data)

      _ ->
        :ok
    end

    :ok
  end

  @doc "Receive up to `cap` bytes from socket `fd`'s transport (POSIX read() on a socket). \"\" on EOF."
  def fd_recv(fd, cap) do
    case fd_state(fd) do
      {id, %{transport: t, kind: kind, rbuf: rbuf} = s} when t != nil ->
        nb = FdTable.nonblock?(fd)

        cond do
          rbuf != "" ->
            take = min(cap, byte_size(rbuf))
            <<chunk::binary-size(take), rest::binary>> = rbuf
            put_state(id, %{s | rbuf: rest})
            chunk

          true ->
            res =
              case kind do
                :dgram -> :gen_udp.recv(t, cap, if(nb, do: 0, else: @block_ms))
                :stream -> :gen_tcp.recv(t, 0, if(nb, do: 0, else: @block_ms))
              end

            case res do
              {:ok, {_addr, _port, data}} -> data
              {:ok, data} when is_binary(data) or is_list(data) -> IO.iodata_to_binary(data)
              _ -> ""
            end
        end

      _ ->
        ""
    end
  end

  # ── sock_recv(fd, ri_data_ptr, ri_data_len, ri_flags, ro_datalen_ptr, ro_flags_ptr) ───────────
  # Drain rbuf (poll may have peeked) first; then bounded recv. NONBLOCK+no data → EAGAIN; EOF → 0.
  def recv(mem, fd, ri_data_ptr, ri_data_len, _ri_flags, ro_datalen_ptr, ro_flags_ptr) do
    case fd_state(fd) do
      {id, %{transport: t, kind: kind, rbuf: rbuf} = s} when t != nil ->
        nb = FdTable.nonblock?(fd)
        cap = iov_capacity(mem, ri_data_ptr, ri_data_len)

        cond do
          rbuf != "" ->
            take = min(cap, byte_size(rbuf))
            <<chunk::binary-size(take), rest::binary>> = rbuf
            put_state(id, %{s | rbuf: rest})
            finish_recv(mem, ri_data_ptr, ri_data_len, ro_datalen_ptr, ro_flags_ptr, chunk)

          true ->
            recv_fn =
              case kind do
                :dgram -> fn -> :gen_udp.recv(t, cap, if(nb, do: 0, else: @block_ms)) end
                :stream -> fn -> :gen_tcp.recv(t, 0, if(nb, do: 0, else: @block_ms)) end
              end

            case recv_fn.() do
              # dgram recv → {:ok, {addr, port, data}}
              {:ok, {_addr, _port, data}} ->
                finish_recv(mem, ri_data_ptr, ri_data_len, ro_datalen_ptr, ro_flags_ptr, data)

              {:ok, data} when is_binary(data) or is_list(data) ->
                finish_recv(mem, ri_data_ptr, ri_data_len, ro_datalen_ptr, ro_flags_ptr,
                  IO.iodata_to_binary(data))

              {:error, :closed} ->
                finish_recv(mem, ri_data_ptr, ri_data_len, ro_datalen_ptr, ro_flags_ptr, "")

              {:error, :timeout} ->
                if nb, do: @e_again, else: @e_timedout

              {:error, _} ->
                @e_inval
            end
        end

      _ ->
        @e_badf
    end
  end

  defp finish_recv(mem, ri_data_ptr, ri_data_len, ro_datalen_ptr, ro_flags_ptr, data) do
    n = scatter(mem, ri_data_ptr, ri_data_len, data)
    store32(mem, ro_datalen_ptr, n)
    if ro_flags_ptr != 0, do: store16(mem, ro_flags_ptr, 0)
    @e_ok
  end

  # ── sock_shutdown(fd, how) ────────────────────────────────────────────────────────────────────
  # how: 1 = rd (SHUT_RD), 2 = wr (SHUT_WR), 3 = rdwr. (WASIX __wasi_sdflags_t bitmask: RD=1, WR=2.)
  def shutdown(_mem, fd, how) do
    case fd_state(fd) do
      {_id, %{transport: t, kind: :stream}} when t != nil ->
        side =
          case how do
            1 -> :read
            2 -> :write
            _ -> :read_write
          end

        case :gen_tcp.shutdown(t, side) do
          :ok -> @e_ok
          {:error, _} -> @e_inval
        end

      _ ->
        @e_badf
    end
  end

  # ── sock_addr_local / sock_addr_remote ────────────────────────────────────────────────────────
  def addr_local(mem, fd, ro_addr_ptr) do
    case fd_state(fd) do
      {_id, %{laddr: {ip, port}}} -> write_addr(mem, ro_addr_ptr, {ip, port}); @e_ok
      {_id, %{transport: t}} when t != nil ->
        case :inet.sockname(t) do
          {:ok, {ip, port}} -> write_addr(mem, ro_addr_ptr, {ip, port}); @e_ok
          _ -> @e_inval
        end
      _ -> @e_badf
    end
  end

  def addr_remote(mem, fd, ro_addr_ptr) do
    case fd_state(fd) do
      {_id, %{raddr: {ip, port}}} -> write_addr(mem, ro_addr_ptr, {ip, port}); @e_ok
      {_id, %{transport: t}} when t != nil ->
        case :inet.peername(t) do
          {:ok, {ip, port}} -> write_addr(mem, ro_addr_ptr, {ip, port}); @e_ok
          _ -> @e_inval
        end
      _ -> @e_badf
    end
  end

  # ── sock_addr_resolve(host_ptr, host_len, port, ro_addrs_ptr, naddrs, ro_naddrs_ptr) ──────────
  # WASIX resolve: write up to `naddrs` __wasi_addr_port_t (20 bytes each) into ro_addrs_ptr,
  # store the count at ro_naddrs_ptr. We use :inet.getaddrinfo for v4+v6. (Closest documented form;
  # NOTE in the comment — the exact WASIX resolve ABI varies by libc rev, we match the addr-array
  # shape tokio/mio expect.)
  def addr_resolve(mem, host_ptr, host_len, port, ro_addrs_ptr, naddrs, ro_naddrs_ptr) do
    host = read_bytes(mem, host_ptr, host_len) |> to_charlist()

    # :inet.getaddrs returns the resolved IP tuples (v4 and/or v6). Try both families.
    addrs =
      (case :inet.getaddrs(host, :inet) do
         {:ok, v4} -> v4
         _ -> []
       end ++
         case :inet.getaddrs(host, :inet6) do
           {:ok, v6} -> v6
           _ -> []
         end)
      |> Enum.uniq()

    if addrs == [] do
      store32(mem, ro_naddrs_ptr, 0)
      @e_inval
    else
      written =
        addrs
        |> Enum.take(max(naddrs, 0))
        |> Enum.with_index()
        |> Enum.map(fn {ip, i} -> write_addr(mem, ro_addrs_ptr + i * 20, {ip, port}); ip end)
        |> length()

      store32(mem, ro_naddrs_ptr, written)
      @e_ok
    end
  end

  # ── poll readiness (called from FdTable.readable?/1 for kind: :socket) ────────────────────────
  # Peek the transport with timeout 0; stash any bytes into rbuf so sock_recv drains them. For a
  # listening socket, "readable" = a pending connection (accept with timeout 0 → stash in acceptq).
  def readable(id) do
    case get_state(id) do
      %{state: :listening, transport: lsock, acceptq: q} = s when lsock != nil ->
        cond do
          q != [] ->
            {true, 1, false}

          true ->
            case :gen_tcp.accept(lsock, 0) do
              {:ok, c} -> put_state(id, %{s | acceptq: q ++ [c]}); {true, 1, false}
              _ -> {false, 0, false}
            end
        end

      %{transport: t, kind: :stream, rbuf: rbuf} = s when t != nil ->
        cond do
          rbuf != "" ->
            {true, byte_size(rbuf), false}

          true ->
            case :gen_tcp.recv(t, 0, 0) do
              {:ok, data} ->
                bin = IO.iodata_to_binary(data)
                put_state(id, %{s | rbuf: rbuf <> bin})
                {true, byte_size(rbuf) + byte_size(bin), false}

              {:error, :closed} ->
                {true, 0, true}

              _ ->
                {false, 0, false}
            end
        end

      %{transport: t, kind: :dgram} when t != nil ->
        case :gen_udp.recv(t, 0, 0) do
          {:ok, _} -> {true, 1, false}
          _ -> {false, 0, false}
        end

      _ ->
        {false, 0, false}
    end
  end

  # ── poll_oneoff true-blocking support (wb-clmb) ───────────────────────────────────────────────
  # poll_oneoff's "nothing immediately ready" branch ARMS each socket fd_read sub for a single
  # mailbox readiness event, then does a bounded selective `receive`. These helpers bridge the
  # fd↔transport↔state mapping it needs. Sockets are normally `{active: false}` (passive) so recv
  # peeks them; arming flips to `active: :once`, which delivers ONE `{:tcp, port, data}` (or
  # `{:tcp_closed,port}` / `{:tcp_error,port,_}`) to the controlling process — `self()` during the
  # synchronous host call (the guest's actor process). After delivery the socket reverts to passive.

  @doc "The transport `:gen_tcp` port behind socket `fd`, or nil (not a connected stream socket)."
  def transport_of(fd) do
    case fd_state(fd) do
      {_id, %{transport: t, kind: :stream}} when t != nil -> t
      _ -> nil
    end
  end

  @doc """
  Arm socket `fd` for a single mailbox readiness event (`:inet.setopts(transport, active: :once)`).
  Returns the transport port (so poll_oneoff can build its armed-port set), or nil if there is no
  live transport. Tolerates an already-closed socket (setopts errors are swallowed → returns the
  port anyway only when setopts succeeded; on failure returns nil so poll treats it as un-armable).
  """
  def arm_readable(fd) do
    case transport_of(fd) do
      nil -> nil
      t -> if :inet.setopts(t, [active: :once]) == :ok, do: t, else: nil
    end
  end

  @doc """
  Deliver bytes that arrived via an armed-socket `{:tcp, port, data}` message: stash them into the
  matching socket-state's `rbuf` so the subsequent `sock_recv` drains them (the SAME rbuf path
  `readable/1` uses). No-op if the port isn't one of our sockets.
  """
  def deliver(port, data) do
    bin = IO.iodata_to_binary(data)

    case Enum.find(store(), fn {_id, s} -> s.transport == port end) do
      {id, s} -> put_state(id, %{s | rbuf: s.rbuf <> bin}); :ok
      _ -> :ok
    end
  end

  # ── __wasi_addr_port_t read/write — the ONE place the offsets live (see moduledoc) ────────────
  defp read_addr(mem, ptr) do
    tag = load8(mem, ptr)
    port = load16(mem, ptr + 2)

    ip =
      case tag do
        2 ->
          for(i <- 0..7, do: load16(mem, ptr + 4 + i * 2)) |> List.to_tuple()

        _ ->
          # default/inet4: first 4 addr bytes.
          {load8(mem, ptr + 4), load8(mem, ptr + 5), load8(mem, ptr + 6), load8(mem, ptr + 7)}
      end

    {tag, ip, port}
  end

  defp write_addr(mem, ptr, {ip, port}) do
    case ip do
      {a, b, c, d} ->
        store8(mem, ptr, 1)
        store16(mem, ptr + 2, port)
        for {byte, i} <- Enum.with_index([a, b, c, d]), do: store8(mem, ptr + 4 + i, byte)
        # zero the remaining 12 addr bytes.
        for i <- 4..15, do: store8(mem, ptr + 4 + i, 0)

      {_, _, _, _, _, _, _, _} = v6 ->
        store8(mem, ptr, 2)
        store16(mem, ptr + 2, port)
        for {grp, i} <- Enum.with_index(Tuple.to_list(v6)), do: store16(mem, ptr + 4 + i * 2, grp)
    end

    :ok
  end

  # gen_tcp.connect wants a charlist host or an inet ip tuple; pass the tuple straight through.
  defp ip_to_connect_arg(ip) when is_tuple(ip), do: ip

  # ── thin memory helpers (delegate to washy.ex iovec/byte helpers; one home) ───────────────────
  defp gather(mem, ptr, n), do: gather_iovs(mem, ptr, n)
  defp scatter(mem, ptr, n, data), do: scatter_iovs(mem, ptr, n, data)
  defp iov_capacity(mem, ptr, n), do: Enum.reduce(0..(n - 1)//1, 0, fn i, acc -> acc + load32(mem, ptr + i * 8 + 4) end)

  # iovec gather/scatter mirror washy.ex (kept private there); same 8-byte {buf,len} layout.
  defp gather_iovs(mem, iovs, n) do
    for(i <- 0..(n - 1)//1, do: read_bytes(mem, load32(mem, iovs + i * 8), load32(mem, iovs + i * 8 + 4)))
    |> IO.iodata_to_binary()
  end

  defp scatter_iovs(mem, iovs, n, data) do
    {written, _} =
      Enum.reduce(0..(n - 1)//1, {0, data}, fn i, {w, rem} ->
        base = load32(mem, iovs + i * 8)
        len = load32(mem, iovs + i * 8 + 4)
        take = min(len, byte_size(rem))
        <<chunk::binary-size(take), rest::binary>> = rem
        write_bytes(mem, base, chunk)
        {w + take, rest}
      end)

    written
  end

  # little-endian load/store over packed :atomics memory (mirror washy.ex load/store).
  defp load8(mem, addr), do: load(mem, addr, 1)
  defp load16(mem, addr), do: load(mem, addr, 2)
  defp load32(mem, addr), do: load(mem, addr, 4)
  defp store8(mem, addr, v), do: store(mem, addr, v, 1)
  defp store16(mem, addr, v), do: store(mem, addr, v, 2)
  defp store32(mem, addr, v), do: store(mem, addr, v, 4)

  import Bitwise

  defp load(mem, addr, n) do
    Enum.reduce(0..(n - 1), 0, fn i, acc -> acc ||| (mget(mem, addr + i) <<< (i * 8)) end)
  end

  defp store(mem, addr, val, n) do
    for i <- 0..(n - 1), do: mput(mem, addr + i, (val >>> (i * 8)) &&& 0xFF)
    :ok
  end

  defp mget(mem, addr) do
    w = :atomics.get(mem, (addr >>> 3) + 1)
    (w >>> ((addr &&& 7) * 8)) &&& 0xFF
  end

  defp mput(mem, addr, byte) do
    idx = (addr >>> 3) + 1
    sh = (addr &&& 7) * 8
    w = :atomics.get(mem, idx)
    w = (w &&& bnot(0xFF <<< sh)) ||| ((byte &&& 0xFF) <<< sh)
    :atomics.put(mem, idx, w &&& 0xFFFFFFFFFFFFFFFF)
  end
end
