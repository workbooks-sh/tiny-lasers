defmodule TinyLasers.Gate.Js do
  @moduledoc """
  **F2 vertical: JS source → BEAM-native, behind the capability gate.**

  `parse` (acorn, the reused Porffor parser dep — H3) → `TinyLasers.Gate.Lower` (ESTree → Elixir quoted,
  direct-term objects — H1) → `Code.compile_quoted` → a real `.beam` module → `run/0`. Confinement (H2) is
  structural: the emitted module references only `TinyLasers.Gate.Runtime`; verify with
  `TinyLasers.Gate.dangerous_refs/1` on the returned binary.

  This is a spike frontend covering the core language (see `Lower`), not a full JS engine — enough to prove
  real parsed JS runs BEAM-native with GC where the WASM hybrid hits the memory wall.
  """

  alias TinyLasers.Gate.{Lower, Runtime}

  @parser Path.expand("../../../compilers/js/porffor/gate_parse.cjs", __DIR__)

  @doc "Parse JS source to an ESTree AST (decoded map). Raises on parse error."
  def parse(src) when is_binary(src) do
    tmp = Path.join(System.tmp_dir!(), "gate_#{System.unique_integer([:positive])}.js")
    File.write!(tmp, src)

    try do
      case System.cmd("node", [@parser, tmp], stderr_to_stdout: false) do
        {json, 0} -> TinyLasers.Wasm.Json.decode!(json)
        {_out, _} -> raise "parse failed"
      end
    after
      File.rm(tmp)
    end
  end

  @doc """
  Compile JS source to a native BEAM module and run it. Returns `%{result, binary, mod}`.
  `opts[:caps]` is a map of granted host capabilities (default: just `print`).
  """
  def run(src, opts \\ []) when is_binary(src) do
    ast = parse(src)
    body = Lower.program(ast)
    modname = Module.concat([TinyLasers.Gate.Guest, "M#{System.unique_integer([:positive])}"])

    quoted =
      quote do
        defmodule unquote(modname) do
          def run, do: unquote(body)
        end
      end

    [{mod, bin}] = Code.compile_quoted(quoted)

    caps = Keyword.get(opts, :caps, default_caps())
    ctx = %{caps: caps, tenant_root: "/tenant", fs: %{}}

    parent = self()

    pid =
      spawn(fn ->
        Runtime.__init(ctx)

        res =
          try do
            {:ok, apply(mod, :run, [])}
          catch
            :throw, {:gg_guest_error, r} -> {:guest_error, r}
            :throw, {:gg_return, v} -> {:ok, v}
            kind, e -> {:crash, kind, e}
          end

        send(parent, {:done, res, Runtime.__output()})
      end)

    _ = pid

    receive do
      {:done, res, output} ->
        %{result: res, output: output, binary: bin, mod: mod}
    after
      10_000 -> %{result: {:timeout, nil}, output: [], binary: bin, mod: mod}
    end
  end

  defp default_caps do
    %{0 => %{fun: &Runtime.cap_print/2}}
  end
end
