defmodule TinyLasers.Js.Preflight do
  @moduledoc """
  AST preflight scanner for the Porffor lane — predicts known seams **before** compile/run.

  Shells [`preflight.cjs`](../../../compilers/js/porffor/preflight.cjs) on the host Node (build-time only).
  Warnings are **reporting** by default; `:hard_unsupported` (`eval`, `new Function`) sets `hard_block`.
  """

  defmodule Report do
    @moduledoc false
    defstruct warnings: [], hard_block: false
  end

  defmodule Warning do
    @moduledoc false
    defstruct [:code, :detail]
  end

  @node_stack "--stack-size=3000"
  @node_heap "--max-old-space-size=8192"

  defp default_root do
    Enum.find(["compilers", Path.expand("compilers", File.cwd!())], &File.dir?/1) || "compilers"
  end

  @doc "Scan JS source; returns `{:ok, %Report{}}` or `{:error, reason}`."
  def scan(source, opts \\ []) when is_binary(source) do
    root = Keyword.get(opts, :root, default_root())
    script = Path.expand(Path.join([root, "js", "porffor", "preflight.cjs"]))

    unless File.regular?(script) do
      {:error, {:preflight_missing, script}}
    else
      tmp = Path.join(System.tmp_dir!(), "tl_preflight_#{System.unique_integer([:positive])}.js")

      try do
        File.write!(tmp, source)

        case System.cmd("node", [@node_stack, @node_heap, script, tmp], stderr_to_stdout: true) do
          {out, 0} -> {:ok, parse_out(out)}
          {out, _} -> {:error, {:preflight_failed, String.slice(out, 0, 300)}}
        end
      after
        File.rm(tmp)
      end
    end
  end

  @doc "Scan a file path."
  def scan_file(path, opts \\ []) do
    with {:ok, src} <- File.read(path), do: scan(src, opts)
  end

  defp parse_out(out) do
    line = out |> String.trim() |> String.split("\n") |> List.last() || "{}"
    parse_json_line(line)
  end

  # Self-contained JSON parse for the one-line shape (no third-party deps).
  defp parse_json_line(line) do
    hard_block = line =~ ~s("hard_block":true) or line =~ ~s("hard_block": true)

    warnings =
      case Regex.scan(~r/"code"\s*:\s*"([^"]+)"\s*,\s*"detail"\s*:\s*"((?:\\.|[^"\\])*)"/, line) do
        [] -> []
        matches -> Enum.map(matches, fn [_, code, detail] -> %Warning{code: to_atom(code), detail: unescape(detail)} end)
      end

    %Report{warnings: warnings, hard_block: hard_block}
  end

  defp to_atom(s) when is_binary(s), do: String.to_atom(s)

  defp unescape(s),
    do: s |> String.replace("\\n", "\n") |> String.replace("\\\"", "\"") |> String.replace("\\\\", "\\")

  @doc "Pretty-print a report for CLI."
  def format(%Report{} = r) do
    head =
      if r.hard_block,
        do: "PREFLIGHT: HARD BLOCK (eval/new Function)\n",
        else: "PREFLIGHT: #{length(r.warnings)} warning(s)\n"

    rows =
      r.warnings
      |> Enum.map(fn w -> "  [#{w.code}] #{w.detail}" end)
      |> Enum.join("\n")

    head <> rows <> "\n"
  end
end
