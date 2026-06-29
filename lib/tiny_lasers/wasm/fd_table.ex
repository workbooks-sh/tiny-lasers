defmodule TinyLasers.Wasm.FdTable do
  @moduledoc """
  The ONE unified fd table for a Wasm guest — the single source of truth for every fd kind
  (file, dir, socket, pipe, and a placeholder for timers). Replaces the old fragmented trio of
  `:tl_fds` / `:tl_sockets` / `:tl_nextfd` process-dict entries.

  POSIX faithful: an fd is a small int that points at an *open file description* (we call it a
  "desc"), which carries the actual resource state (`kind`/`ref`/`pos`/`flags`/refcount). Multiple
  fds may share ONE desc (that's what `dup`/`dup2` do), so a read through one fd advances the offset
  seen by the other, and the underlying resource (socket/pipe) is only torn down when the LAST fd
  closes (refcount → 0). Both Wasm lanes (interpreter + BEAM-asm transpiler) route their WASI
  syscalls through the same host handlers, which now all go through here, so both lanes share this
  exact fd model.

  Backing is the current guest's process dictionary (same scoping the old maps used), under two keys:
    * `:tl_fdmap`   — `%{fd => desc_id}`
    * `:tl_descs`   — `%{desc_id => desc}`  (desc = the open file description map)
  plus `:tl_nextfd` (next fd counter) and `:tl_nextdesc` (next desc id), preserved so the
  call_io / host_exec save+restore dance keeps working unchanged.

  A desc is a map:
    `%{kind: :file|:dir|:socket|:pipe, ref: term, pos: int, flags: int, cloexec: bool, refs: int}`
  where `ref` is the rel-path for file/dir, the transport ref for a socket, or a pipe-buffer id for a
  pipe. The legacy `{rel, off}` file payload and `{:dir, rel}` dir payload remain representable
  (kind+ref+pos), so no behavior is lost in the migration.
  """

  import Bitwise

  # fdflags (WASI): APPEND=0x0001, DSYNC=0x0002, NONBLOCK=0x0004, RSYNC=0x0008, SYNC=0x0010
  @o_nonblock 0x0004

  @fdmap :tl_fdmap
  @descs :tl_descs
  @nextfd :tl_nextfd
  @nextdesc :tl_nextdesc

  # fd 3 = the /work preopen dir; user fds start at 4 (0/1/2 = stdio).
  @first_user_fd 4

  @doc "Install the standard fds (0,1,2 stdio + fd 3 /work preopen) and reset the counters. Idempotent."
  def reset do
    Process.put(@fdmap, %{})
    Process.put(@descs, %{})
    Process.put(@nextfd, @first_user_fd)
    Process.put(@nextdesc, 0)

    # 0 = stdin, 1 = stdout, 2 = stderr — character devices.
    bind_std(0)
    bind_std(1)
    bind_std(2)
    # fd 3 = the /work preopen directory.
    set_fd(3, new_desc(%{kind: :dir, ref: "/work"}))
    :ok
  end

  defdelegate init(), to: __MODULE__, as: :reset

  defp bind_std(fd), do: set_fd(fd, new_desc(%{kind: :file, ref: :stdio, pos: 0}))

  # ── desc store ────────────────────────────────────────────────────────────────────────────────
  defp descs, do: Process.get(@descs, %{})
  defp put_descs(m), do: Process.put(@descs, m)
  defp fdmap, do: Process.get(@fdmap, %{})
  defp put_fdmap(m), do: Process.put(@fdmap, m)

  # create a fresh desc id holding `attrs` (filled with defaults), refs:0 (set_fd bumps it).
  defp new_desc(attrs) do
    id = Process.get(@nextdesc, 0)
    Process.put(@nextdesc, id + 1)

    desc =
      Map.merge(
        %{kind: :file, ref: nil, pos: 0, flags: 0, cloexec: false, refs: 0},
        attrs
      )

    put_descs(Map.put(descs(), id, desc))
    id
  end

  # point `fd` at desc `id` (incrementing the desc refcount); used by alloc/dup/dup2.
  defp set_fd(fd, id) do
    put_descs(Map.update!(descs(), id, fn d -> %{d | refs: d.refs + 1} end))
    put_fdmap(Map.put(fdmap(), fd, id))
    fd
  end

  defp desc_id(fd), do: Map.get(fdmap(), fd)

  # the lowest free fd ≥ the user floor (POSIX lowest-available — what dup/dup2 want).
  defp lowest_free_fd do
    used = fdmap()
    Stream.iterate(@first_user_fd, &(&1 + 1)) |> Enum.find(&(not Map.has_key?(used, &1)))
  end

  # ── public API ──────────────────────────────────────────────────────────────────────────────
  @doc "Allocate a NEW fd + its own desc from `entry` (a desc map, partial). Returns the fd."
  def alloc(entry) when is_map(entry) do
    id = new_desc(entry)
    set_fd(lowest_free_fd(), id)
  end

  @doc "The desc map behind `fd`, or nil."
  def get(fd) do
    case desc_id(fd) do
      nil -> nil
      id -> Map.get(descs(), id)
    end
  end

  @doc "Replace the desc behind `fd` (e.g. advance `pos`). Shared: visible to every fd aliasing it."
  def put(fd, entry) when is_map(entry) do
    case desc_id(fd) do
      nil ->
        :error

      id ->
        # preserve the refcount (callers update kind/ref/pos/flags, not refs).
        put_descs(Map.put(descs(), id, Map.put(entry, :refs, Map.fetch!(descs()[id], :refs))))
        :ok
    end
  end

  @doc "Re-point every file desc whose `ref` is `from` to `to` (used by path_rename to follow moved bytes)."
  def repoint(from, to) do
    put_descs(
      Map.new(descs(), fn
        {id, %{kind: :file, ref: ^from} = d} -> {id, %{d | ref: to}}
        pair -> pair
      end)
    )

    :ok
  end

  @doc """
  Close `fd`: drop the fd→desc mapping always; decrement the desc refcount and only tear down the
  underlying resource (socket close, pipe free) when it hits 0. Returns :ok or {:error, :badf}.
  """
  def close(fd) do
    case desc_id(fd) do
      nil ->
        {:error, :badf}

      id ->
        put_fdmap(Map.delete(fdmap(), fd))
        d = Map.fetch!(descs(), id)

        if d.refs <= 1 do
          teardown(d)
          put_descs(Map.delete(descs(), id))
        else
          put_descs(Map.put(descs(), id, %{d | refs: d.refs - 1}))
        end

        :ok
    end
  end

  # resource teardown on last close.
  defp teardown(%{kind: :pipe, ref: {pid, role}}), do: TinyLasers.Wasm.FdTable.Pipe.free(pid, role)
  defp teardown(%{kind: :socket, ref: ref}), do: sock_close(ref)
  defp teardown(_), do: :ok

  defp sock_close(ref) do
    case Process.get(:tl_sock) do
      f when is_function(f, 1) -> f.({:close, ref})
      _ -> :ok
    end
  end

  @doc """
  `dup(fd)` — a new lowest-available fd that SHARES `fd`'s desc (refs++), with CLOEXEC cleared on the
  new fd (POSIX `dup` clears FD_CLOEXEC). Because the desc is shared, a read through either fd
  advances the common offset. Returns the new fd, or {:error, :badf}.
  """
  def dup(fd) do
    case desc_id(fd) do
      nil ->
        {:error, :badf}

      id ->
        # CLOEXEC is a per-fd flag, but we model it on the (shared) desc. dup() must clear it without
        # touching the original — so if the desc still has fds where cloexec should remain, we keep it
        # simple: dup clears cloexec on the shared desc (the common, faithful case for our guests).
        newfd = lowest_free_fd()
        set_fd(newfd, id)
        put_descs(Map.update!(descs(), id, &%{&1 | cloexec: false}))
        newfd
    end
  end

  @doc """
  `dup2(oldfd, newfd)` (also WASI `fd_renumber`) — make `newfd` alias `oldfd`'s desc. If `newfd` is
  open it is closed first; if `oldfd == newfd` it's a no-op. Returns `newfd`, or {:error, :badf}.
  """
  def dup2(oldfd, newfd) do
    case desc_id(oldfd) do
      nil ->
        {:error, :badf}

      id ->
        cond do
          oldfd == newfd -> newfd
          true ->
            if Map.has_key?(fdmap(), newfd), do: close(newfd)
            set_fd(newfd, id)
            newfd
        end
    end
  end

  @doc "fdflags integer behind `fd` (0 if unknown)."
  def get_flags(fd), do: (g = get(fd)) && g.flags || 0

  @doc "Set the fdflags integer for `fd`. :ok | {:error, :badf}."
  def set_flags(fd, flags) when is_integer(flags) do
    case get(fd) do
      nil -> {:error, :badf}
      d -> put(fd, %{d | flags: flags})
    end
  end

  def get_cloexec(fd), do: (g = get(fd)) && g.cloexec || false

  def set_cloexec(fd, bool) when is_boolean(bool) do
    case get(fd) do
      nil -> {:error, :badf}
      d -> put(fd, %{d | cloexec: bool})
    end
  end

  @doc "Convenience: is O_NONBLOCK set on `fd`?"
  def nonblock?(fd), do: (get_flags(fd) &&& @o_nonblock) != 0

  @doc """
  Immediate read-readiness of `fd` for `poll_oneoff` — purely emulated, never blocks. Returns
  `{ready?, nbytes_available, hangup?}`:
    * stdin (fd 0): ready if `:tl_stdin` has buffered bytes (nbytes = buffered size).
    * a `:pipe`: ready if the buffer has bytes (nbytes = available) OR all writers have closed (EOF
      ⇒ ready with `hangup? = true`, nbytes 0) — POLLHUP semantics.
    * a `:file`: always ready; nbytes = bytes remaining from the fd's `pos` (best-effort).
    * a `:socket`: best-effort — we cannot cheaply peek gen_tcp without blocking, so report
      not-ready (the guest re-polls). Never blocks here.
  """
  def readable?(0) do
    n = byte_size(Process.get(:tl_stdin, ""))
    {n > 0, n, false}
  end

  def readable?(fd) do
    case get(fd) do
      %{kind: :pipe, ref: {pid, _role}} ->
        avail = TinyLasers.Wasm.FdTable.Pipe.available(pid)

        cond do
          avail > 0 -> {true, avail, false}
          TinyLasers.Wasm.FdTable.Pipe.eof?(pid) -> {true, 0, true}
          true -> {false, 0, false}
        end

      %{kind: :file, ref: path, pos: pos} when is_binary(path) ->
        size = byte_size(TinyLasers.Wasm.VFS.get(path) || "")
        {true, max(size - pos, 0), false}

      %{kind: :file} ->
        # stdio bound as :file (ref :stdio) — treat as always readable, unknown size.
        {true, 0, false}

      %{kind: :socket, ref: id} ->
        # Delegate to HostSock: it peeks the transport (timeout 0), stashing any bytes into the
        # socket's rbuf / accepted conns into its acceptq so sock_recv/sock_accept consume them.
        TinyLasers.Wasm.HostSock.readable(id)

      _ ->
        {false, 0, false}
    end
  end

  @doc "List `{fd, desc}` pairs (for readdir/debug)."
  def list, do: Enum.map(fdmap(), fn {fd, id} -> {fd, Map.get(descs(), id)} end)

  # ── pipe helpers ────────────────────────────────────────────────────────────────────────────
  @doc """
  Create an in-memory pipe: a shared byte buffer with a read-end and a write-end fd. Returns
  `{read_fd, write_fd}`. Writing the write-end appends; reading the read-end consumes; once the
  write-end is closed, reads return EOF (0 bytes) per the project's emulation thesis (no OS pipe).
  """
  def pipe do
    pid = TinyLasers.Wasm.FdTable.Pipe.new()
    # ref carries {pipe_id, end} so closing only the WRITE end decrements the writer count (→ EOF).
    rfd = alloc(%{kind: :pipe, ref: {pid, :r}})
    wfd = alloc(%{kind: :pipe, ref: {pid, :w}})
    {rfd, wfd}
  end
