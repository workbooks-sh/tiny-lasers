# Runs a test262 dir on the ASM lane in OS-isolated BATCHES so one pathological case (which can SIGABRT the
# whole BEAM — the no-GC cross-case memory accumulation the corpus docs warn about) cannot wipe the run.
# Each batch is a fresh `mix run` OS process; a crashed batch is reported as crashed cases, not a lost run.
#
#   BATCH=20 DIR=cases mix run scripts/test262-run-isolated.exs        # whole committed slice, batches of 20
#   DIR=cases/built-ins/RegExp mix run scripts/test262-run-isolated.exs
#
# This is the SUBPROCESS-WORKER side: given START/COUNT, it runs exactly that file window and prints tallies.
# The DRIVER side (when no START is set) enumerates files and spawns workers.

base = Path.join(["test", "conformance", "test262"])
hdir = Path.join(base, "harness")
dir = System.get_env("DIR", "cases")
absdir = if String.starts_with?(dir, "/"), do: dir, else: Path.join(base, dir)

files =
  Path.wildcard(Path.join(absdir, "**/*.js"))
  |> Enum.reject(&String.ends_with?(&1, "_FIXTURE.js"))
  |> Enum.sort()

start = System.get_env("START")
batch = String.to_integer(System.get_env("BATCH", "20"))

if start do
  # ── WORKER: run window [START, START+COUNT) ──────────────────────────────────────────────
  s = String.to_integer(start)
  count = String.to_integer(System.get_env("COUNT", "#{batch}"))
  window = Enum.slice(files, s, count)

  results =
    Enum.map(window, fn f ->
      TinyLasers.Js.Test262.run_file(f, rel: Path.relative_to(f, absdir), harness_dir: hdir, fuel: 500_000_000)
    end)

  sm = TinyLasers.Js.Test262.summarize(results)
  IO.puts("BATCH\t#{s}\t#{sm.total}\t#{sm.pass}\t#{sm.fail}\t#{sm.skip}")
  for {sig, rels} <- sm.by_signature, do: IO.puts("SIG\t#{length(rels)}\t#{sig}")
else
  # ── DRIVER: spawn one OS worker per batch, aggregate ─────────────────────────────────────
  total = length(files)
  IO.puts("# isolated run: #{total} files in #{absdir}, batch=#{batch}")

  {pass, fail, skip, crashed, sigs} =
    Enum.reduce(0..max(total - 1, 0)//batch, {0, 0, 0, 0, %{}}, fn s, {p, f, sk, cr, acc} ->
      env = [{"START", "#{s}"}, {"COUNT", "#{batch}"}, {"DIR", dir}, {"BATCH", "#{batch}"}]
      {out, code} =
        System.cmd("mix", ["run", "scripts/test262-run-isolated.exs"],
          env: env, stderr_to_stdout: true
        )

      line = out |> String.split("\n") |> Enum.find("", &String.starts_with?(&1, "BATCH\t"))

      case String.split(line, "\t") do
        ["BATCH", _s, _t, bp, bf, bsk] ->
          acc2 =
            out
            |> String.split("\n")
            |> Enum.filter(&String.starts_with?(&1, "SIG\t"))
            |> Enum.reduce(acc, fn l, a ->
              ["SIG", n, sig] = String.split(l, "\t", parts: 3)
              Map.update(a, sig, String.to_integer(n), &(&1 + String.to_integer(n)))
            end)

          {p + String.to_integer(bp), f + String.to_integer(bf), sk + String.to_integer(bsk), cr, acc2}

        _ ->
          # whole batch crashed (SIGABRT etc.) — count its window as crashed
          win = min(batch, total - s)
          IO.puts("  batch @#{s} CRASHED (exit #{code}) — #{win} cases unrun")
          {p, f, sk, cr + win, Map.update(acc, "crash:batch_sigabrt", win, &(&1 + win))}
      end
    end)

  ran = pass + fail + skip
  pct = if ran - skip > 0, do: Float.round(pass * 100 / (ran - skip), 1), else: 0.0
  IO.puts("\n=== test262 ISOLATED on ASM lane: #{dir} ===")
  IO.puts("pass #{pass}/#{ran - skip} (#{pct}%)  fail #{fail}  skip #{skip}  crashed #{crashed}  (total #{total})")
  IO.puts("--- failures grouped by signature ---")

  sigs
  |> Enum.sort_by(fn {_, n} -> -n end)
  |> Enum.each(fn {sig, n} -> IO.puts("  [#{n}] #{sig}") end)
end
