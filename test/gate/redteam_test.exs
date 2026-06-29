defmodule TinyLasers.GateRedteamTest do
  @moduledoc """
  Red-team for the BEAM capability-gate spike: a hostile guest, compiled to native
  BEAM, must not be able to reach the host. Each test is one row of the threat matrix.

  The invariant under test: guest data never crosses into the atom / MFA / raw-fun /
  raw-pid domain, so a guest can never *name* a host module — escape is unexpressible,
  not merely blocked.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate

  # ── helpers to build guest ASTs ──
  defp lit(v), do: {:lit, v}
  defp var(n), do: {:var, n}
  defp call(c, args), do: {:call, c, args}
  defp get(o, k), do: {:get, o, k}

  # ════════════════════════════════════════════════════════════════════════════
  # 1. Hello world: compiles to native BEAM and runs with correct semantics.
  # ════════════════════════════════════════════════════════════════════════════
  test "hello world runs natively and computes correctly" do
    ast =
      {:seq,
       [
         {:let, "x", {:binop, :+, lit(1), lit(2)}},
         call(var("print"), [var("x")]),
         {:let, "o", {:obj, [{lit("a"), lit(1)}]}},
         {:set, var("o"), lit("b"), lit(2)},
         {:binop, :+, get(var("o"), lit("a")), get(var("o"), lit("b"))}
       ]}

    c = Gate.compile(ast, ["print"])
    out = Gate.run(c)

    assert out.result == {:ok, 3.0}
    assert out.output == ["3"]
  end

  # ════════════════════════════════════════════════════════════════════════════
  # 2. STRUCTURAL: the emitted native bytecode references only the confined Runtime.
  #    (compile-time guarantee made visible — no escape primitive is physically present)
  # ════════════════════════════════════════════════════════════════════════════
  test "emitted bytecode references only the confined Runtime, no dangerous BIFs" do
    ast =
      {:seq,
       [
         {:let, "x", {:binop, :+, lit(40), lit(2)}},
         call(var("print"), [var("x")]),
         {:let, "f", {:fn, ["n"], {:binop, :*, var("n"), lit(2)}}},
         call(var("f"), [lit(21)])
       ]}

    c = Gate.compile(ast, ["print"])

    refs = Gate.refs(c)
    danger = Gate.dangerous_refs(c)

    # every external module call goes to exactly the one confined module
    assert Enum.all?(refs.ext, fn {m, _f, _a} -> m == TinyLasers.Gate.Runtime end),
           "unexpected external modules: #{inspect(refs.ext)}"

    # nothing dangerous at all
    assert danger == %{ext: [], bifs: []}, "escape primitives present: #{inspect(danger)}"
  end

  # ════════════════════════════════════════════════════════════════════════════
  # 3. Cannot name a host module: os.cmd("...") — `os` is undefined, not a module.
  # ════════════════════════════════════════════════════════════════════════════
  test "cannot reach :os.cmd — ungranted identifier resolves to undefined" do
    ast = call(get(var("os"), lit("cmd")), [lit("echo pwned")])

    c = Gate.compile(ast, ["print"])
    out = Gate.run(c)

    assert out.result == {:guest_error, "not a function"}
    assert out.output == []
    # and structurally: :os never appears in the bytecode
    assert Gate.dangerous_refs(c) == %{ext: [], bifs: []}
    assert Enum.all?(Gate.refs(c).ext, fn {m, _, _} -> m == TinyLasers.Gate.Runtime end)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # 4. Least privilege: granted only `print`, cannot reach `fs_write`.
  # ════════════════════════════════════════════════════════════════════════════
  test "cannot reach an ungranted capability" do
    ast = call(var("fs_write"), [lit("/work/x.txt"), lit("pwn")])

    c = Gate.compile(ast, ["print"])
    out = Gate.run(c)

    assert out.result == {:guest_error, "not a function"}
    assert out.fs_writes == []
  end

  # ════════════════════════════════════════════════════════════════════════════
  # 5. Granted fs_write is PATH-CONFINED to the tenant root.
  # ════════════════════════════════════════════════════════════════════════════
  test "granted fs_write cannot escape the tenant root" do
    ast =
      {:seq,
       [
         call(var("fs_write"), [lit("/work/ok.txt"), lit("good")]),
         call(var("fs_write"), [lit("/etc/passwd"), lit("evil")]),
         call(var("fs_write"), [lit("../../../etc/shadow"), lit("evil")])
       ]}

    c = Gate.compile(ast, ["fs_write"])
    out = Gate.run(c, tenant_root: "/work")

    assert out.fs_writes == [{"/work/ok.txt", "good"}],
           "writes escaped confinement: #{inspect(out.fs_writes)}"
  end

  # ════════════════════════════════════════════════════════════════════════════
  # 6. Granted fs_read is PATH-CONFINED — sees own tenant data, not host files.
  # ════════════════════════════════════════════════════════════════════════════
  test "granted fs_read cannot read outside the tenant root" do
    ast =
      {:seq,
       [
         call(var("print"), [call(var("fs_read"), [lit("/work/secret.txt")])]),
         call(var("print"), [call(var("fs_read"), [lit("/etc/passwd")])])
       ]}

    c = Gate.compile(ast, ["print", "fs_read"])
    out = Gate.run(c, tenant_root: "/work", fs: %{"/work/secret.txt" => "tenantdata"})

    assert out.output == ["tenantdata", "undefined"]
  end

  # ════════════════════════════════════════════════════════════════════════════
  # 7. Cannot forge a host handle — calling fabricated values is a guest error.
  # ════════════════════════════════════════════════════════════════════════════
  test "cannot fabricate a host capability handle" do
    # there is no guest opcode that produces a `{:host, _}` tag; calling a number/object fails
    for callee <- [lit(0), lit("os"), {:obj, [{lit("x"), lit(1)}]}] do
      ast = call(callee, [lit("arg")])
      c = Gate.compile(ast, ["print", "fs_write"])
      out = Gate.run(c)
      assert out.result == {:guest_error, "not a function"}
      assert out.fs_writes == []
      assert out.output == []
    end
  end

  # ════════════════════════════════════════════════════════════════════════════
  # 8. Capability is not leaked: a guest only ever holds an opaque handle.
  # ════════════════════════════════════════════════════════════════════════════
  test "guest holds an opaque handle, not a raw host function" do
    ast =
      {:seq,
       [
         {:let, "o", {:obj, [{lit("p"), var("print")}]}},
         # legit: call the granted cap through the handle stored in the object
         call(get(var("o"), lit("p")), [lit("via handle")]),
         # the guest-visible value is the handle itself, an integer-tagged tuple
         get(var("o"), lit("p"))
       ]}

    c = Gate.compile(ast, ["print"])
    out = Gate.run(c)

    assert out.output == ["via handle"]
    assert out.result == {:ok, {:host, 0}}
  end

  # ════════════════════════════════════════════════════════════════════════════
  # 9. CPU DoS: an infinite loop is contained; the caller survives.
  # ════════════════════════════════════════════════════════════════════════════
  test "infinite-loop guest is contained by the run timeout" do
    c = Gate.compile({:spin}, [])
    result = Gate.run_isolated(c, timeout: 300)

    assert result == {:timeout}
    assert Process.alive?(self())
  end

  # ════════════════════════════════════════════════════════════════════════════
  # 10. Memory DoS: unbounded allocation is killed by max_heap_size; caller survives.
  # ════════════════════════════════════════════════════════════════════════════
  test "memory-bomb guest is killed by the heap cap" do
    c = Gate.compile({:mem_bomb}, [])
    result = Gate.run_isolated(c, max_heap_size: 100_000, timeout: 3_000)

    assert match?({:killed, _}, result) or match?({:down, _}, result),
           "expected heap-kill, got: #{inspect(result)}"

    assert Process.alive?(self())
  end

  # ════════════════════════════════════════════════════════════════════════════
  # 11. Atom-table DoS is closed: running guest code creates no atoms from guest data.
  # ════════════════════════════════════════════════════════════════════════════
  test "executing a guest creates zero atoms (atom-exhaustion vector closed)" do
    # build many distinct runtime string keys via concatenation, store them on an object
    sets =
      for i <- 0..200 do
        {:set, var("o"), {:binop, :+, lit("k"), lit("#{i}")}, lit(i)}
      end

    ast = {:seq, [{:let, "o", {:obj, []}} | sets] ++ [get(var("o"), lit("k7"))]}

    # compile FIRST (compilation interns identifiers); measure only the RUN.
    c = Gate.compile(ast, [])
    before = :erlang.system_info(:atom_count)
    out = Gate.run(c)
    later = :erlang.system_info(:atom_count)

    assert out.result == {:ok, 7.0}
    assert later - before == 0, "guest run created #{later - before} atoms"
  end
end