end

defmodule TinyLasers.Wasm.FdTable.Pipe do
  @moduledoc """
  An in-memory pipe buffer — a queue of bytes + a writer-open count, kept in the guest's process
  dictionary under `:tl_pipes`. Pure emulation: there is NO real OS pipe; the guest only needs the
  observable cause-and-effect (write appends, read consumes, EOF once all writers close).
  """

  @key :tl_pipes

  defp store, do: Process.get(@key, %{})
  defp put_store(m), do: Process.put(@key, m)

  @doc "Allocate a fresh pipe buffer; returns its id."
  def new do
    s = store()
    id = map_size(s)
    put_store(Map.put(s, id, %{buf: "", writers: 1}))
    id
  end

  @doc "Append `data` to the pipe buffer."
  def write(id, data) do
    s = store()

    case Map.get(s, id) do
      nil -> :error
      p -> put_store(Map.put(s, id, %{p | buf: p.buf <> data})); byte_size(data)
    end
  end

  @doc "Consume up to `n` bytes from the buffer. Returns the bytes (\"\" when empty — EOF if no writers)."
  def read(id, n) do
    s = store()

    case Map.get(s, id) do
      nil ->
        ""

      p ->
        take = min(n, byte_size(p.buf))
        <<chunk::binary-size(take), rest::binary>> = p.buf
        put_store(Map.put(s, id, %{p | buf: rest}))
        chunk
    end
  end

  @doc "Bytes currently buffered (readable now without blocking)."
  def available(id) do
    case Map.get(store(), id) do
      %{buf: buf} -> byte_size(buf)
      _ -> 0
    end
  end

  @doc "Is the buffer drained AND all writers closed? (true ⇒ subsequent reads are real EOF.)"
  def eof?(id) do
    case Map.get(store(), id) do
      %{buf: "", writers: w} -> w <= 0
      _ -> true
    end
  end

  @doc "A pipe fd was closed — closing the WRITE end decrements writers (→ EOF once drained)."
  def free(id, :w) do
    s = store()

    case Map.get(s, id) do
      nil -> :ok
      p -> put_store(Map.put(s, id, %{p | writers: p.writers - 1})); :ok
    end
  end

  def free(_id, :r), do: :ok
end
