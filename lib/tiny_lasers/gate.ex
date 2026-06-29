defmodule TinyLasers.Gate do
  @moduledoc """
  Capability-gate spike: compile a confined guest to **native BEAM** and run it.

  This is the security core of the "drop WASM, confine on the BEAM" architecture —
  the thing the red-team (`test/guest_gate_redteam_test.exs`) attacks. It is NOT a
  JS frontend (guest programs are hand-built ASTs) and NOT an execution-speed claim;
  it isolates the one risky assumption: *can a handle-capability gate confine native
  BEAM code so a hostile guest cannot reach the host?*

      compile/2      guest AST + granted cap names -> real BEAM module (Code.compile_quoted)
      run/2          run the module in-process, collecting output / fs effects
      run_isolated/2 run in a heap-capped, timeout-bounded, monitored process (DoS containment)
      refs/1         every external module/BIF the emitted bytecode references
      dangerous_refs/1  the subset that would constitute an escape (must be empty)
  """

  alias TinyLasers.Gate.{Codegen, Runtime}

  @cap_fns %{
    "print" => &Runtime.cap_print/2,
    "fs_read" => &Runtime.cap_fs_read/2,
    "fs_write" => &Runtime.cap_fs_write/2,
    "eval" => &Runtime.cap_eval/2
  }

  # The ONLY external module a confined guest may call.
  @allowed_modules MapSet.new([TinyLasers.Gate.Runtime])

  # BIFs that, if present in guest bytecode, would be an escape or a DoS primitive.
  @danger_bifs MapSet.new([
                 :apply,
                 :binary_to_atom,
                 :binary_to_existing_atom,
                 :list_to_atom,
                 :list_to_existing_atom,
                 :binary_to_term,
                 :spawn,
                 :spawn_link,
                 :spawn_opt,
                 :open_port,
                 :halt,
                 :processes,
                 :register,
                 :whereis,
                 :send,
                 :load_module
               ])

  @doc "Compile a guest AST, granting exactly `granted_names` (least privilege)."
  def compile(ast, granted_names) when is_list(granted_names) do
    granted = granted_names |> Enum.with_index() |> Map.new()

    caps =
      granted_names
      |> Enum.with_index()
      |> Map.new(fn {name, id} ->
        {id, %{name: name, fun: Map.fetch!(@cap_fns, name)}}
      end)

    modname = Module.concat(TinyLasers.Gate.Compiled, "G#{System.unique_integer([:positive])}")
    quoted = Codegen.module(modname, ast, granted)
    [{mod, bin}] = Code.compile_quoted(quoted)
    %{module: mod, binary: bin, granted: granted, caps: caps}
  end

  @doc "Run in-process. Returns %{result, output, fs_writes}. A guest throw is caught as a guest error."
  def run(compiled, opts \\ []) do
    ctx = %{
      caps: compiled.caps,
      granted: compiled.granted,
      tenant_root: Keyword.get(opts, :tenant_root, "/work"),
      fs: Keyword.get(opts, :fs, %{})
    }

    Runtime.__init(ctx)

    result =
      try do
        {:ok, apply(compiled.module, :run, [])}
      catch
        :throw, {:gg_guest_error, reason} -> {:guest_error, reason}
      end

    %{
      result: result,
      output: Runtime.__output(),
      fs_writes: Process.get(:gg_fs_writes, []) |> Enum.reverse()
    }
  end

  @doc """
  Run in an isolated process: `max_heap_size{kill}` + wall-clock timeout + monitor.
  A guest that loops or allocates forever is contained without harming the caller.
  Returns {:completed, %{...}} | {:timeout} | {:killed, reason} | {:down, reason}.
  """
  def run_isolated(compiled, opts \\ []) do
    parent = self()
    ref = make_ref()
    max_heap = Keyword.get(opts, :max_heap_size, 2_000_000)
    timeout = Keyword.get(opts, :timeout, 1_000)

    {pid, mon} =
      :erlang.spawn_opt(
        fn -> send(parent, {ref, run(compiled, opts)}) end,
        [:monitor, {:max_heap_size, %{size: max_heap, kill: true, error_logger: false}}]
      )

    receive do
      {^ref, out} ->
        Process.demonitor(mon, [:flush])
        {:completed, out}

      {:DOWN, ^mon, :process, ^pid, :killed} ->
        {:killed, :max_heap_size}

      {:DOWN, ^mon, :process, ^pid, reason} ->
        {:down, reason}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^mon, :process, ^pid, _} -> :ok
        after
          200 -> :ok
        end

        {:timeout}
    end
  end

  # ── structural inspector: what does the emitted NATIVE bytecode actually reference? ──

  @doc "All external {module, fun, arity} calls and BIF names in the compiled guest."
  def refs(%{binary: bin}), do: refs(bin)

  def refs(bin) when is_binary(bin) do
    {:beam_file, _mod, _exp, _attr, _ci, fns} = :beam_disasm.file(bin)

    # Scope the scan to guest-AUTHORED functions. Every Elixir module gets compiler-
    # generated reflection (`module_info/0,1`, `__info__/1`) that calls
    # `:erlang.get_module_info` — boilerplate present in all modules, not guest-emitted
    # and not guest-reachable. Excluding it keeps the structural claim about the guest's
    # own code, which is what confinement is about.
    code =
      fns
      |> Enum.reject(fn {:function, name, _a, _e, _c} -> name in [:module_info, :__info__] end)
      |> Enum.flat_map(fn {:function, _n, _a, _e, c} -> c end)

    %{ext: collect_ext(code) |> Enum.uniq(), bifs: collect_bifs(code) |> Enum.uniq()}
  end

  @doc """
  The subset of refs that would be an escape: any external module other than the
  confined Runtime, or any dangerous BIF. For a properly confined guest this is empty.
  """
  def dangerous_refs(arg) do
    %{ext: ext, bifs: bifs} = refs(arg)
    bad_ext = Enum.reject(ext, fn {m, _f, _a} -> MapSet.member?(@allowed_modules, m) end)
    bad_bifs = Enum.filter(bifs, &MapSet.member?(@danger_bifs, &1))
    %{ext: bad_ext, bifs: bad_bifs}
  end

  # deep-walk the disasm term collecting every {:extfunc, m, f, a}
  defp collect_ext(term) do
    cond do
      match?({:extfunc, _, _, _}, term) ->
        {:extfunc, m, f, a} = term
        [{m, f, a}]

      is_tuple(term) ->
        term |> Tuple.to_list() |> Enum.flat_map(&collect_ext/1)

      is_list(term) ->
        Enum.flat_map(term, &collect_ext/1)

      true ->
        []
    end
  end

  # BIFs appear as instruction tuples headed by :bif* / :gc_bif*, name in position 2
  @bif_heads MapSet.new([:bif, :bif0, :bif1, :bif2, :gc_bif, :gc_bif1, :gc_bif2, :gc_bif3])
  defp collect_bifs(code) do
    Enum.flat_map(code, fn
      instr when is_tuple(instr) and tuple_size(instr) >= 2 ->
        head = elem(instr, 0)
        if MapSet.member?(@bif_heads, head), do: [elem(instr, 1)], else: []

      _ ->
        []
    end)
  end
end
