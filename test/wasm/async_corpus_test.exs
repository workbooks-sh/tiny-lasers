defmodule TinyLasers.JsPorfforAsyncCorpusTest do
  @moduledoc """
  G3 — async/Promise event loop, byte-identical microtask ordering to node on the Porffor→Washy ASM lane.

  `test/conformance/async_corpus.js` emits a sequence of markers; the INTERLEAVING (sync vs microtask order,
  await suspension points, combinator results) is what must match node. The golden is native node's output.

  **Currently @tag :skip** — combinators are done; async/await still has two issues:

    1a. **await ordering (REMAINING — needs true suspension).** `__Porffor_promise_await` is now a BLOCKING
        await: it drives the microtask queue until the awaited promise settles, then returns its real value
        (resolved-promise awaits and queue draining work — strictly better than the old peek hack that returned
        the pending promise object). But it does NOT yield to the caller, so cross-async microtask ORDER
        differs from node (ASM runs `after-await1|after-await2` before `sync-after-async`). Porffor generators
        are EAGER (yield just pushes to an array; the body runs to completion), so async-as-generator can't
        suspend — true await needs a regenerator-style state-machine transform OR (better, and the substrate
        already exists in Washy) a BEAM-fiber await: `await` as a suspending host import parked via
        `atomic.wait`, woken by `atomic.notify` when a host-side scheduler settles the promise. The wasm-threads
        machinery (shared :atomics memory, tid→pid registry, wait/notify ops) is already there.

    1b. **new Promise async-resolve (REMAINING — per-promise binding).** `new Promise((res,rej)=>…)` and
        `Promise.withResolvers()` bind `res`/`rej` to a module global `activePromise` (set by the constructor),
        so a `res()` called LATER (asynchronously) resolves whatever promise was constructed most recently, not
        the intended one — `await new Promise(r => setTimeoutish(() => r(42)))` yields `[object Promise]`. SYNC
        resolve works. Fix needs `res`/`rej` bound to the specific promise; builtins can't capture and can't
        hand user code a closure-convert-dispatched box, so this is an architecture item (carry the promise via
        a per-call mechanism or make res/rej host-bound).

    2. **combinator per-call state (DONE).** Promise.all/allSettled/any/race used to share module globals
       (builtins can't capture locals — closure-conversion is user-code-only), so sequential calls in one tick
       stomped each other (`all:`/`race:` vanished, `settled:` was `undefined`). Fixed by carrying per-call
       state [out, remaining, outPromise, settledFlag, kind] in a per-call array threaded to each input
       promise's reaction via a 4th reaction slot, read by a kind-based dispatcher through a module-global
       `__combineCtx` set in runJobs immediately before each (synchronous, non-reentrant) handler call — since
       a builtin handler can't capture, can't take a fn as a call arg, and can't be called with a 2nd arg.
       Now byte-identical: `all:1,2,3|race:fast|settled:fulfilled,rejected2|any:b`.

  Node golden interleaving (the target):
      sync-start|sync-mid|async-enter|sync-after-async|sync-end|p1-then|after-await1|p2-then|p-catch:e|
      p1-then2|after-await2|p-finally|all:1,2|race:fast|settled:fulfilled,rejected2

  When both pieces land, drop `@tag :skip` and this becomes a hard byte-identical gate (and a regression guard
  for Rollup's async bundle path, which G4 depends on).
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Js.Porffor

  @conf Path.join(__DIR__, "../conformance")
  @prelude Path.join(@conf, "porffor_cjs/cjs_prelude.js")

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  test "async/Promise microtask ordering is byte-identical to node on the ASM lane" do
    corpus = File.read!(Path.join(@conf, "async_corpus.js"))
    golden = File.read!(Path.join(@conf, "async_corpus.golden.txt")) |> String.trim_trailing("\n")

    src = File.read!(@prelude) <> "\n" <> corpus
    {:ok, r} = TinyLasers.Js.Debug.diagnose(src, fuel: 2_000_000_000, transpile: true)
    assert r.completed, "async corpus run did not complete: #{inspect(r.trap || r.error)}"
    assert String.trim_trailing(r.output, "\n") == golden
  end
end
