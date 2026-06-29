defmodule TinyLasers.Wasm do
  @moduledoc """
  **Wasm** — a WebAssembly interpreter in PURE ELIXIR. Untrusted wasm executes *as BEAM code*, so the
  isolation IS the BEAM's: run a module inside a process and you get its own heap (memory isolation), a
  trap = a caught exception (crash isolation), reduction-counting (preemptive fairness), and OTP
  supervision — none of it bolted on. No native runtime means no SFI-escape leakage class (a NIF fault
  crashes the whole VM; a Wasm fault kills one process). Host imports are plain Elixir function calls.

  This is the spike foundation: a decoder (magic/version/sections, LEB128) + a stack-machine interpreter.
  Milestone 1 = integer arithmetic + function calls, proving pure-BEAM wasm execution. Opcodes, linear
  memory (`:atomics`), control flow, and WASI host imports build out from here toward running the shell.

      {:ok, mod} = TinyLasers.Wasm.decode(wasm_binary)
      7 = TinyLasers.Wasm.call(mod, "add", [3, 4])
  """
  import Bitwise
  import TinyLasers.Wasm.Trap, only: [trap!: 1]

  defstruct types: [], funcs: [], exports: %{}, code: [], mem: nil, imports: [], globals: [], data: [], elements: [], table_type: nil, tags: [], id: nil, start: nil, func_names: %{}

  @typedoc "A decoded module."
  @type t :: %__MODULE__{}

  @mask32 0xFFFFFFFF
  @mask64 0xFFFFFFFFFFFFFFFF

  # ── decode ────────────────────────────────────────────────────────────────────────────────────

  @doc "Decode a `.wasm` binary into a module struct."
  def decode(<<0x00, 0x61, 0x73, 0x6D, 1, 0, 0, 0, rest::binary>>) do
    {:ok, decode_sections(rest, %__MODULE__{})}
  rescue
    e -> {:error, {:decode, Exception.message(e)}}
  end

  def decode(_), do: {:error, :not_a_wasm_module}

  @doc """
  Decode with a **content-addressed cache**: the immutable module struct is decoded ONCE per unique
  binary and stored in `:persistent_term` keyed by its SHA-256. Every cell then SHARES that one struct
  with no per-read copy (this is what `persistent_term` gives that ETS does not) — so instantiating the
  Nth cell of a program costs only its fresh mutable state (memory + counters), never re-decoding the
  9.6 MB coreutils module. Assumes a low-cardinality module set (the fleet's compilers/programs); each
  `put` does a global scan, amortized over many reads.
  """
  def decode_cached(bytes) when is_binary(bytes) do
    hash = :crypto.hash(:sha256, bytes)
    key = {:tl_mod_cache, hash}

    case :persistent_term.get(key, nil) do
      nil ->
        case decode(bytes) do
          # stamp the content hash as a stable id so tier_cached keys its build cache in O(1)
          {:ok, mod} -> mod = %{mod | id: hash}; :persistent_term.put(key, mod); {:ok, mod}
          err -> err
        end

      mod ->
        {:ok, mod}
    end
  end

  defp decode_sections(<<>>, mod), do: mod

  defp decode_sections(<<id, rest::binary>>, mod) do
    {size, rest} = uleb(rest)
    <<content::binary-size(size), rest2::binary>> = rest
    decode_sections(rest2, section(id, content, mod))
  end

  # 1 = type: vec of func types `0x60 vec(valtype) vec(valtype)`
  defp section(1, content, mod) do
    {types, _} = vec(content, &functype/1)
    %{mod | types: types}
  end

  # 3 = function: vec of type indices (one per local function)
  defp section(3, content, mod) do
    {idxs, _} = vec(content, &uleb/1)
    %{mod | funcs: idxs}
  end

  # 7 = export: vec of (name, kind, index); keep the func exports as name => func index
  defp section(7, content, mod) do
    {exports, _} = vec(content, &export/1)
    %{mod | exports: exports |> Enum.filter(&match?({_, :func, _}, &1)) |> Map.new(fn {n, :func, i} -> {n, i} end)}
  end

  # 8 = start: a single funcidx run at instantiation BEFORE any export. WASIX/LLVM emits
  # `__wasm_init_memory` here, which `memory.init`s the PASSIVE .rodata/.data/.tdata segments into
  # linear memory (threaded modules ship passive data, not active) — skip it and the rodata vtables /
  # fn-pointer relocations are never written (call_indirect reads index 0 → undefined_element).
  defp section(8, content, mod) do
    {fidx, _} = uleb(content)
    %{mod | start: fidx}
  end

  # 10 = code: vec of (size, vec(locals), body-bytes-ending-in-0x0B)
  defp section(10, content, mod) do
    # stash the parsed types so `blocktype` can resolve a multi-value typeidx blocktype to its real
    # result arity (needed by the block/loop/if exit truncation — a wrong arity drops live results).
    Process.put(:tl_parse_types, mod.types)
    {code, _} = vec(content, &code_entry/1)
    Process.delete(:tl_parse_types)
    %{mod | code: code}
  end

  # 2 = import: vec of (module, field, desc). FUNC imports occupy the LOW function indices (before local
  # funcs), so we keep them in order; non-func imports are skipped for now.
  defp section(2, content, mod) do
    {imports, _} = vec(content, &import_entry/1)
    funcs = imports |> Enum.filter(&match?({_, _, :func, _}, &1)) |> Enum.map(fn {m, n, :func, t} -> {m, n, t} end)
    # An IMPORTED memory (threaded Rust/wasix links shared memory as an import) supplies the module's
    # memory just like a defined one — the host provides it, so seed mod.mem from the import's limits.
    imported_mem = Enum.find_value(imports, fn {_m, _n, :mem, lim} -> lim; _ -> nil end)
    # An IMPORTED table (threaded Rust/wasix links its function table as an import) supplies the module's
    # table just like a defined one — seed mod.table_type from the import's limits so element segments
    # (section 9) have a table to initialize into and call_indirect resolves (no :undefined_element).
    imported_table = Enum.find_value(imports, fn {_m, _n, :table, lim} -> lim; _ -> nil end)
    %{mod | imports: funcs, mem: mod.mem || imported_mem, table_type: mod.table_type || imported_table}
  end

  # 13 = tag: vec of tags (attribute byte + typeidx) — exception tags for the EH proposal (WASIX §0).
  defp section(13, content, mod) do
    {tags, _} = vec(content, fn <<_attr, r::binary>> -> uleb(r) end)
    %{mod | tags: tags}
  end

  # 4 = table: vec of table types (reftype byte + limits). We keep the first table's {min, max} so
  # table.size/grow know the declared size (WASIX §0). One-table model, matching call_indirect.
  defp section(4, content, mod) do
    {tables, _} = vec(content, fn <<_reftype, r::binary>> -> limits(r) end)
    %{mod | table_type: List.first(tables)}
  end

  # 5 = memory: vec of limits (wasm MVP has one memory). limit = flag(0|1) then min[, max] in 64KB pages.
  defp section(5, content, mod) do
    {mems, _} = vec(content, &limits/1)
    %{mod | mem: List.first(mems)}
  end

  # 6 = global: vec of (valtype, mut, init-const-expr). Store the parsed init instrs; evaluated at start.
  defp section(6, content, mod) do
    {globals, _} = vec(content, &global_entry/1)
    %{mod | globals: globals}
  end

  # 9 = element: vec of segments that initialize the function TABLE (for call_indirect / function ptrs).
  defp section(9, content, mod) do
    {elements, _} = vec(content, &element_entry/1)
    %{mod | elements: elements}
  end

  # 11 = data: vec of segments that initialize memory with constant bytes (string literals etc.).
  defp section(11, content, mod) do
    {data, _} = vec(content, &data_entry/1)
    %{mod | data: data}
  end

  # element flag 0 = active table 0: (offset-const-expr, vec funcidx). (Other flag variants: minimal handling.)
  defp element_entry(<<0, rest::binary>>) do
    {offset, :end, rest} = parse_instrs(rest)
    {funcs, rest} = vec(rest, &uleb/1)
    {{offset, funcs}, rest}
  end

  # 0 = custom section. The "name" custom section (emitted by Porffor with `-d`) carries the function-name
  # subsection (subid 1) — a vec of {funcidx, name}. Decoding it gives every wasm function a readable name,
  # so the interpreter/profiler can report `__Porffor_malloc` instead of an opaque index. Other custom
  # sections (and other name subsections) are skipped. Indices are GLOBAL (imports included).
  defp section(0, content, mod) do
    {name, rest} = name_str(content)

    if name == "name" do
      %{mod | func_names: parse_name_subsections(rest, mod.func_names)}
    else
      mod
    end
  rescue
    _ -> mod
  end

  # A name-section string is `uleb length` + that many UTF-8 bytes.
  defp name_str(bin) do
    {len, rest} = uleb(bin)
    <<s::binary-size(len), rest2::binary>> = rest
    {s, rest2}
  end

  defp parse_name_subsections(<<>>, acc), do: acc

  defp parse_name_subsections(<<subid, rest::binary>>, acc) do
    {size, rest} = uleb(rest)
    <<payload::binary-size(size), rest2::binary>> = rest
    acc = if subid == 1, do: parse_func_names(payload, acc), else: acc
    parse_name_subsections(rest2, acc)
  end

  defp parse_func_names(payload, acc) do
    {count, rest} = uleb(payload)

    Enum.reduce(1..count//1, {acc, rest}, fn _, {a, r} ->
      {idx, r} = uleb(r)
      {nm, r} = name_str(r)
      {Map.put(a, idx, nm), r}
    end)
    |> elem(0)
  end

  # sections we don't need yet (table/element/…) are skipped
  defp section(_id, _content, mod), do: mod

  defp data_entry(<<0, rest::binary>>) do
    {offset, :end, rest} = parse_instrs(rest)
    {n, rest} = uleb(rest)
    <<bytes::binary-size(n), rest::binary>> = rest
    {{:active, offset, bytes}, rest}
  end

  defp data_entry(<<1, rest::binary>>) do
    {n, rest} = uleb(rest)
    <<bytes::binary-size(n), rest::binary>> = rest
    {{:passive, bytes}, rest}
  end

  defp data_entry(<<2, rest::binary>>) do
    {_memidx, rest} = uleb(rest)
    {offset, :end, rest} = parse_instrs(rest)
    {n, rest} = uleb(rest)
    <<bytes::binary-size(n), rest::binary>> = rest
    {{:active, offset, bytes}, rest}
  end

  defp global_entry(<<valtype, _mut, rest::binary>>) do
    {init, :end, rest} = parse_instrs(rest)
    {{valtype, init}, rest}
  end

  defp import_entry(content) do
    {mod_name, rest} = name(content)
    {field, rest} = name(rest)
    <<kind, rest::binary>> = rest
    case kind do
      0 -> {tidx, rest} = uleb(rest); {{mod_name, field, :func, tidx}, rest}
      2 -> {lim, rest} = limits(rest); {{mod_name, field, :mem, lim}, rest}
      3 -> <<_vt, _mut, rest::binary>> = rest; {{mod_name, field, :global, nil}, rest}
      1 -> <<_rt, rest::binary>> = rest; {lim, rest} = limits(rest); {{mod_name, field, :table, lim}, rest}
    end
  end

  defp limits(<<0, rest::binary>>), do: ({min, rest} = uleb(rest)) && {{min, nil}, rest}
  defp limits(<<1, rest::binary>>) do
    {min, rest} = uleb(rest)
    {max, rest} = uleb(rest)
    {{min, max}, rest}
  end

  # SHARED-memory limits (WASM threads / WASIX §2): flag 2 = shared, min only; flag 3 = shared, min+max.
  # A shared memory carries `:shared` as a third tuple element so `new_mem` can PRE-ALLOCATE at the max
  # up front — keeping the `:atomics` backing stable (no grow-realloc) so spawned threads share ONE ref.
  defp limits(<<2, rest::binary>>), do: ({min, rest} = uleb(rest)) && {{min, nil, :shared}, rest}
  defp limits(<<3, rest::binary>>) do
    {min, rest} = uleb(rest)
    {max, rest} = uleb(rest)
    {{min, max, :shared}, rest}
  end

  defp functype(<<0x60, rest::binary>>) do
    {params, rest} = vec(rest, &valtype/1)
    {results, rest} = vec(rest, &valtype/1)
    {{params, results}, rest}
  end

  defp valtype(<<t, rest::binary>>), do: {t, rest}

  defp export(content) do
    {name, rest} = name(content)
    <<kind, rest::binary>> = rest
    {idx, rest} = uleb(rest)
    kind = %{0 => :func, 1 => :table, 2 => :mem, 3 => :global}[kind] || kind
    {{name, kind, idx}, rest}
  end

  defp code_entry(content) do
    {size, rest} = uleb(content)
    <<body::binary-size(size), rest2::binary>> = rest
    {locals, code} = vec(body, fn b -> {n, b} = uleb(b); {t, b} = valtype(b); {{n, t}, b} end)
    nlocals = Enum.reduce(locals, 0, fn {n, _}, acc -> acc + n end)
    {instrs, :end, _} = parse_instrs(code)
    {{nlocals, instrs}, rest2}
  end

  # ── parse a function body's bytes into a STRUCTURED instruction list ─────────────────────────────
  # Reads until the matching `end` (0x0B) / `else` (0x05); block/loop/if recurse so each carries its own
  # inner instruction list. This is what makes structured control flow (br targets) tractable.
  defp parse_instrs(bin, acc \\ [])
  defp parse_instrs(<<0x0B, rest::binary>>, acc), do: {Enum.reverse(acc), :end, rest}
  defp parse_instrs(<<0x05, rest::binary>>, acc), do: {Enum.reverse(acc), :else, rest}
  # legacy exception-handling section delimiters (Porffor emits these): catch <tag> / catch_all / delegate
  # <label> terminate the current `try`/catch section, like `else` does for `if` (see parse_op(0x06)).
  defp parse_instrs(<<0x07, rest::binary>>, acc), do: ({t, r} = uleb(rest); {Enum.reverse(acc), {:catch, t}, r})
  defp parse_instrs(<<0x19, rest::binary>>, acc), do: {Enum.reverse(acc), :catch_all, rest}
  defp parse_instrs(<<0x18, rest::binary>>, acc), do: ({lbl, r} = uleb(rest); {Enum.reverse(acc), {:delegate, lbl}, r})

  defp parse_instrs(<<op, rest::binary>>, acc) do
    {instr, rest} = parse_op(op, rest)
    parse_instrs(rest, [instr | acc])
  end

  defp parse_op(0x02, rest), do: ({n, r} = blocktype(rest); {body, :end, r} = parse_instrs(r); {{:block, n, body}, r})
  defp parse_op(0x03, rest), do: ({n, r} = blocktype(rest); {body, :end, r} = parse_instrs(r); {{:loop, n, body}, r})

  defp parse_op(0x04, rest) do
    {n, r} = blocktype(rest)
    {then_b, term, r} = parse_instrs(r)
    {else_b, r} = if term == :else, do: (fn -> {e, :end, r2} = parse_instrs(r); {e, r2} end).(), else: {[], r}
    {{:if, n, then_b, else_b}, r}
  end

  # legacy exception handling (the OLD proposal Porffor emits): `try bt <body> (catch tag <c>)*
  # (catch_all <c>)? end` OR `try bt <body> delegate <label>`. Lowered to `{:try_legacy, nres, body,
  # clauses, delegate}` and run via the SAME {:wasm_exc,…} machinery as the newer try_table.
  defp parse_op(0x06, rest) do
    {nres, r} = blocktype(rest)
    {body, term, r} = parse_instrs(r)
    parse_try_clauses(nres, body, term, r, [])
  end

  # rethrow <label>: re-raise the exception caught by the Nth enclosing try's catch (see step/4).
  defp parse_op(0x09, rest), do: ({lbl, r} = uleb(rest); {{:rethrow, lbl}, r})

  defp parse_try_clauses(nres, body, {:catch, tag}, r, acc) do
    {c, term, r} = parse_instrs(r)
    parse_try_clauses(nres, body, term, r, [{:catch, tag, c} | acc])
  end

  defp parse_try_clauses(nres, body, :catch_all, r, acc) do
    {c, term, r} = parse_instrs(r)
    parse_try_clauses(nres, body, term, r, [{:catch_all, c} | acc])
  end

  defp parse_try_clauses(nres, body, :end, r, acc),
    do: {{:try_legacy, nres, body, Enum.reverse(acc), nil}, r}

  defp parse_try_clauses(nres, body, {:delegate, lbl}, r, acc),
    do: {{:try_legacy, nres, body, Enum.reverse(acc), lbl}, r}

  # Exception handling (exnref proposal, WASIX §0): try_table is a block carrying catch clauses;
  # throw raises a tag's exception; throw_ref re-raises a caught exnref.
  defp parse_op(0x1F, rest) do
    {_bt, r} = blocktype(rest)
    {catches, r} = vec(r, &catch_clause/1)
    {body, :end, r} = parse_instrs(r)
    {{:try_table, catches, body}, r}
  end

  defp parse_op(0x08, rest), do: ({t, r} = uleb(rest); {{:throw, t}, r})
  defp parse_op(0x0A, rest), do: {{:throw_ref}, rest}

  defp parse_op(0x23, rest), do: ({i, r} = uleb(rest); {{:global_get, i}, r})
  defp parse_op(0x24, rest), do: ({i, r} = uleb(rest); {{:global_set, i}, r})
  defp parse_op(0x41, rest), do: ({v, r} = sleb(rest); {{:i32_const, v}, r})
  defp parse_op(0x42, rest), do: ({v, r} = sleb(rest); {{:i64_const, v &&& @mask64}, r})
  # i64 loads/stores (the load width + sign is encoded in the op; value masked to 64 bits)
  defp parse_op(0x29, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 8, false}, r})
  defp parse_op(0x30, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 1, true}, r})
  defp parse_op(0x31, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 1, false}, r})
  defp parse_op(0x32, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 2, true}, r})
  defp parse_op(0x33, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 2, false}, r})
  defp parse_op(0x34, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 4, true}, r})
  defp parse_op(0x35, rest), do: ({o, r} = memarg(rest); {{:i64_load, o, 4, false}, r})
  defp parse_op(0x37, rest), do: ({o, r} = memarg(rest); {{:i64_store, o, 8}, r})
  defp parse_op(0x3C, rest), do: ({o, r} = memarg(rest); {{:i64_store, o, 1}, r})
  defp parse_op(0x3D, rest), do: ({o, r} = memarg(rest); {{:i64_store, o, 2}, r})
  defp parse_op(0x3E, rest), do: ({o, r} = memarg(rest); {{:i64_store, o, 4}, r})
  defp parse_op(0x20, rest), do: ({i, r} = uleb(rest); {{:local_get, i}, r})
  defp parse_op(0x21, rest), do: ({i, r} = uleb(rest); {{:local_set, i}, r})
  defp parse_op(0x22, rest), do: ({i, r} = uleb(rest); {{:local_tee, i}, r})
  defp parse_op(0x10, rest), do: ({f, r} = uleb(rest); {{:call, f}, r})
  defp parse_op(0x11, rest), do: ({tidx, r} = uleb(rest); {_tbl, r} = uleb(r); {{:call_indirect, tidx}, r})
  defp parse_op(0x0C, rest), do: ({n, r} = uleb(rest); {{:br, n}, r})
  defp parse_op(0x0D, rest), do: ({n, r} = uleb(rest); {{:br_if, n}, r})
  defp parse_op(0x0E, rest), do: ({labels, r} = vec(rest, &uleb/1); {default, r} = uleb(r); {{:br_table, labels, default}, r})
  defp parse_op(0x0F, rest), do: {{:return}, rest}
  defp parse_op(0x1A, rest), do: {{:drop}, rest}
  defp parse_op(0x00, rest), do: {{:unreachable}, rest}
  defp parse_op(0x01, rest), do: {{:nop}, rest}
  defp parse_op(0x28, rest), do: ({o, r} = memarg(rest); {{:i32_load, o}, r})
  defp parse_op(0x2C, rest), do: ({o, r} = memarg(rest); {{:i32_load8s, o}, r})
  defp parse_op(0x2D, rest), do: ({o, r} = memarg(rest); {{:i32_load8u, o}, r})
  defp parse_op(0x2E, rest), do: ({o, r} = memarg(rest); {{:i32_load16s, o}, r})
  defp parse_op(0x2F, rest), do: ({o, r} = memarg(rest); {{:i32_load16u, o}, r})
  defp parse_op(0x36, rest), do: ({o, r} = memarg(rest); {{:i32_store, o}, r})
  defp parse_op(0x3A, rest), do: ({o, r} = memarg(rest); {{:i32_store8, o}, r})
  defp parse_op(0x3B, rest), do: ({o, r} = memarg(rest); {{:i32_store16, o}, r})
  defp parse_op(0x3F, <<_, rest::binary>>), do: {{:memory_size}, rest}
  defp parse_op(0x40, <<_, rest::binary>>), do: {{:memory_grow}, rest}
  # floats: const literals — read RAW bits (NaN/Inf can't be pattern-matched as an Erlang float), decode to
  # a float only when finite; a non-finite const becomes a placeholder (raises only if actually used).
  defp parse_op(0x43, <<bits::32-little, rest::binary>>), do: {{:fconst, decode_f(bits, 32)}, rest}
  defp parse_op(0x44, <<bits::64-little, rest::binary>>), do: {{:fconst, decode_f(bits, 64)}, rest}
  defp parse_op(0x2A, rest), do: ({o, r} = memarg(rest); {{:f32_load, o}, r})
  defp parse_op(0x2B, rest), do: ({o, r} = memarg(rest); {{:f64_load, o}, r})
  defp parse_op(0x38, rest), do: ({o, r} = memarg(rest); {{:f32_store, o}, r})
  defp parse_op(0x39, rest), do: ({o, r} = memarg(rest); {{:f64_store, o}, r})
  # 0xFC = the "misc" prefix (bulk memory + saturating truncations). Sub-opcode is a uleb.
  defp parse_op(0xFC, rest) do
    {sub, rest} = uleb(rest)

    case sub do
      8 -> {data, r} = uleb(rest); <<_mem, r::binary>> = r; {{:memory_init, data}, r}
      9 -> {_data, r} = uleb(rest); {{:data_drop}, r}
      10 -> <<_dst, _src, r::binary>> = rest; {{:memory_copy}, r}
      11 -> <<_mem, r::binary>> = rest; {{:memory_fill}, r}
      n when n in 0..7 -> {{:trunc_sat, n}, rest}
      # table ops (reference-types proposal): init/elem.drop/copy carry table/elem indices; grow/size/fill a tableidx.
      12 -> {_elem, r} = uleb(rest); {_tbl, r} = uleb(r); {{:table_init}, r}
      13 -> {_elem, r} = uleb(rest); {{:elem_drop}, r}
      14 -> {_dt, r} = uleb(rest); {_st, r} = uleb(r); {{:table_copy}, r}
      15 -> {_t, r} = uleb(rest); {{:table_grow}, r}
      16 -> {_t, r} = uleb(rest); {{:table_size}, r}
      17 -> {_t, r} = uleb(rest); {{:table_fill}, r}
      _ -> raise("tinylasers: unimplemented 0xFC sub-op #{sub}")
    end
  end

  # 0xFD = SIMD (v128) prefix. We parse PAST it (correct immediate per sub-op) so SIMD-using modules
  # decode; execution of a v128 op raises (unimplemented) — fine if the run never hits one.
  defp parse_op(0xFD, rest) do
    {sub, rest} = uleb(rest)

    {imm, rest} =
      cond do
        sub in 0..11 or sub in [92, 93] -> memarg(rest)
        sub in [12, 13] -> (<<c::binary-size(16), r::binary>> = rest; {c, r})
        sub in 21..34 -> (<<lane, r::binary>> = rest; {lane, r})
        sub in 84..91 -> ({o, r} = memarg(rest); <<lane, r2::binary>> = r; {{o, lane}, r2})
        true -> {nil, rest}
      end

    {{:simd, sub, imm}, rest}
  end

  # 0xFE = the ATOMICS / threads prefix (WASIX §0). Sub-opcode is a uleb; loads/stores/rmw/wait/notify
  # carry a memarg, atomic.fence carries a single (reserved) byte. We parse into typed tuples the
  # interpreter executes — atomicity-under-contention lands with threads (§2); single-thread semantics here.
  defp parse_op(0xFE, rest) do
    {sub, rest} = uleb(rest)

    cond do
      sub == 0x03 -> (<<_reserved, r::binary>> = rest; {{:atomic_fence}, r})
      sub == 0x00 -> ({o, r} = memarg(rest); {{:atomic_notify, o}, r})
      sub == 0x01 -> ({o, r} = memarg(rest); {{:atomic_wait, 4, o}, r})
      sub == 0x02 -> ({o, r} = memarg(rest); {{:atomic_wait, 8, o}, r})
      sub in 0x10..0x16 -> ({o, r} = memarg(rest); {{:atomic_load, o, atomic_load_width(sub)}, r})
      sub in 0x17..0x1D -> ({o, r} = memarg(rest); {{:atomic_store, o, atomic_store_width(sub)}, r})
      sub in 0x1E..0x4E -> ({o, r} = memarg(rest); {opname, n} = atomic_rmw_shape(sub); {{:atomic_rmw, opname, o, n}, r})
      true -> raise("tinylasers: unimplemented 0xFE sub-op #{sub}")
    end
  end

  # Access widths (bytes) for the atomic load (0x10..0x16) and store (0x17..0x1D) sub-opcodes.
  defp atomic_load_width(s), do: elem({4, 8, 1, 2, 1, 2, 4}, s - 0x10)
  defp atomic_store_width(s), do: elem({4, 8, 1, 2, 1, 2, 4}, s - 0x17)

  # The 49 rmw sub-opcodes (0x1E..0x4E) = 7 ops × 7 widths. op = base/7, width = base rem 7.
  defp atomic_rmw_shape(sub) do
    base = sub - 0x1E
    op = elem({:add, :sub, :and, :or, :xor, :xchg, :cmpxchg}, div(base, 7))
    n = elem({4, 8, 1, 2, 1, 2, 4}, rem(base, 7))
    {op, n}
  end

  # The n-byte unsigned mask, and the rmw operation applied to (old, operand), wrapped to the width.
  defp mask_n(n), do: (1 <<< (n * 8)) - 1
  # Reference types (WASIX §0): a funcref is the function index (an integer); a null ref is `:null`.
  # ref.null carries a heaptype byte; ref.func a funcidx; table.get/set a tableidx (single-table model).
  defp parse_op(0xD0, <<_heaptype, rest::binary>>), do: {{:ref_null}, rest}
  defp parse_op(0xD1, rest), do: {{:ref_is_null}, rest}
  defp parse_op(0xD2, rest), do: ({i, r} = uleb(rest); {{:ref_func, i}, r})
  defp parse_op(0x25, rest), do: ({_t, r} = uleb(rest); {{:table_get}, r})
  defp parse_op(0x26, rest), do: ({_t, r} = uleb(rest); {{:table_set}, r})

  # the pure numeric/compare/convert ops (no immediate) — a contiguous range; dispatch by opcode
  defp parse_op(op, rest) when op == 0x1B or (op >= 0x45 and op <= 0xC4), do: {{:op, op}, rest}
  # anything else carries an immediate we haven't taught the parser — fail LOUDLY with the exact opcode
  defp parse_op(op, _rest), do: raise("tinylasers parser: unhandled opcode 0x#{Integer.to_string(op, 16)} (needs an immediate-aware clause)")

  # blocktype → the block's RESULT ARITY (how many values it leaves on the stack). 0x40 = empty (0
  # results); a single valtype byte = 1 result; otherwise a signed-LEB type index (multi-value blocks —
  # rare; we consume the full LEB so the instruction stream stays aligned, and treat it as 1 result,
  # which is correct for every non-multivalue module). The arity is REQUIRED so block/loop/if exit can
  # discard stack values left above [entry ++ results] — a `br` may legally carry extra operands, which
  # the spec drops (the wb-h9ad memcmp bug: a `br` to a void block leaked the comparison result).
  defp blocktype(<<0x40, rest::binary>>), do: {0, rest}

  defp blocktype(<<b, rest::binary>>) when b in [0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x70, 0x6F],
    do: {1, rest}

  # a non-negative signed-LEB s33 = a type index → the block's results are that type's results (multi-
  # value blocks, used by real Rust/wasix output). Resolve the arity from the stashed types.
  defp blocktype(bin) do
    {idx, r} = sleb(bin)
    {_params, results} = Enum.at(Process.get(:tl_parse_types, []), idx, {[], [0]})
    {length(results), r}
  end

  # A try_table catch clause: catch (tag→label), catch_ref (tag→label, +exnref), catch_all (→label),
  # catch_all_ref (→label, +exnref). The label is a br target relative to the try_table frame.
  defp catch_clause(<<0x00, rest::binary>>), do: ({t, r} = uleb(rest); {l, r} = uleb(r); {{:catch, t, l}, r})
  defp catch_clause(<<0x01, rest::binary>>), do: ({t, r} = uleb(rest); {l, r} = uleb(r); {{:catch_ref, t, l}, r})
  defp catch_clause(<<0x02, rest::binary>>), do: ({l, r} = uleb(rest); {{:catch_all, l}, r})
  defp catch_clause(<<0x03, rest::binary>>), do: ({l, r} = uleb(rest); {{:catch_all_ref, l}, r})

  defp name(content) do
    {len, rest} = uleb(content)
    <<s::binary-size(len), rest2::binary>> = rest
    {s, rest2}
  end

  # vec = uleb count, then `count` items parsed by `f`
  defp vec(bin, f) do
    {count, rest} = uleb(bin)
    Enum.reduce(1..count//1, {[], rest}, fn _, {acc, b} -> {x, b} = f.(b); {[x | acc], b} end)
    |> then(fn {acc, b} -> {Enum.reverse(acc), b} end)
  end

  # LEB128 unsigned + signed
  defp uleb(bin), do: uleb(bin, 0, 0)
  defp uleb(<<byte, rest::binary>>, shift, acc) do
    acc = acc ||| ((byte &&& 0x7F) <<< shift)
    if (byte &&& 0x80) != 0, do: uleb(rest, shift + 7, acc), else: {acc, rest}
  end

  defp sleb(bin), do: sleb(bin, 0, 0)
  defp sleb(<<byte, rest::binary>>, shift, acc) do
    acc = acc ||| ((byte &&& 0x7F) <<< shift)
    shift2 = shift + 7
    if (byte &&& 0x80) != 0 do
      sleb(rest, shift2, acc)
    else
      acc = if (byte &&& 0x40) != 0 and shift2 < 64, do: acc ||| (-1 <<< shift2), else: acc
      {acc, rest}
    end
  end

  # ── run ───────────────────────────────────────────────────────────────────────────────────────

  @doc """
  Call an exported function by name with integer args. Returns the top-of-stack result (or nil). Builds a
  fresh runtime: a per-call **linear memory** as an `:atomics` array (mutable, NIF-free, BEAM-native — the
  primitive that lets wasm's mutable byte memory live inside an isolated BEAM process).
  """
  # Default instruction FUEL: a generous-but-FINITE work budget so a runaway guest traps
  # (`:out_of_fuel`) instead of spinning forever. Wall-clock is bounded separately by
  # `TinyLasers.Wasm.Sandbox`. Override per run with `call(mod, name, args, fuel: N)`.
  @default_fuel 2_000_000_000
  # Max wasm CALL depth (recursive calls grow the BEAM process stack). Bounds it to a clean
  # `:stack_exhausted` trap instead of an opaque process crash. Block/loop nesting is statically
  # finite and not counted here.
  @default_max_depth 10_000
  # Hard ceiling on memory growth (pages) — replaces the old implicit 64-page cap. A guest cannot
  # grow past this, so `memory.grow` can never OOM the host. 4096 pages = 256 MB. Override per run.
  @default_max_pages 4096

  def call(%__MODULE__{} = mod, name, args, opts \\ []) when is_list(args) do
    {result, _io} = call_io(mod, name, args, opts)
    result
  end

  @doc """
  Like `call/4`, but also returns captured stdout (what the guest wrote via WASI `fd_write`).
  Opts: `:fuel` (instruction budget, default #{@default_fuel}).
  """
  def call_io(%__MODULE__{} = mod, name, args, opts \\ []) when is_list(args) do
    # Snapshot ALL per-run process-dict context so a NESTED call_io (host_exec's fork/exec emulation)
    # restores the outer run's context on return. The interpreter threads `rt` and is immune, but
    # TRANSPILED code reads these from the dict — without restore, an outer transpiled function running
    # after a host_exec would see the INNER program's globals/table/mem_pages/fuel (the wb-6c2y bug:
    # shell strspn read coreutils' stack pointer against the shell's smaller memory → OOB trap).
    prev = Process.get(:tl_out)
    prev_mem = Process.get(:tl_mem)
    prev_globals = Process.get(:tl_globals)
    prev_table = Process.get(:tl_table)
    prev_mem_pages = Process.get(:tl_mem_pages)
    prev_max_pages = Process.get(:tl_max_pages)
    prev_fuel = Process.get(:tl_last_fuel)
    Process.put(:tl_out, [])
    globals = new_globals(mod.globals)
    mem_pages = new_mem(mod.mem)
    init_data(globals, mod.data)
    fuel = :atomics.new(1, signed: true)
    budget = Keyword.get(opts, :fuel, @default_fuel)
    :atomics.put(fuel, 1, budget)
    # expose the fuel counter so the caller can compute consumed = budget - remaining (metrics)
    Process.put(:tl_last_fuel, {budget, fuel})
    depth = :atomics.new(1, signed: true)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_pages = Keyword.get(opts, :max_pages, @default_max_pages)
    table = new_table(mod.elements, globals)
    # Expose the runtime context via the process dict (alongside :tl_mem) so TRANSPILED standalone
    # BEAM code can reach the same globals/table/mem_pages/fuel the interpreter holds in `rt` — what the
    # transpiler needs for global.get/set, call_indirect, memory.grow/bounds, and fuel-charging.
    Process.put(:tl_globals, globals)
    Process.put(:tl_table, table)
    Process.delete(:tl_table_size)
    Process.put(:tl_mem_pages, mem_pages)
    Process.put(:tl_max_pages, max_pages)
    # TIERED lane (opt-in), LAZY hot-path model: start fully interpreted (zero upfront cost), count
    # calls, and compile ONLY functions that get hot (threshold crossings) — so even a 5000-function
    # module pays nothing at startup and compiles just its working set. The growing native registry lives
    # in the mutable `:tl_jit` dict; call counts in a per-run `:counters`.
    prev_jit = Process.get(:tl_jit)

    lazy =
      if Keyword.get(opts, :transpile, false) do
        Process.put(:tl_jit, %{})
        counts = :counters.new(max(1, length(mod.code)), [:write_concurrency])
        # :async (default) compiles hot functions in the BACKGROUND so a run never stalls on a compile
        # storm; :sync compiles inline (deterministic — tests, and where blocking is acceptable).
        {counts, Keyword.get(opts, :tier_threshold, 20), Keyword.get(opts, :tier_async, true)}
      else
        nil
      end

    # A module that imports proc_fork MUST run on the reified-stack lane (the only one that can capture
    # the fork continuation) and MUST NOT JIT (native frames are uncapturable). Auto-select it so real
    # fork programs "just work" without the caller knowing — explicit `cps:`/`transpile:` opts still win.
    imports_fork? = Enum.any?(mod.imports, fn {_m, n, _t} -> n == "proc_fork" end)
    cps = Keyword.get(opts, :cps, imports_fork?)
    lazy = if cps and not Keyword.has_key?(opts, :transpile), do: nil, else: lazy

    rt = %{mod: mod, mem_pages: mem_pages, globals: globals, table: table, fuel: fuel, depth: depth, max_depth: max_depth, max_pages: max_pages, lazy: lazy, ni: length(mod.imports), cps: cps, gtypes: global_types(mod)}
    # stash rt so a transpiled function can trampoline back into the interpreter (`call_local`)
    prev_rt = Process.get(:tl_rt)
    Process.put(:tl_rt, rt)
    # Install a FRESH unified fd table for this instance (stdio 0/1/2 + the /work preopen at fd 3,
    # next-fd 4) — the ONE source of truth for every fd kind. Only at the OUTERMOST call_io: a nested
    # host_exec run snapshots+restores the table itself (so it gets its own fresh table mid-flight),
    # and re-installing here would clobber the parent's table on return-from-nest.
    if prev_rt == nil, do: TinyLasers.Wasm.FdTable.reset()

    # Run the module's START function (section 8) once, at the OUTERMOST instantiation, before the export.
    # For WASIX/LLVM this is `__wasm_init_memory`, which copies passive data segments into memory — without
    # it rodata/vtables stay zero. A nested host_exec run keeps its own start semantics via its own call_io.
    if prev_rt == nil && mod.start != nil, do: call_fn(rt, mod.start, [])

    try do
      result = call_fn(rt, Map.fetch!(mod.exports, name), args)
      out = Process.get(:tl_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
      # :tl_out/:tl_mem are restored only on the NORMAL return: when the guest throws (proc_exit /
      # trap) the immediate caller (host_exec) still reads the partial output + the guest's memory before
      # IT restores them, so we must leave those in place on the throw path.
      restore(:tl_out, prev)
      restore(:tl_mem, prev_mem)
      {result, out}
    after
      # The EXECUTION CONTEXT (globals/table/mem_pages/fuel/rt) must be restored on EVERY exit — normal OR
      # throw — or an outer TRANSPILED function resuming after a host_exec would read the inner program's
      # context from the dict (the wb-6c2y OOB: shell read coreutils' SP/page-count). No caller reads
      # these post-throw, so restoring them in `after` is safe.
      restore(:tl_globals, prev_globals)
      restore(:tl_table, prev_table)
      restore(:tl_mem_pages, prev_mem_pages)
      restore(:tl_max_pages, prev_max_pages)
      restore(:tl_last_fuel, prev_fuel)
      restore(:tl_rt, prev_rt)
      restore(:tl_jit, prev_jit)
      # When the OUTERMOST run ends, tear down any worker threads it spawned — a guest's main exiting
      # must kill its threads (POSIX), not leave them parked in futex_wait for the 60s cap (rayon leaves
      # idle pool workers blocked on a futex after the parallel region).
      if prev_rt == nil, do: kill_run_threads()
    end
  end

  # Kill every worker thread spawned during this run + clear the tid→pid registry. Bounded, idempotent.
  defp kill_run_threads do
    for pid <- Process.get(:tl_thread_pids, []), is_pid(pid), do: Process.exit(pid, :kill)
    Process.delete(:tl_thread_pids)
    try do
      :ets.delete_all_objects(threads_table())
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  # ── PERSISTENT INSTANCES (wb: JS guest-actor state across messages) ─────────────────────────────
  #
  # `call_io` is one-shot: set up the process-dict run context (`:tl_mem`/globals/table/fuel/`:tl_rt`),
  # invoke ONE function, restore on exit. A persistent guest needs the OPPOSITE of the restore: instantiate
  # + run a setup function (`_start`) but KEEP the linear memory + runtime state, then re-enter a named
  # export per message with that SAME memory/globals alive — so QuickJS's heap (its `let count=0`, closures)
  # survives between deliveries instead of resetting on every script re-run.
  #
  # OWNERSHIP MODEL — single-process, no shared mutable memory. An `Instance` is OWNED by exactly one BEAM
  # process (the actor GenServer). The struct is the *canonical, immutable snapshot* of the guest's run
  # context (the `:atomics` refs for memory/globals/table/fuel, the page-count atomics, the decoded module,
  # the import count). `:atomics` refs are shared handles to off-heap mutable cells, but only the owning
  # process ever installs them into ITS process dict and invokes the export — there is no cross-process
  # access, so there is no shared-mutable hazard. `instance_invoke` runs the export IN THE CALLING
  # (owner) process directly (NOT in a `Sandbox` Task): re-spawning a Task per message would lose the
  # process-dict run context (the Task gets a fresh dict), and copying every atomics ref + re-pinning it
  # each call buys nothing — the owner process already provides BEAM isolation (one actor = one process =
  # its own heap; a trap is a caught exception). Wall-clock bounding for a delivery is the GenServer's
  # concern (it can run the invoke under its own timeout); fuel is bounded per-call here.
  #
  # `memory.grow` REALLOCATES `:tl_mem` (atomics can't grow in place) and stores the new backing in the
  # dict. So after an invoke we SNAPSHOT the (possibly swapped) `:tl_mem` back into the returned handle.
  # `mem_pages`/globals/table/fuel are stable atomics refs (mutated in place), so they never need re-capture
  # — but we re-read them defensively. Hence `instance_invoke/4` returns `{result, out, new_instance}`: the
  # owner threads the updated handle forward (it differs from the input only if memory grew).

  @typedoc """
  An opaque persistent-guest handle. Captures everything `call_io` would have torn down, so the export
  can be re-entered with the guest's memory/globals/rt still live. Owned by one process; thread the
  `new_instance` returned by `instance_invoke/3` forward.
  """
  @type instance :: %{
          __struct__: __MODULE__.Instance,
          mod: t(),
          mem: reference() | nil,
          mem_pages: reference() | nil,
          max_pages: pos_integer(),
          globals: reference() | nil,
          table: map(),
          rt: map()
        }

  defmodule Instance do
    @moduledoc "Opaque persistent-guest handle (see `TinyLasers.Wasm.instance_*`). Hold it in the owner process."
    defstruct [:mod, :mem, :mem_pages, :max_pages, :globals, :table, :rt, vfs: %{}]
  end

  @doc """
  **Instantiate a guest and KEEP it alive.** Runs setup `name` (e.g. `"_start"` — which for a JS guest
  evals the script, registering `Beam.onMessage`) to completion, then captures the live run context
  (memory/globals/table/fuel/rt) into an `%Instance{}` instead of tearing it down. Returns
  `{:ok, instance, out}` (setup's captured stdout) or `{:exit, code, out}` (setup called `proc_exit`)
  or `{:trap, reason}`.

  Like `call_io`, this snapshots and restores the CALLER's prior process-dict context around the setup
  run, so it is safe to call from inside another run (and leaves the caller's dict untouched). The
  RETURNED instance is the only live reference to the guest's state.
  """
  def instance_start(%__MODULE__{} = mod, name \\ "_start", args \\ [], opts \\ []) when is_list(args) do
    prev = capture_run_ctx()

    globals = new_globals(mod.globals)
    mem_pages = new_mem(mod.mem)
    init_data(globals, mod.data)
    fuel = :atomics.new(1, signed: true)
    :atomics.put(fuel, 1, Keyword.get(opts, :fuel, @default_fuel))
    Process.put(:tl_last_fuel, {Keyword.get(opts, :fuel, @default_fuel), fuel})
    depth = :atomics.new(1, signed: true)
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)
    max_pages = Keyword.get(opts, :max_pages, @default_max_pages)
    table = new_table(mod.elements, globals)
    Process.put(:tl_out, [])
    Process.put(:tl_globals, globals)
    Process.put(:tl_table, table)
    Process.delete(:tl_table_size)
    Process.put(:tl_mem_pages, mem_pages)
    Process.put(:tl_max_pages, max_pages)

    # A persistent instance may opt into the TRANSPILER (asm lane) just like `call_io` — hot exported
    # functions JIT to BEAM assembly and stay compiled across `instance_invoke` re-entries (the
    # `:tl_jit` dict + the mod.id-keyed persistent cache both survive `capture_run_ctx`). This is what
    # makes a long-lived guest (e.g. the Rollup parser serving many `parse` calls) run at asm speed.
    lazy =
      if Keyword.get(opts, :transpile, false) do
        Process.put(:tl_jit, %{})
        counts = :counters.new(max(1, length(mod.code)), [:write_concurrency])
        {counts, Keyword.get(opts, :tier_threshold, 20), Keyword.get(opts, :tier_async, true)}
      else
        nil
      end

    rt = %{mod: mod, mem_pages: mem_pages, globals: globals, table: table, fuel: fuel, depth: depth, max_depth: max_depth, max_pages: max_pages, lazy: lazy, ni: length(mod.imports), gtypes: global_types(mod)}
    Process.put(:tl_rt, rt)

    # START function (section 8): instantiate-time init (e.g. __wasm_init_memory) before the export.
    if mod.start != nil, do: call_fn(rt, mod.start, [])

    try do
      _ = call_fn(rt, Map.fetch!(mod.exports, name), args)
      out = Process.get(:tl_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
      # capture the (possibly grown) memory backing into the handle
      inst = %Instance{
        mod: mod, mem: Process.get(:tl_mem), mem_pages: mem_pages, max_pages: max_pages,
        globals: globals, table: Process.get(:tl_table, table), rt: rt,
        # carry the guest VFS (:map backend) so files written during one re-entry persist into the next
        vfs: Process.get(:tl_vfs, %{})
      }
      {:ok, inst, out}
    catch
      :throw, {:tl_exit, code} ->
        out = Process.get(:tl_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
        {:exit, code, out}
    rescue
      e in TinyLasers.Wasm.Trap -> {:trap, e.reason}
    after
      restore_run_ctx(prev)
    end
  end

  @doc """
  **Re-enter a live guest.** Invoke export `name` (e.g. `"wb_dispatch"`) on `instance`, reusing its
  memory/globals/table/rt — so guest state set up by `instance_start` (and prior invokes) is still there.
  Each call runs to completion with its OWN fresh fuel budget (`:fuel` opt). Returns
  `{:ok, result, out, new_instance}` / `{:exit, code, out, new_instance}` / `{:trap, reason, new_instance}`.

  Always thread `new_instance` forward: if the guest grew memory, its `:tl_mem` backing was swapped and
  the new backing is captured into `new_instance.mem` (the input handle's `mem` is now stale).

  Run this IN THE OWNER PROCESS (the GenServer). It installs the held context into the process dict,
  invokes, snapshots back, and restores the caller's prior dict context in `after` — so a nested invoke
  (or any other run in the same process) is unaffected.
  """
  def instance_invoke(%Instance{} = inst, name, args \\ [], opts \\ []) when is_list(args) do
    prev = capture_run_ctx()

    # fresh fuel + depth per delivery; everything else is the held (mutated-in-place / re-captured) state
    fuel = :atomics.new(1, signed: true)
    :atomics.put(fuel, 1, Keyword.get(opts, :fuel, @default_fuel))
    depth = :atomics.new(1, signed: true)
    rt = %{inst.rt | fuel: fuel, depth: depth}

    Process.put(:tl_out, [])
    Process.put(:tl_mem, inst.mem)
    Process.put(:tl_globals, inst.globals)
    Process.put(:tl_table, inst.table)
    Process.delete(:tl_table_size)
    Process.put(:tl_mem_pages, inst.mem_pages)
    Process.put(:tl_max_pages, inst.max_pages)
    # restore the guest VFS so reads see files written by earlier messages (overrides any per-run reset)
    Process.put(:tl_vfs, inst.vfs || %{})
    Process.put(:tl_last_fuel, {Keyword.get(opts, :fuel, @default_fuel), fuel})
    Process.put(:tl_rt, rt)

    try do
      result = call_fn(rt, Map.fetch!(inst.mod.exports, name), args)
      out = Process.get(:tl_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
      {:ok, result, out, snapshot(inst, rt)}
    catch
      :throw, {:tl_exit, code} ->
        out = Process.get(:tl_out, []) |> Enum.reverse() |> IO.iodata_to_binary()
        {:exit, code, out, snapshot(inst, rt)}
    rescue
      e in TinyLasers.Wasm.Trap -> {:trap, e.reason, snapshot(inst, rt)}
    after
      restore_run_ctx(prev)
    end
  end

  @doc """
  **Free a persistent instance.** The guest's state lives in `:atomics` (off-heap) + the immutable struct;
  there is no native resource to release, so freeing = dropping the references so the GC reclaims the
  atomics. Returns `:ok`. (Explicit so the actor's `terminate` has a clear, intentional teardown point and
  so the API reads symmetrically with `instance_start`.)
  """
  def instance_free(%Instance{}), do: :ok

  @doc """
  **Clone a booted instance** (wb-8mdz.4). Produces a fresh, independent instance with a byte-identical
  copy of the template's linear memory (the whole QuickJS world: heap, the static `g_ctx`, everything) +
  copied globals, sharing the immutable table/vfs maps (Elixir COW). The actor layer boots ONE template
  (QuickJS + the full prelude) once, then clones it per guest and `wb_eval`s just the per-actor script —
  skipping the multi-second prelude re-eval on every spawn. Pure Elixir; no native, no NIF.
  """
  def instance_clone(%Instance{} = t) do
    msize = :atomics.info(t.mem).size
    newmem = :atomics.new(msize, signed: false)
    copy_atomics(t.mem, newmem, msize)

    newpages = :atomics.new(1, signed: false)
    :atomics.put(newpages, 1, :atomics.get(t.mem_pages, 1))

    newglobals = clone_globals(t.globals)
    rt = %{t.rt | mem_pages: newpages, globals: newglobals}
    %Instance{t | mem: newmem, mem_pages: newpages, globals: newglobals, rt: rt}
  end

  defp copy_atomics(src, dst, n), do: for(i <- 1..n//1, do: :atomics.put(dst, i, :atomics.get(src, i)))
  defp clone_globals(nil), do: nil

  defp clone_globals(g) do
    n = :atomics.info(g).size
    ng = :atomics.new(n, signed: false)
    copy_atomics(g, ng, n)
    ng
  end

  # snapshot mutated run state back into the handle. Only `:tl_mem` (reallocated by memory.grow) and the
  # table can change identity per invoke; globals/mem_pages are atomics mutated in place (same ref).
  defp snapshot(%Instance{} = inst, rt) do
    %{
      inst
      | mem: Process.get(:tl_mem),
        table: Process.get(:tl_table, inst.table),
        vfs: Process.get(:tl_vfs, inst.vfs),
        rt: %{rt | fuel: nil, depth: nil}
    }
  end

  # capture / restore the full per-run process-dict context (same keys call_io guards) so instance ops are
  # nesting-safe — a setup/invoke that runs inside another tinylasers run leaves the outer run's dict intact.
  defp capture_run_ctx do
    %{
      out: Process.get(:tl_out), mem: Process.get(:tl_mem), globals: Process.get(:tl_globals),
      table: Process.get(:tl_table), mem_pages: Process.get(:tl_mem_pages),
      max_pages: Process.get(:tl_max_pages), last_fuel: Process.get(:tl_last_fuel),
      rt: Process.get(:tl_rt)
    }
  end

  defp restore_run_ctx(c) do
    restore(:tl_out, c.out)
    restore(:tl_mem, c.mem)
    restore(:tl_globals, c.globals)
    restore(:tl_table, c.table)
    restore(:tl_mem_pages, c.mem_pages)
    restore(:tl_max_pages, c.max_pages)
    restore(:tl_last_fuel, c.last_fuel)
    restore(:tl_rt, c.rt)
  end

  @doc """
  **Host-mediated invocation — the thesis's fork/exec emulation.** A running guest (e.g. a shell)
  invokes another program: `argv[0]` resolves to a wasm module (via the `:tl_programs` registry,
  with a multicall `:default` fallback like coreutils), which Wasm runs NESTED with the given
  `stdin` and `argv`, returning `{stdout, exit_code}`. Cooperative + buffered — no real concurrency,
  no real fork; the guest only needs to BELIEVE it spawned a process.

  The child gets a FRESH fd table + argv/stdin and its own isolated linear memory (call_io allocates
  it); it SHARES the parent's virtual FS so file effects persist across the "pipeline". The parent's
  full context (captured stdout, memory, argv, stdin, fds) is saved and restored around the call —
  nesting-safe because the BEAM handles the re-entrant call_io for free.
  """
  def host_exec([prog | _] = argv, stdin, opts \\ []) when is_binary(stdin) do
    case resolve_program(prog) do
      nil ->
        {"", 127}

      mod ->
        # Snapshot the parent's full fd table (every unified key) so the child gets a FRESH table and
        # the parent's is restored on return — fork/exec emulation, nesting-safe.
        saved =
          {Process.get(:tl_out), Process.get(:tl_mem), Process.get(:tl_argv),
           Process.get(:tl_stdin),
           {Process.get(:tl_fdmap), Process.get(:tl_descs), Process.get(:tl_nextfd),
            Process.get(:tl_nextdesc), Process.get(:tl_pipes)}}

        Process.put(:tl_out, [])
        Process.put(:tl_argv, argv)
        Process.put(:tl_stdin, stdin)
        TinyLasers.Wasm.FdTable.reset()

        # If the PARENT run is tiering, the nested program tiers too — so a pipeline's actual compute
        # (the grep/sort/sha256 in coreutils) runs native, not just the shell. Hot functions compile in
        # the background + cache across invocations, so repeated/heavy commands get fast.
        child_opts =
          case Process.get(:tl_rt) do
            %{lazy: {_, _, _}} -> Keyword.put_new(opts, :transpile, true)
            _ -> opts
          end

        try do
          try do
            {_r, out} = call_io(mod, "_start", [], child_opts)
            {out, 0}
          rescue
            # a child that TRAPS (e.g. a Rust panic → unreachable when it touches outside its sandbox)
            # must not crash the parent — return its partial output + a non-zero exit code.
            _ -> {Process.get(:tl_out, []) |> Enum.reverse() |> IO.iodata_to_binary(), 134}
          catch
            :throw, {:tl_exit, code} ->
              {Process.get(:tl_out, []) |> Enum.reverse() |> IO.iodata_to_binary(), code}
          end
        after
          {o, m, a, s, {fdmap, descs, nfd, ndesc, pipes}} = saved
          restore(:tl_out, o)
          restore(:tl_mem, m)
          restore(:tl_argv, a)
          restore(:tl_stdin, s)
          restore(:tl_fdmap, fdmap)
          restore(:tl_descs, descs)
          restore(:tl_nextfd, nfd)
          restore(:tl_nextdesc, ndesc)
          restore(:tl_pipes, pipes)
        end
    end
  end

  defp restore(key, nil), do: Process.delete(key)
  defp restore(key, val), do: Process.put(key, val)

  @doc """
  Invoke a HOST IMPORT by its decoded spec (`{module, name, type_idx}`) with `args` — the seam the
  **transpiler** uses to perform WASI/host I/O from compiled BEAM code. It dispatches to the exact same
  `call_host` the interpreter uses, so a transpiled guest and an interpreted guest do identical I/O.
  Host functions read/write guest memory via the process-dict `:tl_mem` (set up by the run), not
  `rt` — so a `nil` runtime is fine here. proc_exit still throws `{:tl_exit, code}`; the caller catches.
  """
  def invoke_host({_module, _name, _type} = spec, args) when is_list(args), do: call_host(nil, spec, args)

  @doc """
  **Trampoline from transpiled code back into the interpreter.** A native (transpiled) function calls
  this for a callee that was NOT transpiled (interpreted lane), passing the global func index + arg
  list. It dispatches through the same `call_fn` the interpreter uses (host import → `call_host`, local
  → `invoke`, which may itself re-dispatch to native), all on the shared run state held in `:tl_rt`.
  """
  def call_local(fidx, args) when is_integer(fidx) and is_list(args) do
    bench_tick(8)
    case Process.get(:tl_rt) do
      nil -> raise "call_local/2 outside a tinylasers run (no :tl_rt)"
      rt -> call_fn(rt, fidx, args)
    end
  end

  @doc """
  **Indirect call from transpiled code on the shared run state.** Mirrors the interpreter's
  `{:call_indirect, typeidx}` step EXACTLY: resolve the table index → global func index (trap
  `:undefined_element` if absent), check the resolved func's type against the expected signature at
  `typeidx` (trap `:indirect_call_type_mismatch` on mismatch), then dispatch through the same `call_fn`
  on the shared `:tl_rt`. Returns the callee result (or `nil` for a void target).
  """
  def call_indirect_dyn(table_idx, typeidx, args)
      when is_integer(table_idx) and is_integer(typeidx) and is_list(args) do
    case Process.get(:tl_rt) do
      nil ->
        raise "call_indirect_dyn/3 outside a tinylasers run (no :tl_rt)"

      rt ->
        f = Map.get(rt.table, table_idx)
        if f == nil, do: trap!(:undefined_element)
        expected = Enum.at(rt.mod.types, typeidx)
        if func_type(rt.mod, f) != expected, do: trap!(:indirect_call_type_mismatch)
        call_fn(rt, f, args)
    end
  end

  @doc """
  **Capture the current run context so a cooperative GENERATOR FIBER can adopt it.** A generator instance
  runs its compiled wasm body on its own BEAM process (a fiber — `Nexus.Porffor.GeneratorFiber`), suspending
  at each `yield`; that fiber must see the SAME linear memory/table/fuel the parent guest sees, so the
  yielded values it writes land in the shared heap the parent reads.

  Returns a snapshot map the fiber passes to `gen_adopt_context/1`. The fiber SHARES (same atomics ref) the
  parent's memory, table, `:tl_last_fuel` (isolation invariant 4 — a generator charges the ONE per-run
  fuel budget, so a guest can't shard compute across fibers to dodge it), AND the globals. Sharing globals
  is both safe and necessary: Porffor keeps no shadow stack pointer (operands/locals live on the wasm value
  stack, preserved by the parked fiber's frozen BEAM call stack) — the only mutable internal globals are the
  malloc bump (`currentPtr`/`endPtr`/`heapStart`), which MUST be shared so the fiber's allocations are
  coherent with the parent's (a copy gives the fiber its own cursor → the parent overwrites the generator's
  yielded objects). Sharing also lets `yield`/`next(v)`/`return` values ride plain `any` module globals the
  fiber and parent both see — real JS values, full types, objects included, no marshaling. Single-active
  (the AsyncFiber baton) means only one of {parent, fiber} touches the shared globals at any instant.
  """
  @spec gen_capture_context() :: map
  def gen_capture_context do
    %{
      mem: Process.get(:tl_mem),
      mem_pages: Process.get(:tl_mem_pages),
      max_pages: Process.get(:tl_max_pages),
      mem_shared: Process.get(:tl_mem_shared),
      table: Process.get(:tl_table),
      table_size: Process.get(:tl_table_size),
      # SHARED (not copied) — the one per-run fuel atomics. Invariant 4.
      last_fuel: Process.get(:tl_last_fuel),
      programs: Process.get(:tl_programs),
      vfs: Process.get(:tl_vfs),
      jit: Process.get(:tl_jit),
      # the host-import table the fiber needs to resolve its OWN __porffor_gen_yield call (and any other
      # host import the generator body reaches) — call_host's registrable seam reads this from the dict.
      imports: Process.get(:tl_imports),
      rt: Process.get(:tl_rt),
      # SHARED (same atomics ref) — coherent malloc + value globals across the park (see moduledoc).
      globals: Process.get(:tl_globals)
    }
  end

  @doc """
  **Adopt a captured generator run context into the current (fiber) process.** Called at the top of a
  generator-fiber body before it invokes the wasm generator function via `call_local/2`. Installs the shared
  mem/table/fuel and the fiber's own globals, and re-homes the `rt` onto those globals so `call_local`/
  `call_indirect_dyn` resolve against this fiber's stack. Mirrors `do_guest_thread_spawn`'s child install,
  minus the fd/socket table snapshot (a generator body does pure compute over the shared heap).
  """
  @spec gen_adopt_context(map) :: :ok
  def gen_adopt_context(ctx) do
    Process.put(:tl_mem, ctx.mem)
    if ctx.mem_pages, do: Process.put(:tl_mem_pages, ctx.mem_pages)
    if ctx.max_pages, do: Process.put(:tl_max_pages, ctx.max_pages)
    if ctx.mem_shared, do: Process.put(:tl_mem_shared, ctx.mem_shared)
    Process.put(:tl_table, ctx.table)
    if ctx.table_size, do: Process.put(:tl_table_size, ctx.table_size)
    Process.put(:tl_last_fuel, ctx.last_fuel)
    Process.put(:tl_globals, ctx.globals)
    if ctx.programs, do: Process.put(:tl_programs, ctx.programs)
    if ctx.vfs, do: Process.put(:tl_vfs, ctx.vfs)
    if ctx.jit, do: Process.put(:tl_jit, ctx.jit)
    if ctx.imports, do: Process.put(:tl_imports, ctx.imports)
    Process.put(:tl_out, [])
    # the fiber's rt shares the parent's mem/table/fuel refs but points at the fiber's own globals.
    if ctx.rt, do: Process.put(:tl_rt, %{ctx.rt | globals: ctx.globals})
    :ok
  end

  @doc "Build a module's mutable globals array (the transpiler installs this in `:tl_globals`)."
  def init_globals(%__MODULE__{} = mod), do: new_globals(mod.globals)

  @doc """
  Charge one unit of fuel (the transpiler calls this on each loop back-edge so a transpiled loop can't
  spin unbounded). Raises the SAME `:out_of_fuel` trap the interpreter does when the budget is spent.
  Coarser than the interpreter's per-instruction charge (per-iteration here), but it bounds runaway loops.
  """
  def charge_fuel do
    case Process.get(:tl_last_fuel) do
      {_budget, fuel} -> if :atomics.sub_get(fuel, 1, 1) < 0, do: trap!(:out_of_fuel)
      _ -> :ok
    end
  end

  # argv[0] → a wasm module: an explicit program, else a multicall `:default` (e.g. coreutils) that
  # dispatches on argv[0]. nil = command not found.
  defp resolve_program(name) do
    progs = Process.get(:tl_programs, %{})
    Map.get(progs, name) || Map.get(progs, :default)
  end

  # Linear memory is PACKED + RIGHT-SIZED for density: the backing `:atomics` is sized to the module's
  # `min` pages (NOT a 64-page cap) with 8 bytes per slot, and lives in the process dict (`:tl_mem`)
  # so `memory.grow` can REALLOCATE it (atomics can't grow in place) and every reader sees the new
  # backing. One guest = one process, so the dict is the right mutable cell. `mem_pages` (logical page
  # count) is a stable 1-slot atomics. `wmem/0` is the current backing.
  @page_words 8192
  defp wmem, do: Process.get(:tl_mem)

  # bool → u8 (for WASIX struct fields)
  defp b(true), do: 1
  defp b(_), do: 0

  defp new_mem(nil), do: (Process.delete(:tl_mem); nil)

  # SHARED memory (threads, §2): PRE-ALLOCATE the backing at the declared max up front. `memory.grow`
  # then only bumps the page-count counter (`:tl_mem_pages`) and NEVER reallocates the `:atomics`
  # ref — so every spawned thread keeps reading/writing the SAME backing (true shared memory). A shared
  # memory always declares a max (WASM threads spec); if somehow absent, fall back to min (single-thread).
  defp new_mem({min, max, :shared}) when is_integer(max) do
    pages = max(1, min)
    Process.put(:tl_mem, :atomics.new(max * @page_words, signed: false))
    # mark the run as shared-memory: grow must NOT realloc (would desync spawned threads).
    Process.put(:tl_mem_shared, true)
    pref = :atomics.new(1, signed: false)
    :atomics.put(pref, 1, pages)
    pref
  end

  defp new_mem({min, max}) when is_integer(min), do: new_mem({min, max, :unshared})

  defp new_mem({min, _max, _share}) do
    pages = max(1, min)
    Process.put(:tl_mem, :atomics.new(pages * @page_words, signed: false))
    Process.delete(:tl_mem_shared)
    pref = :atomics.new(1, signed: false)
    :atomics.put(pref, 1, pages)
    pref
  end

  @doc """
  `memory.grow(n)` for TRANSPILED code — mirrors the interpreter's grow exactly: realloc `:tl_mem`
  to `old+n` pages (copying live words), bump the `:tl_mem_pages` count, return the OLD page count;
  or `-1` (masked to i32) when `n<0` or the new size exceeds the run's `:tl_max_pages` ceiling. Reads
  all state from the process dict (the shared run context), so a transpiled and an interpreted grow are
  identical. Transpiled load/store re-read `:tl_mem` per access, so they see the grown backing.
  """
  def guest_memory_grow(n) do
    mem_pages = Process.get(:tl_mem_pages)
    old = :atomics.get(mem_pages, 1)
    new = old + n

    cond do
      n < 0 or new > Process.get(:tl_max_pages, @default_max_pages) ->
        -1 &&& @mask32

      # shared memory: counter bump only (backing pre-allocated at max) — see step({:memory_grow}).
      Process.get(:tl_mem_shared) ->
        :atomics.put(mem_pages, 1, new)
        old

      true ->
        oldmem = wmem()
        newmem = :atomics.new(new * @page_words, signed: false)
        for i <- 1..(old * @page_words)//1, do: :atomics.put(newmem, i, :atomics.get(oldmem, i))
        Process.put(:tl_mem, newmem)
        :atomics.put(mem_pages, 1, new)
        old
    end
  end

  # IEEE-754 float arithmetic for TRANSPILED code (wb-8mdz.3) — the SAME farith the interpreter uses, so a
  # transpiled f32/f64 add/sub/mul/div by zero / overflow / on a non-finite operand yields ±Inf/NaN instead
  # of raising ArithmeticError. `op` ∈ :add|:sub|:mul|:div, `size` ∈ 32|64. Oracle-green by construction
  # (asm call_exts the identical function the interp calls).
  def guest_farith(a, b, op, size), do: farith(a, b, op, size)

  @doc "IEEE float comparison for transpiled code — 0/1, NaN-unordered, identical to the interp's fcmp."
  def guest_fcmp(a, b, op), do: if(fcmp(a, b, op), do: 1, else: 0)

  @doc "IEEE float min/max/abs/neg/sqrt for transpiled code — non-finite-safe, identical to the interp."
  def guest_fminmax(a, b, which, size), do: fminmax(a, b, which, size)
  def guest_fabs(a, size), do: fabs(a, size)
  def guest_fneg(a, size), do: fneg(a, size)
  def guest_fsqrt(a, size), do: fsqrt(a, size)

  @doc "IEEE float ceil/floor/trunc/nearest/copysign for transpiled code — non-finite-safe, == the interp."
  def guest_fceil(a, size), do: fround_unary(a, size, &Float.ceil/1)
  def guest_ffloor(a, size), do: fround_unary(a, size, &Float.floor/1)
  def guest_ftrunc(a, size), do: fround_unary(a, size, fn x -> trunc(x) * 1.0 end)
  def guest_fnearest(a, size), do: fround_unary(a, size, &fnearest/1)
  def guest_fcopysign(a, b, size), do: fcopysign_nf(a, b, size)

  @doc "sign-extension ops for transpiled code (i32/i64.extend8_s/16_s/32_s) — identical to the interp."
  def guest_i32_extend8_s(a), do: sext(a &&& 0xFF, 8)
  def guest_i32_extend16_s(a), do: sext(a &&& 0xFFFF, 16)
  def guest_i64_extend8_s(a), do: sext64(a &&& 0xFF, 8)
  def guest_i64_extend16_s(a), do: sext64(a &&& 0xFFFF, 16)
  def guest_i64_extend32_s(a), do: sext64(a &&& @mask32, 32)

  @doc "exnref throw/throw_ref for transpiled code — same {:wasm_exc,…} Elixir-throw the interp uses, so a
  try_table (interp or asm) catches it identically and an uncaught one propagates out of the function."
  def guest_throw(tagidx, vals), do: throw({:wasm_exc, tagidx, vals})
  def guest_throw_ref({:exnref, tag, vals}), do: throw({:wasm_exc, tag, vals})
  def guest_throw_ref(:null), do: trap!(:null_exnref)
  def guest_throw_ref(_), do: trap!(:not_an_exnref)

  @doc "tag arity (operand count a `throw` consumes), from the module's tag→type table — for the asm lane."
  def tag_arity_of(mod, tagidx) do
    typeidx = Enum.at(mod.tags, tagidx)
    {params, _results} = Enum.at(mod.types, typeidx)
    length(params)
  end

  # ── try_table (catch side) helpers for the asm lane — mirror the interp's match_catch/handle_catch.
  # A try_table's BEAM `try_case` hands us {class, reason}; only a wasm exception ({:throw, {:wasm_exc,…}})
  # is ours to dispatch — anything else (a host error/exit) is re-raised so it propagates identically.
  @doc "Decode a caught BEAM throw into `{:exc, tag, vals}` when it's a wasm exception, else `:rethrow`."
  def guest_catch_match(:throw, {:wasm_exc, tag, vals}), do: {:exc, tag, vals}
  def guest_catch_match(_class, _reason), do: :rethrow

  @doc "Re-raise a non-matching/non-wasm exception with its original class + captured stacktrace."
  def guest_reraise(class, reason, stacktrace), do: :erlang.raise(class, reason, stacktrace)

  @doc "Build an exnref term `{:exnref, tag, vals}` for a `catch_ref`/`catch_all_ref` clause."
  def guest_mk_exnref(tag, vals), do: {:exnref, tag, vals}

  # ── reftypes / table ops for TRANSPILED code (WASIX §0) — bit-identical mirrors of the interpreter's
  # step({:ref_*}/{:table_*}) handlers, reading the shared run state (:tl_rt / :tl_table). The asm
  # lane call_exts these so table/ref ops run NATIVE instead of falling back to the interpreter. ──
  @doc "`ref.is_null` for transpiled code — 1 if the popped ref is the null sentinel, else 0."
  def guest_ref_is_null(:null), do: 1
  def guest_ref_is_null(_), do: 0

  @doc "`table.get(i)` — the table entry at `i` (global func index / ref), or the null sentinel."
  def guest_table_get(i) do
    rt = Process.get(:tl_rt)
    Map.get(Process.get(:tl_table, rt.table), i, :null)
  end

  @doc "`table.set(i, v)` — store ref `v` at index `i` in the mutable table. Returns :ok."
  def guest_table_set(i, v) do
    rt = Process.get(:tl_rt)
    Process.put(:tl_table, Map.put(Process.get(:tl_table, rt.table), i, v))
    :ok
  end

  @doc "`table.size` — current table length."
  def guest_table_size, do: table_size(Process.get(:tl_rt))

  @doc "`table.grow(init, n)` — append `n` slots of `init`; returns old size, or -1 (u32) past the max."
  def guest_table_grow(init, n) do
    rt = Process.get(:tl_rt)
    old = table_size(rt)
    new = old + n
    max = case rt.mod.table_type do {_, m} -> m; _ -> nil end

    if max != nil and new > max do
      -1 &&& @mask32
    else
      table = Enum.reduce(grow_range(old, new), Process.get(:tl_table, rt.table), fn idx, t -> Map.put(t, idx, init) end)
      Process.put(:tl_table, table)
      Process.put(:tl_table_size, new)
      old
    end
  end

  @doc "`table.fill(i, val, n)` — set `n` slots from `i` to ref `val`. Returns :ok."
  def guest_table_fill(i, val, n) do
    rt = Process.get(:tl_rt)
    table = Enum.reduce(grow_range(i, i + n), Process.get(:tl_table, rt.table), fn idx, t -> Map.put(t, idx, val) end)
    Process.put(:tl_table, table)
    Process.delete(:tl_table_size)
    :ok
  end

  @doc "`memory.copy(dst, src, n)` for transpiled code — mirrors the interpreter (overlap-safe, bounds-trapped)."
  def guest_memory_copy(dst, src, n) do
    if n > 0 do
      mem = wmem()
      bounds_g!(dst, n)
      bounds_g!(src, n)
      mem_copy(mem, dst, src, n)
    end

    :ok
  end

  @doc """
  `memory.init(dst, src, n)` for transpiled code — copy n bytes from the (immutable) data segment `bytes`
  (resolved at compile time by the asm lane) into memory at dst. Mirrors the interpreter: src-bounds trap
  `:out_of_bounds_data` first, then dst-bounds, then byte copy; n=0 is a no-op.
  """
  def guest_memory_init(bytes, dst, src, n) do
    if n > 0 do
      if src + n > byte_size(bytes), do: trap!(:out_of_bounds_data)
      bounds_g!(dst, n)
      mem = wmem()
      for i <- 0..(n - 1)//1, do: store(mem, dst + i, :binary.at(bytes, src + i), 1)
    end

    :ok
  end

  @doc "`memory.fill(dst, val, n)` for transpiled code — mirrors the interpreter (byte fill, bounds-trapped)."
  def guest_memory_fill(dst, val, n) do
    if n > 0 do
      mem = wmem()
      bounds_g!(dst, n)
      for i <- 0..(n - 1)//1, do: store(mem, dst + i, val, 1)
    end

    :ok
  end

  @doc """
  `memory.size` for TRANSPILED code — current page count read from the shared `:tl_mem_pages`
  atomics (mirrors the interpreter, which reads `rt.mem_pages`; same backing).
  """
  def guest_memory_size do
    :atomics.get(Process.get(:tl_mem_pages), 1)
  end

  @doc """
  Bounds-checked little-endian UNSIGNED integer load of `n` bytes at `addr` for TRANSPILED code.
  Reads `:tl_mem` from the process dict per access (so a grown backing is seen), traps
  `:out_of_bounds` against the logical memory size — byte-identical to the interpreter's `gload/3`.
  """
  def guest_load(addr, n) do
    bounds_g!(addr, n)
    load(wmem(), addr, n)
  end

  @doc """
  Bounds-checked SIGNED integer load (load8_s / load16_s): load `n` bytes unsigned, then sign-extend
  from `n*8` bits into the unsigned i32 representation — mirrors the interpreter's `sext(gload(..), bits)`.
  """
  def guest_load_s(addr, n) do
    bounds_g!(addr, n)
    sext(load(wmem(), addr, n), n * 8)
  end

  @doc "Bounds-checked SIGNED load that sign-extends to 64 bits (i64 partial loads). Matches the interpreter's `{:i64_load, _, n, true}` (`sext64(v, n*8)`)."
  def guest_load_s64(addr, n) do
    bounds_g!(addr, n)
    sext64(load(wmem(), addr, n), n * 8)
  end

  @doc """
  Bounds-checked FLOAT load (f32/f64) for TRANSPILED code — bit-identical to the interpreter's `gfload/3`
  (`fload/2` → `decode_f`): returns an Elixir float for finite values, or `{:nonfinite, bits, size}` for
  ±Inf/NaN/-0 (the same shape every float op in both lanes carries). n ∈ 4 (f32) | 8 (f64).
  """
  def guest_fload(addr, n) do
    bounds_g!(addr, n)
    fload(wmem(), addr, n)
  end

  @doc """
  Bounds-checked FLOAT store (f32/f64) for TRANSPILED code — bit-identical to the interpreter's `gfstore/4`
  (`fstore/3`): encodes a finite float (or `{:nonfinite, bits, size}`) to little-endian bytes and writes them.
  """
  def guest_fstore(addr, val, n) do
    bounds_g!(addr, n)
    fstore(wmem(), addr, val, n)
  end

  @doc """
  Bounds-checked little-endian integer store of the low `n` bytes of `val` at `addr` for TRANSPILED
  code — byte-identical to the interpreter's `gstore/4`. Returns `:ok`.
  """
  def guest_store(addr, val, n) do
    bounds_g!(addr, n)
    store(wmem(), addr, val, n)
  end

  # Atomic read-modify-write host helper for the asm lane — same byte math as the interpreter's
  # {:atomic_rmw, ...} step. `opc`: 0=add 1=sub 2=and 3=or 4=xor 5=xchg. Returns the OLD value.
  @doc false
  def guest_atomic_rmw(addr, val, n, opc) do
    bounds_g!(addr, n)
    m = mask_n(n)

    atomic_word_cas(wmem(), addr, n, fn old ->
      case opc do
        0 -> (old + val) &&& m
        1 -> (old - val) &&& m
        2 -> (old &&& val) &&& m
        3 -> (old ||| val) &&& m
        4 -> bxor(old, val) &&& m
        5 -> val &&& m
      end
    end)
  end

  @doc false
  def guest_atomic_cmpxchg(addr, expected, repl, n) do
    bounds_g!(addr, n)
    m = mask_n(n)
    exp = expected &&& m
    repl = repl &&& m
    atomic_word_cas(wmem(), addr, n, fn old -> if old == exp, do: repl, else: old end)
  end

  # Atomic n-byte read-modify-write via a word-level CAS loop on the packed `:atomics` memory. The plain
  # `load`+compute+`store` form is a NON-atomic RMW: under emulated threads (BEAM processes sharing wmem)
  # two threads interleave and lose updates (e.g. a 2000-increment counter lands at 1994). wasm atomics are
  # naturally aligned, so an n≤8-byte value never straddles a 64-bit word — CAS the containing word until it
  # sticks. Returns the OLD field value (the result every atomic RMW / cmpxchg op yields).
  defp atomic_word_cas(mem, addr, n, compute) do
    idx = (addr >>> 3) + 1
    shift = (addr &&& 7) * 8
    fmask = mask_n(n)
    wmask = fmask <<< shift
    cas_loop(mem, idx, shift, fmask, wmask, compute)
  end

  defp cas_loop(mem, idx, shift, fmask, wmask, compute) do
    word = :atomics.get(mem, idx)
    old = (word >>> shift) &&& fmask
    new = compute.(old) &&& fmask
    newword = ((word &&& bnot(wmask)) ||| (new <<< shift)) &&& @mask64

    case :atomics.compare_exchange(mem, idx, word, newword) do
      :ok -> old
      _actual -> cas_loop(mem, idx, shift, fmask, wmask, compute)
    end
  end

  # ── FUTEX + THREADS (WASIX §2) ──────────────────────────────────────────────────────────────────
  #
  # ARCHITECTURE. Wasm linear memory is `:tl_mem`, an `:atomics` ref — and `:atomics` are SHAREABLE
  # across BEAM processes (off-heap, mutated in place). So a thread spawned by `thread_spawn` runs in
  # its OWN BEAM process yet reads/writes the SAME atomics-backed memory + table as its parent: true
  # shared memory, no copy. What's SHARED vs COPIED per thread:
  #   • SHARED (same ref in every thread): `:tl_mem` (memory), `:tl_table`, `:tl_mem_pages`,
  #     `:tl_max_pages`, `:tl_mem_shared`, `:tl_rt` (carries the same mem/table/fuel refs).
  #   • COPIED (per-thread): the `:tl_globals` atomics array — wasi-libc keeps `__stack_pointer` in a
  #     mutable global, so each thread needs its OWN stack pointer (and thus its own globals array) or
  #     two threads would smash one stack. We deep-copy the parent's globals into a fresh atomics ref.
  #   • `:tl_out` is fresh per thread (a thread's stdout is its own; it shares memory, not the buffer).
  # Memory MUST be `shared` (pre-allocated at max — see new_mem) so grow never reallocates the backing
  # out from under a running thread.
  #
  # FUTEX REGISTRY. A named public ETS bag `:tl_futex` keyed `{mem_id, byte_addr}` → waiter pid.
  # `mem_id` identifies the shared memory: we use the `:tl_mem` atomics ref itself (a stable term
  # for the lifetime of the run; shared threads hold the same ref ⇒ same key). Lazily created.

  @futex_max_wait_ms 60_000

  # Lazily ensure the public futex ETS bag exists (survives concurrent creation by losing the race).
  defp futex_table do
    case :ets.whereis(:tl_futex) do
      :undefined ->
        try do
          :ets.new(:tl_futex, [:named_table, :public, :bag])
        rescue
          ArgumentError -> :tl_futex
        end

      _ ->
        :tl_futex
    end
  end

  # The shared-memory id used to key futex waiters: the `:tl_mem` atomics ref (stable, shared).
  defp futex_mem_id, do: Process.get(:tl_mem)

  @doc """
  **`memory.atomic.wait(addr, expected, timeout_ns)` — real futex wait (WASIX §2).** ONE impl shared
  by the interpreter (`step({:atomic_wait,…})`) and the asm lane (`AsmOps.Atomics`). Returns `0` woken /
  `1` not-equal / `2` timed-out.

  Atomically reads `mem[addr]` (width `n` = 4 or 8); if it `!= expected`, returns 1 immediately (no
  block). Otherwise registers `self()` in `:tl_futex` under `{mem_id, addr}` and blocks in a
  SELECTIVE receive on the exact `{:wb_wake, addr}` (so it never swallows unrelated mailbox messages),
  BOUNDED by `after timeout_ms`. `timeout_ns < 0` ("infinite") is still capped at `@futex_max_wait_ms`
  — never an unbounded block. Always deregisters self from the bag on exit (woken OR timed out).
  """
  def guest_atomic_wait(addr, expected, n, timeout_ns) do
    bounds_g!(addr, n)
    cur = load(wmem(), addr, n)

    if cur != (expected &&& mask_n(n)) do
      1
    else
      tab = futex_table()
      key = {futex_mem_id(), addr}
      :ets.insert(tab, {key, self()})

      timeout_ms =
        cond do
          timeout_ns < 0 -> @futex_max_wait_ms
          true -> min(@futex_max_wait_ms, ceil(timeout_ns / 1_000_000))
        end

      try do
        receive do
          {:wb_wake, ^addr} -> 0
        after
          timeout_ms -> 2
        end
      after
        :ets.delete_object(tab, {key, self()})
      end
    end
  end

  @doc """
  **`memory.atomic.notify(addr, count)` — real futex notify (WASIX §2).** Wakes up to `count` pids
  registered on `{mem_id, addr}` by sending each `{:wb_wake, addr}` and removing it from the bag.
  Returns the number actually woken (an i32). `count == 0xFFFFFFFF` (-1) means "all waiters". ONE impl
  shared by interpreter + asm lane.
  """
  def guest_atomic_notify(addr, count) do
    tab = futex_table()
    key = {futex_mem_id(), addr}
    waiters = for {^key, pid} <- :ets.lookup(tab, key), do: pid
    want = if count == @mask32 or count < 0, do: length(waiters), else: count

    woken =
      waiters
      |> Enum.take(want)
      |> Enum.reduce(0, fn pid, acc ->
        # remove BEFORE sending so a re-waiting thread can re-register cleanly.
        :ets.delete_object(tab, {key, pid})
        send(pid, {:wb_wake, addr})
        acc + 1
      end)

    woken
  end

  # ── thread_spawn / lifecycle ──
  #
  # WASIX/wasi-libc thread ABI: the guest module EXPORTS `wasi_thread_start(tid: i32, start_arg: i32)`.
  # The host import `thread_spawn(start_arg_ptr: i32) -> tid(i32)` allocates a tid (a per-run counter)
  # and spawns a BEAM process that adopts the parent's SHARED run context (memory/table/pages/rt) with a
  # FRESH globals copy + fresh stdout, then invokes `wasi_thread_start` with `[tid, start_arg]`. We
  # spawn+monitor (NOT link) so a thread crash logs but never propagates a raw EXIT that breaks the
  # parent run. spawn is async: the tid is returned immediately and the thread runs concurrently.

  @doc false
  def guest_thread_spawn(start_arg) do
    rt = Process.get(:tl_rt) || raise "thread_spawn outside a tinylasers run (no :tl_rt)"

    # allocate a tid (per-run counter in the rt's atomics-backed slot; tids start at 1).
    tid = next_tid()
    do_guest_thread_spawn(rt, tid, start_arg)
  end

  # Shared spawn body for both `thread_spawn` (start_arg returned as tid) and `thread_spawn_v2`
  # (config_ptr passed through, tid written to a ret ptr). Registers tid→worker-pid in the public
  # `:tl_threads` table so `thread_join(tid)` can BOUNDED-wait on it, and stamps the child's own
  # `:tl_thread_id` so `thread_id` reports it. Returns the tid.
  defp do_guest_thread_spawn(rt, tid, start_arg) do

    # capture the SHARED refs the child must adopt (same atomics, not copies).
    parent = %{
      mem: Process.get(:tl_mem),
      mem_pages: Process.get(:tl_mem_pages),
      max_pages: Process.get(:tl_max_pages),
      mem_shared: Process.get(:tl_mem_shared),
      table: Process.get(:tl_table),
      table_size: Process.get(:tl_table_size),
      last_fuel: Process.get(:tl_last_fuel),
      rt: rt,
      programs: Process.get(:tl_programs),
      vfs: Process.get(:tl_vfs),
      tid_counter: Process.get(:tl_tid_counter),
      # POSIX threads SHARE the fd table. We SNAPSHOT the parent's fd maps into the child at spawn so
      # fds that existed AT SPAWN TIME are visible in the child (covers the common server-thread-
      # accepts-on-main's-listen-fd pattern). These are plain term maps in the dict — a shallow copy
      # is the snapshot. (An fd opened in one thread AFTER spawn being visible in another is the rarer
      # case → true shared fd table via ETS is a follow-up, wb-followup.) The fd/desc/sock id counters
      # are copied too so the child allocates non-colliding ids for its own new fds.
      fdmap: Process.get(:tl_fdmap),
      descs: Process.get(:tl_descs),
      nextfd: Process.get(:tl_nextfd),
      nextdesc: Process.get(:tl_nextdesc),
      pipes: Process.get(:tl_pipes),
      sockstate: Process.get(:tl_sockstate),
      socknext: Process.get(:tl_socknext)
    }

    # fresh per-thread globals (own stack pointer) — deep-copy the parent's globals atomics.
    child_globals = copy_globals(Process.get(:tl_globals))

    {pid, _ref} =
      spawn_monitor(fn ->
        # install the child's run context: SHARED mem/table/pages/rt, COPIED globals, fresh stdout.
        Process.put(:tl_mem, parent.mem)
        Process.put(:tl_mem_pages, parent.mem_pages)
        Process.put(:tl_max_pages, parent.max_pages)
        if parent.mem_shared, do: Process.put(:tl_mem_shared, parent.mem_shared)
        Process.put(:tl_table, parent.table)
        if parent.table_size, do: Process.put(:tl_table_size, parent.table_size)
        Process.put(:tl_last_fuel, parent.last_fuel)
        Process.put(:tl_globals, child_globals)
        Process.put(:tl_out, [])
        if parent.programs, do: Process.put(:tl_programs, parent.programs)
        if parent.vfs, do: Process.put(:tl_vfs, parent.vfs)
        if parent.tid_counter, do: Process.put(:tl_tid_counter, parent.tid_counter)
        # adopt the parent's fd table snapshot (see `parent` capture for the model). gen_tcp/gen_udp
        # transports in :tl_sockstate are BEAM ports owned by the parent process; gen_tcp.accept/recv
        # from a non-controlling process fails, so we re-home each live transport's controlling_process
        # to this child. (Single-server-thread is the dominant pattern; multi-thread-shared-socket is
        # the same follow-up as the post-spawn fd-visibility gap.) HostSock's :tl_sock teardown hook
        # is reinstalled below so the child's FdTable.close frees ports correctly.
        if parent.fdmap, do: Process.put(:tl_fdmap, parent.fdmap)
        if parent.descs, do: Process.put(:tl_descs, parent.descs)
        if parent.nextfd, do: Process.put(:tl_nextfd, parent.nextfd)
        if parent.nextdesc, do: Process.put(:tl_nextdesc, parent.nextdesc)
        if parent.pipes, do: Process.put(:tl_pipes, parent.pipes)

        if parent.sockstate do
          Process.put(:tl_sockstate, parent.sockstate)
          if parent.socknext, do: Process.put(:tl_socknext, parent.socknext)
          TinyLasers.Wasm.HostSock.install()
        end
        # the child knows its own thread id (so `thread_id` reports the tid, not 1).
        Process.put(:tl_thread_id, tid)
        # the child's rt shares the same mem/table/fuel refs, but points at the child's globals.
        Process.put(:tl_rt, %{rt | globals: child_globals})

        export = Map.get(rt.mod.exports, "wasi_thread_start")

        if export do
          try do
            call_fn(%{rt | globals: child_globals}, export, [tid, start_arg])
          catch
            :throw, {:tl_exit, _code} -> :ok
          end
        end
      end)

    # Re-home each live socket transport to the child: gen_tcp.accept/recv must be issued by the
    # transport's CONTROLLING process, and only the CURRENT owner (this parent) may transfer it — so
    # the handoff happens HERE, not inside the child. The parent's own subsequent socket ops (e.g. the
    # main thread's client connect/send/recv on its own fd) re-home back lazily: gen_tcp ops tolerate a
    # non-owner for connect, and recv/send go through whichever process holds the port. For the
    # canonical loopback-server pattern (main creates+listens, child accepts) this gives the child the
    # listen socket. (Bounded; swallow not-owner/closed.)
    if parent.sockstate do
      for {_id, %{transport: t}} <- parent.sockstate, is_port(t) do
        try do
          :gen_tcp.controlling_process(t, pid)
        catch
          _, _ -> :ok
        end
      end
    end

    # register tid→worker-pid so thread_join(tid) can await this BEAM process (cleared on reap).
    threads_table() |> :ets.insert({tid, pid})
    # track this run's worker pids so the run can tear them down on exit — a guest's main exiting
    # (proc_exit) must kill its threads, not leave them parked in futex_wait for the 60s cap (rayon's
    # pool leaves idle workers blocked on a futex after the parallel region; without teardown the run
    # lingers). Mirrors POSIX: process exit terminates all threads.
    Process.put(:tl_thread_pids, [pid | Process.get(:tl_thread_pids, [])])

    # reap the monitor message so the parent's mailbox stays clean; log a crash, never propagate it.
    parent_self = self()

    spawn(fn ->
      ref2 = Process.monitor(pid)

      receive do
        {:DOWN, ^ref2, :process, ^pid, reason} when reason in [:normal, :noproc] -> :ok
        {:DOWN, ^ref2, :process, ^pid, reason} ->
          require Logger
          Logger.warning("tinylasers thread #{tid} (#{inspect(pid)}) crashed: #{inspect(reason)} (parent #{inspect(parent_self)})")
      after
        @futex_max_wait_ms -> :ok
      end

      # thread is terminal — drop its tid→pid mapping; a later join short-circuits (already done).
      :ets.delete(threads_table(), tid)
    end)

    tid
  end

  # Public ETS map tid → worker BEAM pid for spawned threads (WASIX §2 thread_join). Lazily created;
  # survives a concurrent-creation race by catching the ArgumentError and re-reading the name.
  defp threads_table do
    case :ets.whereis(:tl_threads) do
      :undefined ->
        try do
          :ets.new(:tl_threads, [:named_table, :public, :set])
        rescue
          ArgumentError -> :tl_threads
        end

      _ ->
        :tl_threads
    end
  end

  # Per-run thread-id counter (1, 2, 3, …). Stored as an `:atomics` ref in the dict so all threads of a
  # run share ONE monotonically increasing counter (each spawn gets a unique tid).
  defp next_tid do
    ctr =
      case Process.get(:tl_tid_counter) do
        nil ->
          c = :atomics.new(1, signed: true)
          Process.put(:tl_tid_counter, c)
          c

        c ->
          c
      end

    :atomics.add_get(ctr, 1, 1)
  end

  # Deep-copy a globals atomics array (per-thread, for an independent stack pointer). nil stays nil.
  defp copy_globals(nil), do: nil

  defp copy_globals(src) do
    %{size: size} = :atomics.info(src)
    dst = :atomics.new(size, signed: false)
    for i <- 1..size//1, do: :atomics.put(dst, i, :atomics.get(src, i))
    dst
  end

  # Deep-copy a linear-memory atomics (fork: the child gets a PRIVATE copy so parent/child writes are
  # isolated — POSIX copy-on-fork semantics, eagerly). Same shape as copy_globals; sized off the source.
  defp copy_mem(nil), do: nil

  defp copy_mem(src) do
    %{size: size} = :atomics.info(src)
    dst = :atomics.new(size, signed: false)
    for i <- 1..size//1, do: :atomics.put(dst, i, :atomics.get(src, i))
    dst
  end

  # bounds check for the bulk-memory host helpers — same limit the interpreter's bounds!/3 uses, read
  # from the shared :tl_mem_pages dict (so transpiled + interpreted bulk ops trap identically).
  defp bounds_g!(addr, n) do
    limit = :atomics.get(Process.get(:tl_mem_pages), 1) * 65536
    if addr < 0 or addr + n > limit, do: trap!(:out_of_bounds)
  end

  # mutable globals as an `:atomics` array; initial values come from each global's const init expression.
  defp new_globals([]), do: nil

  defp new_globals(globals) do
    ref = :atomics.new(length(globals), signed: false)
    stub = %{mod: nil, mem: nil, globals: nil, fuel: cfuel()}

    globals
    |> Enum.with_index(1)
    |> Enum.each(fn {g, ix} ->
      {vt, init} = norm_global(g)
      {_sig, [v | _], _l} = run(init, [], {}, stub)
      # Globals are stored as raw 64-bit BITS so the integer-only :atomics can hold any valtype. f64/f32
      # globals (e.g. Porffor, which represents JS numbers as f64) reinterpret to/from bits; i32/i64 store
      # the value masked. global_get/set decode per the global's valtype (gval/gbits, via rt.gtypes).
      :atomics.put(ref, ix, gbits(v, vt))
    end)

    ref
  end

  # A global entry is `{valtype, init}` from decode; tolerate the legacy bare-init-list shape (test/build
  # helpers, pre-typed-globals) by defaulting it to i32 (127).
  defp norm_global({vt, init}) when is_integer(vt), do: {vt, init}
  defp norm_global(init) when is_list(init), do: {127, init}

  # The valtypes of a module's globals, as an O(1)-indexed tuple for the get/set hot path. (Single-table
  # global model — no imported globals; global index i ⇒ mod.globals[i].)
  def global_types(mod), do: mod.globals |> Enum.map(fn g -> elem(norm_global(g), 0) end) |> List.to_tuple()

  # value ⇄ 64-bit storage bits per valtype (124=f64, 125=f32, 126=i64, 127=i32). i32 keeps the prior
  # 32-bit masking; i64 was latently truncated by the old `&&& @mask32` global_set — now full-width.
  # Public: the asm lane (TinyLasers.Wasm.AsmOps.IntExt) calls these for f64/f32 globals so atomics holds the
  # i64 BITS (atomics can't store a float, and a `band` mask on a float crashes) — bit-identical to interp.
  def gbits(v, 124), do: reinterpret_to_i(v, 64)
  def gbits(v, 125), do: reinterpret_to_i(v, 32) &&& @mask32
  def gbits(v, 126), do: v &&& @mask64
  def gbits(v, _), do: v &&& @mask32

  def gval(bits, 124), do: decode_f(bits, 64)
  def gval(bits, 125), do: decode_f(bits &&& @mask32, 32)
  def gval(bits, _), do: bits

  # Build the function table (idx => global func index) from active element segments — for call_indirect.
  defp new_table([], _globals), do: %{}

  # Current logical table size: the runtime counter (after grows) or the module's declared min.
  defp table_size(rt), do: Process.get(:tl_table_size) || table_min(rt)
  defp table_min(rt), do: (case rt.mod.table_type do {min, _} -> min; _ -> 0 end)
  # An ascending index range [lo, hi) that's empty when hi <= lo (//1 step avoids a descending range).
  defp grow_range(lo, hi), do: lo..(hi - 1)//1

  # ── exception-handling helpers (exnref) ──
  # A tag's value arity = the param count of its declared function type.
  defp tag_arity(rt, tagidx) do
    typeidx = Enum.at(rt.mod.tags, tagidx)
    {params, _results} = Enum.at(rt.mod.types, typeidx)
    length(params)
  end

  # The first catch clause that matches `tag` (catch_all/catch_all_ref match any), or nil.
  # first legacy clause matching the thrown tag (catch_all matches anything).
  defp match_legacy(clauses, tag) do
    Enum.find(clauses, fn
      {:catch, t, _c} -> t == tag
      {:catch_all, _c} -> true
    end)
  end

  defp match_catch(catches, tag) do
    Enum.find(catches, fn
      {:catch, t, _l} -> t == tag
      {:catch_ref, t, _l} -> t == tag
      {:catch_all, _l} -> true
      {:catch_all_ref, _l} -> true
    end)
  end

  # Push the caught values (+ optional exnref) onto the try_table's entry stack, then branch to the
  # clause's label (relative to the try_table frame: label 0 = exit the try_table).
  defp handle_catch(clause, tag, vals, stack, l) do
    pushed =
      case clause do
        {:catch, _t, _label} -> Enum.reverse(vals) ++ stack
        {:catch_ref, _t, _label} -> [{:exnref, tag, vals} | Enum.reverse(vals) ++ stack]
        {:catch_all, _label} -> stack
        {:catch_all_ref, _label} -> [{:exnref, tag, vals} | stack]
      end

    label = elem(clause, tuple_size(clause) - 1)
    if label == 0, do: {:next, pushed, l}, else: {:br, label - 1, pushed, l}
  end

  defp new_table(elements, globals) do
    stub = %{mod: nil, mem: nil, globals: globals, table: %{}, fuel: cfuel()}

    Enum.reduce(elements, %{}, fn {offset, funcs}, acc ->
      {_sig, [base | _], _l} = run(offset, [], {}, stub)
      funcs |> Enum.with_index() |> Enum.reduce(acc, fn {f, i}, a -> Map.put(a, base + i, f) end)
    end)
  end

  # Copy each ACTIVE data segment's bytes into linear memory at its (const-expr) offset.
  defp init_data(_globals, []), do: :ok

  defp init_data(globals, data) do
    stub = %{mod: nil, mem: nil, globals: globals, fuel: cfuel()}

    Enum.each(data, fn
      {:passive, _bytes} ->
        :ok

      {:active, offset_expr, bytes} ->
        {_sig, [addr | _], _l} = run(offset_expr, [], {}, stub)
        bytes |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> store(wmem(), addr + i, b, 1) end)
    end)
  end

  # The function index space: imports occupy [0, n_imports); local funcs follow. Dispatch a global index.
  defp call_fn(rt, fidx, args) do
    ni = length(rt.mod.imports)
    if fidx < ni,
      do: call_host(rt, Enum.at(rt.mod.imports, fidx), args),
      else: invoke(rt, fidx - ni, args)
  end

  # Invoke LOCAL function `local_idx`. Lazy tiered dispatch when enabled: a function already compiled to
  # native BEAM runs there (same shared mem/globals/fuel ⇒ identical, oracle-verified); a hot-but-cold
  # function (call count crossed the threshold) gets compiled ON DEMAND; everything else interprets.
  defp invoke(rt, local_idx, args) do
    case Map.get(rt, :lazy) do
      {counts, threshold, async?} -> lazy_invoke(rt, local_idx, args, counts, threshold, async?)
      # `cps: true` selects the REIFIED-stack interpreter (`interp_invoke_cps`/`tramp`) — the
      # fork-safe lane (wb-nsrp): a tail-recursive trampoline whose only stack is an explicit
      # frames list, so a continuation can be snapshotted/resumed (return-twice `proc_fork`).
      # Proven bit-identical to `interp_invoke` by the differential oracle before fork rides it.
      _ -> if Map.get(rt, :cps), do: interp_invoke_cps(rt, local_idx, args), else: interp_invoke(rt, local_idx, args)
    end
  end

  defp lazy_invoke(rt, local_idx, args, counts, threshold, async?) do
    gfidx = local_idx + rt.ni

    # DIFFTRACE SEAM (TinyLasers.Wasm.DiffTrace): when an allow-set is installed, ONLY those gfidxs may reach
    # the asm lane — everything else interprets. Lets a differential harness binary-search WHICH asm
    # function makes a transpiled run diverge from the (oracle) interpreter. nil in normal operation (one
    # process-dict read; never an allow-set in production).
    case Process.get(:tl_jit_only) do
      nil -> lazy_invoke_dispatch(rt, local_idx, args, counts, threshold, async?, gfidx)
      allow -> if MapSet.member?(allow, gfidx),
                 do: lazy_invoke_dispatch(rt, local_idx, args, counts, threshold, async?, gfidx),
                 else: interp_invoke(rt, local_idx, args)
    end
  end

  defp lazy_invoke_dispatch(rt, local_idx, args, counts, threshold, async?, gfidx) do
    jit = Process.get(:tl_jit, %{})

    case Map.get(jit, gfidx) do
      {m, f, _ar, tok} ->
        # The per-process `:tl_jit` fast path pins the ModulePool generation token the MFA was compiled
        # under. The global pool may recycle slot `m` for ANOTHER guest mid-run (soft_purge succeeds while
        # we're between calls), reloading the same atom with a DIFFERENT chunk — still `module_loaded`, but
        # `wf_<gfidx>` now points at the wrong function (silent corruption) or is absent (undefined). A
        # token mismatch means recycled: drop the stale entry and re-resolve (cached_one self-heals,
        # recompiling into a fresh slot if needed). This mirrors the validation `cached_one` already does
        # for the persistent JitCache; the fast path previously skipped it (wb-7jwh density race).
        if TinyLasers.Wasm.ModulePool.valid?(m, tok) do
          cov_tick(1)
          apply(m, f, args)
        else
          Process.put(:tl_jit, Map.delete(jit, gfidx))
          lazy_invoke(rt, local_idx, args, counts, threshold, async?)
        end

      :failed ->
        interp_invoke(rt, local_idx, args)

      :pending ->
        # ASYNC mode: a background compile is in flight. Adopt it the moment it lands (in the persistent
        # cache); until then keep interpreting — the run never stalls on the compile.
        case TinyLasers.Wasm.Transpile.cached_one(rt.mod.id, gfidx) do
          {:ok, {m, f, _} = native} ->
            Process.put(:tl_jit, Map.put(jit, gfidx, jit_pin(native)))
            cov_tick(1)
            apply(m, f, args)

          :error ->
            Process.put(:tl_jit, Map.put(jit, gfidx, :failed))
            interp_invoke(rt, local_idx, args)

          _ ->
            interp_invoke(rt, local_idx, args)
        end

      nil ->
        # Adopt a function already compiled (a prior run, or a background task this run) immediately —
        # this is how repeatedly-used modules run native from the first call. A cached :error means we
        # already decided not to compile it (unsupported op / too expensive) — don't re-attempt.
        case TinyLasers.Wasm.Transpile.cached_one(rt.mod.id, gfidx) do
          {:ok, {m, f, _} = native} ->
            Process.put(:tl_jit, Map.put(jit, gfidx, jit_pin(native)))
            cov_tick(1)
            apply(m, f, args)

          :error ->
            Process.put(:tl_jit, Map.put(jit, gfidx, :failed))
            interp_invoke(rt, local_idx, args)

          _ ->
            :counters.add(counts, local_idx + 1, 1)

            if :counters.get(counts, local_idx + 1) >= threshold do
              tier_hot(rt, local_idx, args, gfidx, jit, async?)
            else
              interp_invoke(rt, local_idx, args)
            end
        end
    end
  end

  # A function crossed the hotness threshold. ASYNC: kick off a background compile, mark :pending, keep
  # interpreting this call (no stall — the compile storm is spread across the background). SYNC: compile
  # now and dispatch native (deterministic — used by tests and where blocking is fine).
  defp tier_hot(rt, local_idx, args, gfidx, jit, true) do
    TinyLasers.Wasm.Transpile.compile_one_async(rt.mod, gfidx)
    Process.put(:tl_jit, Map.put(jit, gfidx, :pending))
    interp_invoke(rt, local_idx, args)
  end

  defp tier_hot(rt, local_idx, args, gfidx, jit, false) do
    entry =
      case TinyLasers.Wasm.Transpile.compile_one(rt.mod, gfidx) do
        {:ok, native} -> jit_pin(native)
        :error -> :failed
      end

    Process.put(:tl_jit, Map.put(jit, gfidx, entry))

    case entry do
      {m, f, _ar, _tok} -> cov_tick(1); apply(m, f, args)
      :failed -> interp_invoke(rt, local_idx, args)
    end
  end

  # Pin a freshly-resolved native MFA with the ModulePool generation token it was compiled under, so the
  # per-process `:tl_jit` dispatch can detect (via `ModulePool.valid?/2`) when the pool later recycles
  # that slot for a different guest and re-resolve instead of calling stale/wrong code (wb-7jwh).
  defp jit_pin({m, f, ar}), do: {m, f, ar, TinyLasers.Wasm.ModulePool.token(m)}

  # ASM-native coverage accounting (gated; zero-overhead when off). When :tl_cov holds a 2-slot atomics
  # ref, every dispatched call ticks slot 1 (ASM-native) or slot 2 (interp fallback) so a run can report
  # what fraction executed ASM-native vs bailed to interp — the "no silent downgrade" gate. Call-weighted at
  # the dispatch boundary; native sub-calls that stay inside compiled code aren't re-dispatched (a known
  # under-count of native, i.e. the reported ASM% is a conservative lower bound).
  @compile {:inline, cov_tick: 1}
  defp cov_tick(slot) do
    case Process.get(:tl_cov) do
      nil -> :ok
      ref -> :atomics.add(ref, slot, 1)
    end
  end

  # Gated per-seam call counter for the asm-lane perf loop. Only `call_local` (the asm→interp trampoline,
  # ~hundreds of k/run) is wired by default — it's the cheapest high-signal seam (tracks how much a run
  # bails to the interpreter). The hot per-op seams (guest_load*/guest_store*/charge_fuel) are NOT ticked
  # by default because they fire 10M+ times/run and a per-call Process.get would tax the hot path; wire
  # them temporarily when re-measuring. Zero overhead when `:tl_bench` is unset.
  @bench_slots %{call_local: 8}
  @compile {:inline, bench_tick: 1}
  defp bench_tick(slot) do
    case Process.get(:tl_bench) do
      nil -> :ok
      ref -> :counters.add(ref, slot, 1)
    end
  end

  @doc """
  Run `fun` with per-seam call counters on; returns `{result, counts_map}`. Reports how often each wired
  host seam is invoked during a transpiled run — default wires `call_local` (asm→interp trampolines).
  """
  def with_bench(fun) when is_function(fun, 0) do
    ref = :counters.new(8, [:write_concurrency])
    prev = Process.put(:tl_bench, ref)
    try do
      result = fun.()
      counts = Map.new(@bench_slots, fn {k, s} -> {k, :counters.get(ref, s)} end)
      {result, counts}
    after
      if prev, do: Process.put(:tl_bench, prev), else: Process.delete(:tl_bench)
    end
  end

  @doc "Run `fun` with ASM-native coverage accounting on; returns `{result, %{asm:, interp:, asm_pct:}}`."
  def with_coverage(fun) when is_function(fun, 0) do
    ref = :atomics.new(2, signed: false)
    prev = Process.put(:tl_cov, ref)
    try do
      result = fun.()
      asm = :atomics.get(ref, 1)
      interp = :atomics.get(ref, 2)
      total = asm + interp
      pct = if total > 0, do: Float.round(asm * 100 / total, 2), else: 0.0
      {result, %{asm: asm, interp: interp, asm_pct: pct}}
    after
      if prev, do: Process.put(:tl_cov, prev), else: Process.delete(:tl_cov)
    end
  end

  defp interp_invoke(rt, local_idx, args) do
    cov_tick(2)
    if :atomics.add_get(rt.depth, 1, 1) > rt.max_depth, do: trap!(:stack_exhausted)
    {nlocals, instrs} = Enum.at(rt.mod.code, local_idx)
    locals = (args ++ List.duplicate(0, nlocals)) |> List.to_tuple()
    # Gated throw-localization (counterpart to :tl_oob_debug): on a guest exception, print the innermost
    # function's index+name (from the `-d` name section) as the stack unwinds, then re-raise. Off by default
    # (one process-dict read per call when off). Names a Porffor `-d` build's boxed fns as `b$<hint>$<N>`.
    {_sig, stack, _l} =
      cond do
        Process.get(:tl_trace_throw) ->
          try do
            run(instrs, [], locals, rt)
          catch
            :throw, {:wasm_exc, _, _} = e ->
              gf = local_idx + length(rt.mod.imports)
              IO.puts(:stderr, "TL_THROW_FN gfidx=#{gf} #{inspect(Map.get(rt.mod.func_names || %{}, gf))}")
              :erlang.throw(e)
          end

        # Gated TRAP-localization: print the innermost function index+name as a TinyLasers.Wasm.Trap
        # (out_of_bounds etc.) unwinds, then re-raise. Mirrors :tl_trace_throw for non-catchable traps.
        Process.get(:tl_trap_trace) ->
          try do
            run(instrs, [], locals, rt)
          rescue
            e in TinyLasers.Wasm.Trap ->
              gf = local_idx + length(rt.mod.imports)
              IO.puts(:stderr, "TL_TRAP_FN gfidx=#{gf} #{inspect(Map.get(rt.mod.func_names || %{}, gf))} reason=#{inspect(e.reason)}")
              reraise(e, __STACKTRACE__)
          end

        true ->
          run(instrs, [], locals, rt)
      end
    :atomics.sub(rt.depth, 1, 1)

    # Return shape by RESULT ARITY: void→nil, single→the bare value, MULTI→the top-N values as a list
    # (top-ordered, [resN-1..res0]). Porffor tags every value with its type, so most functions return
    # [value, type] pairs — the single-value `[top|_]` form silently dropped the second result, underflowing
    # the caller's stack. The asm lane bails to interp on multi-result, so only this path needs the list.
    case func_result_arity(rt.mod, local_idx + length(rt.mod.imports)) do
      0 -> nil
      1 -> case stack do [top | _] -> top; [] -> nil end
      n -> Enum.take(stack, n)
    end
  end

  # HOST IMPORTS = pure Elixir functions (this is the host-mediation seam — caps/tenant/Membrane live here).
  # WASI `fd_write(fd, iovs, iovs_len, nwritten_ptr)`: gather the iovec byte ranges from memory, capture
  # writes to stdout/stderr, store the byte count, return errno 0.
  defp call_host(rt, {_m, "fd_write", _t}, [fd, iovs, iovs_len, nwritten]) do
    data = gather_iovs(wmem(), iovs, iovs_len)
    cond do
      fd in [1, 2] -> Process.put(:tl_out, [data | Process.get(:tl_out, [])])
      true ->
        case TinyLasers.Wasm.FdTable.get(fd) do
          %{kind: :pipe, ref: {pid, _}} -> TinyLasers.Wasm.FdTable.Pipe.write(pid, data)
          # POSIX write() on a socket fd is sock_send: native code uses write()/read() interchangeably
          # with send()/recv() on a connected socket. Route through HostSock so the bytes hit the
          # :gen_tcp transport (an echo server reads with read(), writes with write()).
          %{kind: :socket} -> TinyLasers.Wasm.HostSock.fd_send(wmem(), fd, data)
          _ -> file_write(fd, data)
        end
    end

    store(wmem(), nwritten, byte_size(data), 4)
    0
  end

  defp call_host(_rt, {_m, "proc_exit", _t}, [code]), do: throw({:tl_exit, code})

  # ── WASIX `wasix_32v1` host imports ── native unix binaries (wasix-libc / target_family=unix) call these
  # directly instead of the wasm `memory.atomic.*` instructions. They route to the SAME §2 futex / §6 signal
  # machinery the instruction lane uses (DRY) — proven by running a real wasix-libc-compiled binary (§8).

  # proc_exit2(code) — WASIX exit (the '2' variant carries the code; same effect as proc_exit).
  defp call_host(_rt, {_m, "proc_exit2", _t}, [code | _]), do: throw({:tl_exit, code})

  # callback_signal(name_ptr, name_len) — wasi-libc registers the export name of its signal-dispatch
  # trampoline so a delivered signal can re-enter the guest there (async invocation = wb-rgkq). Stash; void.
  defp call_host(_rt, {_m, "callback_signal", _t}, [name_ptr, name_len]) do
    Process.put(:tl_signal_callback, read_bytes(wmem(), name_ptr, name_len))
    0
  end

  # futex_wait(futex_ptr, expected, timeout_ptr, ret_woken_ptr) — WASIX futex over a 32-bit word; mirrors
  # memory.atomic.wait. timeout_ptr → OptionTimestamp (tag 0 = none/infinite). Writes woken-bool; errno 0.
  defp call_host(_rt, {_m, "futex_wait", _t}, [futex_ptr, expected, timeout_ptr, ret_ptr]) do
    rc = guest_atomic_wait(futex_ptr, expected, 4, read_option_timestamp(timeout_ptr))
    store(wmem(), ret_ptr, if(rc == 0, do: 1, else: 0), 1)
    0
  end

  # futex_wake(futex_ptr, ret_woken_ptr) — wake ONE waiter; writes whether one was woken; errno 0.
  defp call_host(_rt, {_m, "futex_wake", _t}, [futex_ptr, ret_ptr]) do
    store(wmem(), ret_ptr, if(guest_atomic_notify(futex_ptr, 1) > 0, do: 1, else: 0), 1)
    0
  end

  # futex_wake_all(futex_ptr, ret_woken_ptr) — wake ALL waiters; writes whether any were woken; errno 0.
  defp call_host(_rt, {_m, "futex_wake_all", _t}, [futex_ptr, ret_ptr]) do
    store(wmem(), ret_ptr, if(guest_atomic_notify(futex_ptr, 0xFFFFFFFF) > 0, do: 1, else: 0), 1)
    0
  end

  # thread_signal(tid, sig) — deliver a signal to thread `tid` (best-effort over the §6 process model). 0.
  defp call_host(_rt, {_m, "thread_signal", _t}, [_tid, _sig]), do: 0

  # proc_signals_sizes_get(ret_ptr) — number of signal dispositions wasi-libc should sync. A fresh process
  # has none non-default ⇒ write 0; libc then skips proc_signals_get. errno 0.
  defp call_host(_rt, {_m, "proc_signals_sizes_get", _t}, [ret_ptr]) do
    store(wmem(), ret_ptr, 0, 4)
    0
  end

  # proc_signals_get(buf_ptr) — write the disposition array (empty for a fresh process). errno 0.
  defp call_host(_rt, {_m, "proc_signals_get", _t}, [_buf_ptr]), do: 0

  # getcwd(buf_ptr, size_ptr) — WASIX: size_ptr is in/out (caller capacity → callee actual). The guest cwd
  # is the preopen root "/"; write it (truncated to capacity) + its length. errno 0.
  defp call_host(_rt, {_m, "getcwd", _t}, [buf_ptr, size_ptr]) do
    cwd = "/"
    cap = load(wmem(), size_ptr, 4)
    n = min(byte_size(cwd), max(cap, 0))
    if n > 0, do: write_bytes(wmem(), buf_ptr, binary_part(cwd, 0, n))
    store(wmem(), size_ptr, byte_size(cwd), 4)
    0
  end

  # path_open2(dirfd, dirflags, path_ptr, path_len, oflags, rights_base:i64, rights_inheriting:i64,
  # fdflags, fdflags_ext, ret_fd_ptr) — the WASIX 10-arg path_open; same semantics, extra fdflags_ext
  # ignored. Delegates to the shared resolver (symlink-follow + create/trunc/append).
  defp call_host(_rt, {_m, "path_open2", _t},
         [_dirfd, df, path_ptr, path_len, oflags, _rb, _ri, ff, _ffext, ofd_ptr]) do
    raw = read_bytes(wmem(), path_ptr, path_len)
    follow = (df &&& 1) != 0

    case if(follow, do: resolve_symlink(raw, 8), else: {:ok, raw}) do
      {:error, :loop} -> 32
      {:ok, rel} -> path_open_resolved(rel, oflags, ff, ofd_ptr)
    end
  end

  # WASIX OptionTimestamp at `ptr`: tag u8 @0 (0 = None ⇒ infinite/-1), else the u64 ns timestamp @8.
  defp read_option_timestamp(ptr) do
    case load(wmem(), ptr, 1) do
      0 -> -1
      _ -> load(wmem(), ptr + 8, 8)
    end
  end

  # host_exec(cmd_ptr, cmd_len, in_ptr, in_len) — the guest asks the host to run `cmd` with `in` as
  # stdin. The host runs that program's wasm module (host_exec/3), STASHES its output + exit code, and
  # returns the output byte length (or -1 if the program isn't found). The guest then pulls the bytes
  # with host_exec_read — a pipe-friendly ABI so a shell can feed one stage's output into the next.
  defp call_host(rt, {_m, "host_exec", _t}, [cmd_ptr, cmd_len, in_ptr, in_len]) do
    argv = read_bytes(wmem(), cmd_ptr, cmd_len) |> String.split()
    stdin = read_bytes(wmem(), in_ptr, in_len)

    case argv do
      [prog | _] ->
        # an optional per-run EXEC POLICY (set by the caller) can refuse a command before it runs — the
        # generic seam connection-scope enforcement rides on: the app maps argv → a connection grant and
        # denies a blocked one (exit 126, fails closed). The runtime knows nothing about connections.
        case exec_policy_hook(argv) do
          {:deny, reason} ->
            stash_exec("#{prog}: #{reason}\n", 126)

          :ok ->
            # a HOST CAPABILITY (work/agent/request/web) mid-pipe routes to the host dispatcher (the
            # Membrane), not to a wasm program — so a cap composes inside a pipeline, not just as word #1.
            case host_dispatch_hook(argv, stdin) do
              {out, code} ->
                stash_exec(out, code)

              :not_host ->
                if resolve_program(prog) do
                  {out, code} = host_exec(argv, stdin)
                  stash_exec(out, code)
                else
                  -1
                end
            end
        end

      [] ->
        -1
    end
  end

  # an optional per-run exec policy (set by the caller): `(argv) -> :ok | {:deny, reason}`.
  defp exec_policy_hook(argv) do
    case Process.get(:tl_exec_policy) do
      f when is_function(f, 1) -> f.(argv)
      _ -> :ok
    end
  end

  defp stash_exec(out, code) do
    Process.put(:tl_exec_out, out)
    Process.put(:tl_exec_code, code)
    byte_size(out)
  end

  # an optional host-cap dispatcher (set by the agent shell): `(argv, stdin) -> {out, code} | :not_host`
  defp host_dispatch_hook(argv, stdin) do
    case Process.get(:tl_host_dispatch) do
      f when is_function(f, 2) -> f.(argv, stdin)
      _ -> :not_host
    end
  end

  # host_exec_read(buf_ptr) — copy the stashed child output into guest memory; return the child's exit
  # code. Pairs with host_exec (the guest sizes its buffer from host_exec's return, then reads).
  defp call_host(rt, {_m, "host_exec_read", _t}, [buf_ptr]) do
    write_bytes(wmem(), buf_ptr, Process.get(:tl_exec_out, ""))
    Process.get(:tl_exec_code, 0)
  end

  # host_http — the thesis's network emulation: wasm has no sockets, so a guest's HTTP call is handed to
  # the host, which performs it (TLS + egress, SSRF-guarded) and STASHES the response. Same pipe-friendly
  # ABI as host_exec: returns the response BODY length (or -1 if no transport is wired); host_http_read
  # copies the body into the guest's buffer and returns the HTTP status. The request bytes are opaque to
  # the runtime — a caller-set `:tl_http` hook interprets them (so tinylasers carries no HTTP policy).
  defp call_host(rt, {_m, "host_http", _t}, [req_ptr, req_len]) do
    req = read_bytes(wmem(), req_ptr, req_len)

    case http_hook(req) do
      {body, status} when is_binary(body) ->
        Process.put(:tl_http_out, body)
        Process.put(:tl_http_status, status)
        byte_size(body)

      _ ->
        -1
    end
  end

  defp call_host(rt, {_m, "host_http_read", _t}, [buf_ptr]) do
    write_bytes(wmem(), buf_ptr, Process.get(:tl_http_out, ""))
    Process.get(:tl_http_status, 0)
  end

  # ── Beam.* JS↔OTP interop host seam (wb-wzgu/north-star) ──────────────────────────────────────────
  # The bridge from a guest's `Beam` global (host imports) to `TinyLasers.Wasm.Actor` (the persistent
  # guest-actor mechanism). ABI: handles are STRINGS (an encoded pid), messages/args/replies are JSON
  # bytes (the Term bridge), all read/written through guest memory like host_exec. These clauses are
  # inert until `qjs-run.wasm` is rebuilt to import them + inject the `Beam` global (see
  # reference/beam/JS-OTP-INTEROP-DESIGN.md) — this is the host half, testable via `invoke_host`.

  # beam_self(buf_ptr) -> len : write this guest's handle (encoded pid string) into buf, return its length.
  defp call_host(_rt, {_m, "beam_self", _t}, [buf_ptr]) do
    h = pid_handle(TinyLasers.Wasm.Actor.beam_self())
    write_bytes(wmem(), buf_ptr, h)
    byte_size(h)
  end

  # beam_spawn(src_ptr, src_len, out_ptr) -> handle_len : spawn a JS guest actor, write its handle to out.
  defp call_host(_rt, {_m, "beam_spawn", _t}, [src_ptr, src_len, out_ptr]) do
    src = read_bytes(wmem(), src_ptr, src_len)

    case TinyLasers.Wasm.Actor.beam_spawn({:js, src}) do
      {:ok, pid} ->
        h = pid_handle(pid)
        write_bytes(wmem(), out_ptr, h)
        byte_size(h)

      _ ->
        -1
    end
  end

  # beam_send(to_ptr, to_len, msg_ptr, msg_len) -> 0 | -1 : send a JSON message to the target handle.
  defp call_host(_rt, {_m, "beam_send", _t}, [to_ptr, to_len, msg_ptr, msg_len]) do
    to = read_bytes(wmem(), to_ptr, to_len)
    msg = TinyLasers.Wasm.Actor.Term.from_json(read_bytes(wmem(), msg_ptr, msg_len))

    case handle_pid(to) do
      nil -> -1
      pid -> if TinyLasers.Wasm.Actor.beam_send(pid, msg) == :ok, do: 0, else: -1
    end
  end

  # beam_call(name_ptr, name_len, args_ptr, args_len, out_ptr) -> reply_len : sync call to an Elixir
  # handler, write the JSON reply into out.
  defp call_host(_rt, {_m, "beam_call", _t}, [name_ptr, name_len, args_ptr, args_len, out_ptr]) do
    name = read_bytes(wmem(), name_ptr, name_len)
    args = TinyLasers.Wasm.Actor.Term.from_json(read_bytes(wmem(), args_ptr, args_len))
    args = if is_list(args), do: args, else: [args]

    reply =
      case TinyLasers.Wasm.Actor.beam_call(name, args) do
        {:ok, r} -> r
        {:error, e} -> %{"error" => inspect(e)}
        r -> r
      end

    json = TinyLasers.Wasm.Actor.Term.to_json(reply)
    write_bytes(wmem(), out_ptr, json)
    byte_size(json)
  end

  # beam_recv(out_ptr) -> len : write the message the Actor stashed for this re-entry (JSON) into out.
  defp call_host(_rt, {_m, "beam_recv", _t}, [out_ptr]) do
    json = Process.get(:tl_beam_inbox, "null")
    write_bytes(wmem(), out_ptr, json)
    byte_size(json)
  end

  # beam_link(to_ptr, to_len) -> 0 | -1 : monitor a peer (handle/name) from the calling actor.
  defp call_host(_rt, {_m, "beam_link", _t}, [to_ptr, to_len]) do
    to = read_bytes(wmem(), to_ptr, to_len)
    target = handle_pid(to) || to
    if TinyLasers.Wasm.Actor.beam_link(target) == :ok, do: 0, else: -1
  end

  # beam_process_info(to_ptr, to_len, out_ptr) -> len : JSON of {reductions,memory,message_queue_len}.
  # An empty target (len 0) means "this actor".
  defp call_host(_rt, {_m, "beam_process_info", _t}, [to_ptr, to_len, out_ptr]) do
    target = if to_len > 0, do: (read_bytes(wmem(), to_ptr, to_len) |> then(&(handle_pid(&1) || &1))), else: nil
    json = TinyLasers.Wasm.Actor.process_info(target) |> TinyLasers.Wasm.Actor.Term.to_json()
    write_bytes(wmem(), out_ptr, json)
    byte_size(json)
  end

  # beam_system_info(out_ptr) -> len : JSON of VM-wide counters (process_count, atom_count, run_queue, …).
  defp call_host(_rt, {_m, "beam_system_info", _t}, [out_ptr]) do
    json = TinyLasers.Wasm.Actor.system_info() |> TinyLasers.Wasm.Actor.Term.to_json()
    write_bytes(wmem(), out_ptr, json)
    byte_size(json)
  end

  # timer_set(id, ms) -> 0 : arm a BEAM timer on the owning actor; on fire it re-enters wb_timer(id).
  defp call_host(_rt, {_m, "timer_set", _t}, [id, ms]) do
    TinyLasers.Wasm.Actor.timer_set(id, ms)
    0
  end

  # timer_clear(id) -> 0 : cancel a pending timer on the owning actor.
  defp call_host(_rt, {_m, "timer_clear", _t}, [id]) do
    TinyLasers.Wasm.Actor.timer_clear(id)
    0
  end

  # io_recv(out_ptr) -> len : write the {id,ok,value} completion envelope the actor stashed for this
  # wb_complete re-entry (JSON) into guest memory. Mirrors beam_recv; the generic async-completion read.
  defp call_host(_rt, {_m, "io_recv", _t}, [out_ptr]) do
    json = Process.get(:tl_io_inbox, "null")
    write_bytes(wmem(), out_ptr, json)
    byte_size(json)
  end

  # handles ARE encoded pids (stable, registry-free). Guard list_to_pid against a bogus guest string.
  defp pid_handle(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> to_string()
  defp pid_handle(other), do: to_string(other)

  defp handle_pid(h) do
    :erlang.list_to_pid(to_charlist(h))
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # an optional host HTTP transport (set by the caller): `(request_bytes) -> {body, status} | :none`.
  defp http_hook(req) do
    case Process.get(:tl_http) do
      f when is_function(f, 1) -> f.(req)
      _ -> :none
    end
  end

  # ── host-brokered TCP (Layer 2) — wasm32-wasip1 has no sockets, so a guest's connect/send/recv is
  # performed by the host (real sockets, SSRF-guarded) and the bytes shuttle across the membrane. This
  # is the general path for raw std::net / socket-aware tokio that Layer 1's HTTP shim doesn't cover.
  # Generic: a caller-set `:tl_sock` hook owns the transport; tinylasers only maps a guest fd → its ref.
  defp call_host(rt, {_m, "host_tcp_connect", _t}, [host_ptr, host_len, port]) do
    host = read_bytes(wmem(), host_ptr, host_len)

    case sock_hook({:connect, host, port}) do
      {:ok, ref} ->
        # a socket is just another fd in the unified table (kind: :socket, ref = the transport ref).
        TinyLasers.Wasm.FdTable.alloc(%{kind: :socket, ref: ref})

      _ ->
        -1
    end
  end

  defp call_host(rt, {_m, "host_tcp_send", _t}, [fd, buf_ptr, len]) do
    case sock_ref(fd) do
      nil ->
        -1

      ref ->
        case sock_hook({:send, ref, read_bytes(wmem(), buf_ptr, len)}) do
          n when is_integer(n) -> n
          _ -> -1
        end
    end
  end

  defp call_host(rt, {_m, "host_tcp_recv", _t}, [fd, buf_ptr, cap]) do
    case sock_ref(fd) do
      nil ->
        -1

      ref ->
        case sock_hook({:recv, ref, cap}) do
          {:data, bin} ->
            bin = binary_part(bin, 0, min(byte_size(bin), cap))
            write_bytes(wmem(), buf_ptr, bin)
            byte_size(bin)

          :eof ->
            0

          _ ->
            -1
        end
    end
  end

  defp call_host(rt, {_m, "host_tcp_close", _t}, [fd]) do
    case sock_ref(fd) do
      nil ->
        -1

      _ref ->
        # FdTable.close runs the transport teardown ({:close, ref} via :tl_sock) on the last ref.
        TinyLasers.Wasm.FdTable.close(fd)
        0
    end
  end

  # ── WASIX §3 BSD-socket ABI (wb-j9op) — thin clauses: parse args, delegate to HostSock ──────────
  # Socket state lives in HostSock's :tl_sockstate map (transport ports shared across dup'd fds),
  # the fd lives in the unified FdTable (kind: :socket, ref = state id). See TinyLasers.Wasm.HostSock.
  defp call_host(_rt, {_m, "sock_open", _t}, [af, socktype, protocol, fd_out]),
    do: TinyLasers.Wasm.HostSock.open(wmem(), af, socktype, protocol, fd_out)

  defp call_host(_rt, {_m, "sock_bind", _t}, [fd, addr_ptr]),
    do: TinyLasers.Wasm.HostSock.bind(wmem(), fd, addr_ptr)

  defp call_host(_rt, {_m, "sock_listen", _t}, [fd, backlog]),
    do: TinyLasers.Wasm.HostSock.listen(wmem(), fd, backlog)

  defp call_host(_rt, {_m, "sock_accept", _t}, [fd, fd_flags, ro_fd, ro_addr]),
    do: TinyLasers.Wasm.HostSock.accept(wmem(), fd, fd_flags, ro_fd, ro_addr)

  # sock_accept_v2 — wasix-libc's `accept()` lowers to this (NOT sock_accept). Same 4-arg shape:
  # (fd, flags, retptr0=new-fd, retptr1=__wasi_addr_port_t peer). Alias to the one impl.
  defp call_host(_rt, {_m, "sock_accept_v2", _t}, [fd, fd_flags, ro_fd, ro_addr]),
    do: TinyLasers.Wasm.HostSock.accept(wmem(), fd, fd_flags, ro_fd, ro_addr)

  defp call_host(_rt, {_m, "sock_connect", _t}, [fd, addr_ptr]),
    do: TinyLasers.Wasm.HostSock.connect(wmem(), fd, addr_ptr)

  defp call_host(_rt, {_m, "sock_send", _t}, [fd, si_ptr, si_len, si_flags, ro_len]),
    do: TinyLasers.Wasm.HostSock.send(wmem(), fd, si_ptr, si_len, si_flags, ro_len)

  defp call_host(_rt, {_m, "sock_recv", _t}, [fd, ri_ptr, ri_len, ri_flags, ro_len, ro_flags]),
    do: TinyLasers.Wasm.HostSock.recv(wmem(), fd, ri_ptr, ri_len, ri_flags, ro_len, ro_flags)

  defp call_host(_rt, {_m, "sock_shutdown", _t}, [fd, how]),
    do: TinyLasers.Wasm.HostSock.shutdown(wmem(), fd, how)

  defp call_host(_rt, {_m, "sock_addr_local", _t}, [fd, ro_addr]),
    do: TinyLasers.Wasm.HostSock.addr_local(wmem(), fd, ro_addr)

  defp call_host(_rt, {_m, "sock_addr_remote", _t}, [fd, ro_addr]),
    do: TinyLasers.Wasm.HostSock.addr_remote(wmem(), fd, ro_addr)

  defp call_host(_rt, {_m, "sock_addr_resolve", _t}, [hp, hl, port, ro_addrs, naddrs, ro_naddrs]),
    do: TinyLasers.Wasm.HostSock.addr_resolve(wmem(), hp, hl, port, ro_addrs, naddrs, ro_naddrs)

  # ── socket options (wb-rqej) — Rust std::net sets/reads these (C didn't); surfaced by the rust_net
  # conformance fixture. Our gen_tcp transport already does the behaviourally-important bits (reuseaddr),
  # so we faithfully RECORD flag/size/time options per {fd,opt} and echo them on get — the guest sees a
  # consistent set/get round-trip — without changing transport behaviour. opt ids are the wasix
  # __wasi_sock_option_t enum; treated uniformly (store-and-echo) which satisfies std::net.
  defp call_host(_rt, {_m, "sock_set_opt_flag", _t}, [fd, opt, flag]) do
    Process.put(:tl_sockopts, Map.put(Process.get(:tl_sockopts, %{}), {fd, opt, :flag}, flag &&& 1))
    0
  end

  defp call_host(_rt, {_m, "sock_get_opt_flag", _t}, [fd, opt, ret_ptr]) do
    store(wmem(), ret_ptr, Map.get(Process.get(:tl_sockopts, %{}), {fd, opt, :flag}, 0), 1)
    0
  end

  defp call_host(_rt, {_m, "sock_set_opt_size", _t}, [fd, opt, size]) do
    Process.put(:tl_sockopts, Map.put(Process.get(:tl_sockopts, %{}), {fd, opt, :size}, size))
    0
  end

  defp call_host(_rt, {_m, "sock_get_opt_size", _t}, [fd, opt, ret_ptr]) do
    store(wmem(), ret_ptr, Map.get(Process.get(:tl_sockopts, %{}), {fd, opt, :size}, 0), 8)
    0
  end

  # opt_time is a tagged __wasi_option_timestamp_t: tag u8 @0 (0=None/no-timeout, 1=Some), u64 @8.
  defp call_host(_rt, {_m, "sock_set_opt_time", _t}, [fd, opt, time_ptr]) do
    tag = load(wmem(), time_ptr, 1)
    val = if tag == 0, do: :none, else: load(wmem(), time_ptr + 8, 8)
    Process.put(:tl_sockopts, Map.put(Process.get(:tl_sockopts, %{}), {fd, opt, :time}, val))
    0
  end

  defp call_host(_rt, {_m, "sock_get_opt_time", _t}, [fd, opt, ret_ptr]) do
    case Map.get(Process.get(:tl_sockopts, %{}), {fd, opt, :time}, :none) do
      :none -> store(wmem(), ret_ptr, 0, 1)
      v -> (store(wmem(), ret_ptr, 1, 1); store(wmem(), ret_ptr + 8, v, 8))
    end
    0
  end

  # ── WASIX §6 process model (wb-yq11) — thin delegations to TinyLasers.Wasm.HostProc ─────────────────
  # proc_spawn: async subprocess (monitored BEAM worker → host_exec) → pid; returns immediately.
  defp call_host(_rt, {_m, "proc_spawn", _t},
         [n_ptr, n_len, a_ptr, a_len, e_ptr, e_len, in_fd, out_fd, err_fd, ret_pid]),
       do: TinyLasers.Wasm.HostProc.spawn(wmem(), n_ptr, n_len, a_ptr, a_len, e_ptr, e_len, in_fd, out_fd, err_fd, ret_pid)

  # proc_exec: replace-image emulation — run the new image then exit the caller (never returns on ok).
  defp call_host(_rt, {_m, "proc_exec", _t}, [n_ptr, n_len, a_ptr, a_len, e_ptr, e_len, in_fd]),
    do: TinyLasers.Wasm.HostProc.exec(wmem(), n_ptr, n_len, a_ptr, a_len, e_ptr, e_len, in_fd)

  # proc_fork(copy_memory, ret_pid_ptr) — WASIX is a 2-arg call (the wasi-libc fork wrapper passes a
  # copy-memory flag + the pid out-ptr). True return-twice fork needs to resume the CHILD at the fork
  # call site with rc 0, i.e. capture the guest continuation — only possible with asyncify (the guest
  # compiled with stack_checkpoint/restore; this guest has none) or host wasm-stack capture (impossible
  # on the BEAM). So for a NON-asyncified guest we return ENOSYS(52): fork() yields -1 and well-written
  # programs fall back gracefully (fork-or-fail) instead of crashing. True fork = wb-nsrp (asyncify path).
  defp call_host(_rt, {_m, "proc_fork", _t}, [_copy_mem, _ret_pid]), do: 52
  defp call_host(_rt, {_m, "proc_fork", _t}, [ret_pid]),
    do: TinyLasers.Wasm.HostProc.fork(wmem(), ret_pid)

  # proc_join / wait: BOUNDED block until the child is terminal; writes the POSIX wait-status.
  defp call_host(_rt, {_m, "proc_join", _t}, [pid_ptr, flags, ret_status]),
    do: TinyLasers.Wasm.HostProc.join(wmem(), pid_ptr, flags, ret_status)

  # proc_raise(sig): signal the current process (self).
  defp call_host(_rt, {_m, "proc_raise", _t}, [sig]),
    do: TinyLasers.Wasm.HostProc.raise_self(sig)

  # proc_signal(pid, sig): deliver a signal to a target child (default actions / EINTR / handler-pending).
  defp call_host(_rt, {_m, "proc_signal", _t}, [pid, sig]),
    do: TinyLasers.Wasm.HostProc.signal(pid, sig)

  # sigaction(sig, act, oldact): register/replace a handler on the current process.
  defp call_host(_rt, {_m, "sigaction", _t}, [sig, act_ptr, oldact_ptr]),
    do: TinyLasers.Wasm.HostProc.sigaction(wmem(), sig, act_ptr, oldact_ptr)

  # sigpending(set): the bitmask of signals raised but not yet acted on (current process).
  defp call_host(_rt, {_m, "sigpending", _t}, [set_ptr]),
    do: TinyLasers.Wasm.HostProc.sigpending(wmem(), set_ptr)

  # the transport ref behind a socket fd in the unified table (nil if fd isn't an open socket).
  defp sock_ref(fd) do
    case TinyLasers.Wasm.FdTable.get(fd) do
      %{kind: :socket, ref: ref} -> ref
      _ -> nil
    end
  end

  # an optional host TCP transport (set by the caller): `(op) -> result` where op is
  # `{:connect, host, port}` → `{:ok, ref} | {:error, _}`, `{:send, ref, data}` → bytes_sent,
  # `{:recv, ref, max}` → `{:data, bin} | :eof | {:error, _}`, `{:close, ref}` → :ok.
  defp sock_hook(op) do
    case Process.get(:tl_sock) do
      f when is_function(f, 1) -> f.(op)
      _ -> {:error, :no_transport}
    end
  end

  # WASI args (argv): argc < 2 so the shell reads its command line from stdin.
  defp call_host(rt, {_m, "args_sizes_get", _t}, [argc_ptr, bufsize_ptr]) do
    argv = Process.get(:tl_argv, ["sh"])
    store(wmem(), argc_ptr, length(argv), 4)
    store(wmem(), bufsize_ptr, Enum.reduce(argv, 0, fn a, acc -> acc + byte_size(a) + 1 end), 4)
    0
  end

  defp call_host(rt, {_m, "args_get", _t}, [argv_ptr, buf_ptr]) do
    Process.get(:tl_argv, ["sh"])
    |> Enum.reduce({argv_ptr, buf_ptr}, fn a, {pp, bp} ->
      store(wmem(), pp, bp, 4)
      write_bytes(wmem(), bp, a)
      store(wmem(), bp + byte_size(a), 0, 1)
      {pp + 4, bp + byte_size(a) + 1}
    end)

    0
  end

  # WASI read: fd 0 = stdin (command line); a file fd = the virtual filesystem; else EOF.
  defp call_host(rt, {_m, "fd_read", _t}, [fd, iovs, iovs_len, nread_ptr]) do
    cap = iov_capacity(wmem(), iovs, iovs_len)

    data =
      cond do
        fd == 0 -> stdin_take(cap)
        match?(%{kind: :pipe}, TinyLasers.Wasm.FdTable.get(fd)) ->
          %{ref: {pid, _}} = TinyLasers.Wasm.FdTable.get(fd)
          TinyLasers.Wasm.FdTable.Pipe.read(pid, cap)
        # POSIX read() on a socket fd is sock_recv (see fd_write). Drain the transport (bounded);
        # EOF/closed → "" (read() returns 0). Honors the socket's nonblock flag.
        match?(%{kind: :socket}, TinyLasers.Wasm.FdTable.get(fd)) ->
          TinyLasers.Wasm.HostSock.fd_recv(fd, cap)
        true -> file_read(fd, cap)
      end

    store(wmem(), nread_ptr, scatter_iovs(wmem(), iovs, iovs_len, data), 4)
    0
  end

  # WASIX §4 TTY/termios. `__wasi_tty_t` struct layout (canonical, ~24 bytes with tail padding):
  #   cols u32 @0 · rows u32 @4 · width(px) u32 @8 · height(px) u32 @12 ·
  #   stdin_tty u8 @16 · stdout_tty u8 @17 · stderr_tty u8 @18 ·
  #   echo u8 @19 · line_buffered u8 @20 · line_feeds u8 @21.
  # crossterm/ratatui on WASIX route window size through tty_get (cols/rows), not a raw
  # TIOCGWINSZ ioctl — there is no ioctl host import, so the tty_get path covers it.
  # State is owned by TinyLasers.Wasm.Tty (the one home); these clauses are thin (de)serializers.
  defp call_host(_rt, {_m, "tty_get", _t}, [ptr]) do
    s = TinyLasers.Wasm.Tty.get()
    store(wmem(), ptr + 0, s.cols, 4)
    store(wmem(), ptr + 4, s.rows, 4)
    store(wmem(), ptr + 8, s.width_px, 4)
    store(wmem(), ptr + 12, s.height_px, 4)
    store(wmem(), ptr + 16, b(s.stdin_tty), 1)
    store(wmem(), ptr + 17, b(s.stdout_tty), 1)
    store(wmem(), ptr + 18, b(s.stderr_tty), 1)
    store(wmem(), ptr + 19, b(s.echo), 1)
    store(wmem(), ptr + 20, b(s.line_buffered), 1)
    store(wmem(), ptr + 21, b(s.line_feeds), 1)
    0
  end

  defp call_host(_rt, {_m, "tty_set", _t}, [ptr]) do
    echo = load(wmem(), ptr + 19, 1) != 0
    line_buffered = load(wmem(), ptr + 20, 1) != 0
    # raw (cbreak) mode is the absence of both echo and line buffering.
    TinyLasers.Wasm.Tty.put(%{
      cols: load(wmem(), ptr + 0, 4),
      rows: load(wmem(), ptr + 4, 4),
      width_px: load(wmem(), ptr + 8, 4),
      height_px: load(wmem(), ptr + 12, 4),
      stdin_tty: load(wmem(), ptr + 16, 1) != 0,
      stdout_tty: load(wmem(), ptr + 17, 1) != 0,
      stderr_tty: load(wmem(), ptr + 18, 1) != 0,
      echo: echo,
      line_buffered: line_buffered,
      line_feeds: load(wmem(), ptr + 21, 1) != 0,
      raw: not echo and not line_buffered
    })

    0
  end

  # fd metadata: a file fd is a regular file (4); stdin/out/err are character devices (2).
  defp call_host(rt, {_m, "fd_fdstat_get", _t}, [fd, ptr]) do
    # fs_filetype: 3 = directory, 4 = regular file, 2 = character device (stdio). Grant full rights so a
    # tool checks out readdir/read/write on whatever it opened.
    # A stdio fd with a tty attached (Tty.isatty?/1) is unambiguously a character device (2).
    ft =
      cond do
        TinyLasers.Wasm.Tty.isatty?(fd) -> 2
        true ->
          case TinyLasers.Wasm.FdTable.get(fd) do
            %{kind: :dir} -> 3
            nil -> 2
            _ -> 4
          end
      end

    # fs_flags (offset 2, u16) reflects the fd's fdflags (O_NONBLOCK/APPEND/…) from the table.
    store(wmem(), ptr, ft, 1)
    store(wmem(), ptr + 2, TinyLasers.Wasm.FdTable.get_flags(fd), 2)
    store(wmem(), ptr + 8, @mask64, 8)
    store(wmem(), ptr + 16, @mask64, 8)
    0
  end

  # ONE preopened dir at fd 3 = the virtual /work, so the shell resolves /work/<path> against it.
  defp call_host(rt, {_m, "fd_prestat_get", _t}, [3, ptr]) do
    store(wmem(), ptr, 0, 1)
    store(wmem(), ptr + 4, byte_size(preopen_name()), 4)
    0
  end

  defp call_host(_rt, {_m, "fd_prestat_get", _t}, [_fd, _ptr]), do: 8

  defp call_host(rt, {_m, "fd_prestat_dir_name", _t}, [3, ptr, len]) do
    name = preopen_name()
    write_bytes(wmem(), ptr, binary_part(name, 0, min(len, byte_size(name))))
    0
  end

  defp call_host(_rt, {_m, "fd_prestat_dir_name", _t}, _args), do: 8

  # open a path (relative to the /work preopen) in the virtual FS — create/truncate per oflags.
  # `df` carries the lookupflags: bit0 (LOOKUP_SYMLINK_FOLLOW=1) means resolve symlinks to their target
  # before opening (the common case). When set we walk the symlink chain (bounded, ELOOP-safe) so opening
  # a link reads the real file. With the bit clear we open the link path verbatim.
  defp call_host(rt, {_m, "path_open", _t}, [_dirfd, df, path_ptr, path_len, oflags, _rb, _ri, ff, ofd_ptr]) do
    raw = read_bytes(wmem(), path_ptr, path_len)
    follow = (df &&& 1) != 0

    case if(follow, do: resolve_symlink(raw, 8), else: {:ok, raw}) do
      {:error, :loop} -> 32
      {:ok, rel} -> path_open_resolved(rel, oflags, ff, ofd_ptr)
    end
  end

  defp path_open_resolved(rel, oflags, ff, ofd_ptr) do
    exists = TinyLasers.Wasm.VFS.has?(rel)
    creat = (oflags &&& 1) != 0
    trunc = (oflags &&& 8) != 0
    append = (ff &&& 0x0001) != 0

    cond do
      # opening a DIRECTORY (the /work root or an implied subdir) — succeed with a dir fd (no content)
      dir_path?(rel) ->
        fd = TinyLasers.Wasm.FdTable.alloc(%{kind: :dir, ref: rel})
        store(wmem(), ofd_ptr, fd, 4)
        0

      not exists and not creat ->
        44

      true ->
      if not exists or trunc, do: TinyLasers.Wasm.VFS.put(rel, "")
      # APPEND fdflag positions the fd at end-of-file so writes extend rather than overwrite
      off = if append, do: byte_size(TinyLasers.Wasm.VFS.get(rel) || ""), else: 0
      fd = TinyLasers.Wasm.FdTable.alloc(%{kind: :file, ref: rel, pos: off, flags: ff})
      store(wmem(), ofd_ptr, fd, 4)
      0
    end
  end

  # WASI fd_close: refcount-aware (a dup'd fd only frees the underlying resource on the last close).
  # 0 on success, EBADF (8) on a bad fd.
  defp call_host(_rt, {_m, "fd_close", _t}, [fd]) do
    case TinyLasers.Wasm.FdTable.close(fd) do
      :ok -> 0
      {:error, :badf} -> 8
    end
  end

  # WASI fd_renumber(from, to) == POSIX dup2: `to` aliases `from` (closing `to` first if open).
  defp call_host(_rt, {_m, "fd_renumber", _t}, [from, to]) do
    case TinyLasers.Wasm.FdTable.dup2(from, to) do
      {:error, :badf} -> 8
      _ -> 0
    end
  end

  # WASI fd_fdstat_set_flags(fd, flags) — fcntl-style: set O_NONBLOCK/APPEND/… on the fd. 0/EBADF(8).
  defp call_host(_rt, {_m, "fd_fdstat_set_flags", _t}, [fd, flags]) do
    case TinyLasers.Wasm.FdTable.set_flags(fd, flags) do
      {:error, :badf} -> 8
      _ -> 0
    end
  end

  defp call_host(rt, {_m, "fd_seek", _t}, [fd, offset, whence, ofs_ptr]) do
    case TinyLasers.Wasm.FdTable.get(fd) do
      %{kind: kind, ref: path, pos: off} = d when kind in [:file] ->
        size = byte_size(TinyLasers.Wasm.VFS.get(path) || "")
        base = case whence do
          0 -> 0
          1 -> off
          2 -> size
          _ -> 0
        end
        noff = base + s64(offset)
        TinyLasers.Wasm.FdTable.put(fd, %{d | pos: noff})
        store(wmem(), ofs_ptr, noff, 8)
        0

      _ ->
        70
    end
  end

  # WASI environment — served from the run-scoped `:tl_env` (a list of "KEY=VALUE" strings, set by
  # the caller; empty by default). Same NUL-terminated, pointer-table encoding as args_get. This is the
  # generic seam credential-injection rides on: the app builds the env (e.g. a CLI connection's token)
  # and sets `:tl_env`; the runtime knows nothing about what the vars mean.
  defp call_host(rt, {_m, "environ_sizes_get", _t}, [c_ptr, b_ptr]) do
    env = Process.get(:tl_env, [])
    store(wmem(), c_ptr, length(env), 4)
    store(wmem(), b_ptr, Enum.reduce(env, 0, fn e, acc -> acc + byte_size(e) + 1 end), 4)
    0
  end

  defp call_host(rt, {_m, "environ_get", _t}, [environ_ptr, buf_ptr]) do
    Process.get(:tl_env, [])
    |> Enum.reduce({environ_ptr, buf_ptr}, fn e, {pp, bp} ->
      store(wmem(), pp, bp, 4)
      write_bytes(wmem(), bp, e)
      store(wmem(), bp + byte_size(e), 0, 1)
      {pp + 4, bp + byte_size(e) + 1}
    end)

    0
  end
  # REAL time: clock id 0 = realtime (wall, since epoch), 1 = monotonic — both in nanoseconds. A fixed
  # `:tl_clock` override (tests/determinism) still wins when set. Previously returned 0 always, which
  # silently broke every Date.now()/timestamp/timeout in a guest.
  defp call_host(rt, {_m, "clock_time_get", _t}, [id, _prec, time_ptr]) do
    t = Process.get(:tl_clock) || clock_now(id)
    store(wmem(), time_ptr, t, 8)
    0
  end

  # REAL randomness from the host CSPRNG. Previously wrote ZEROS, which silently made crypto/UUIDs/
  # hashing/Math.random deterministic-and-wrong. A `:tl_random` override (tests) still wins.
  defp call_host(rt, {_m, "random_get", _t}, [buf, len]) do
    bytes = Process.get(:tl_random) || :crypto.strong_rand_bytes(len)
    write_bytes(wmem(), buf, binary_part(bytes, 0, min(len, byte_size(bytes))) |> pad_to(len))
    0
  end
  defp call_host(_rt, {_m, "sched_yield", _t}, _args), do: 0

  # WASIX §2 thread imports. thread_spawn(start_arg_ptr) -> tid: spawn a BEAM process sharing this run's
  # memory/table (fresh per-thread globals = own stack pointer) that runs the exported
  # `wasi_thread_start(tid, start_arg)`. Returns the tid immediately (async spawn). thread_exit ends the
  # calling thread's process (a normal exit). See guest_thread_spawn for the full shared-vs-copied model.
  defp call_host(_rt, {_m, "thread_spawn", _t}, [start_arg]), do: guest_thread_spawn(start_arg)
  defp call_host(_rt, {_m, "thread-spawn", _t}, [start_arg]), do: guest_thread_spawn(start_arg)
  defp call_host(_rt, {_m, "thread_exit", _t}, _args), do: throw({:tl_exit, 0})

  # thread_parallelism(ret_ptr) -> errno: hardware-concurrency hint rayon/std use to size their pool.
  # We report a small FIXED count (keeps the emulated pool bounded + the test fast); errno 0.
  @thread_parallelism 4
  defp call_host(_rt, {_m, "thread_parallelism", _t}, [ret_ptr]) do
    store(wmem(), ret_ptr, @thread_parallelism, 4)
    0
  end

  # thread_spawn_v2(config_ptr, ret_tid_ptr) -> errno: WASIX v2 spawn. The arg is a CONFIG STRUCT ptr;
  # the guest's `wasi_thread_start(tid, start_ptr)` derefs it, so we pass config_ptr straight through
  # as the start arg. Reuses the shared spawn plumbing; writes the tid to ret_tid_ptr; errno 0.
  defp call_host(rt, {_m, "thread_spawn_v2", _t}, [config_ptr, ret_tid_ptr]) do
    tid = next_tid()
    do_guest_thread_spawn(rt, tid, config_ptr)
    store(wmem(), ret_tid_ptr, tid, 4)
    0
  end

  # thread_id(ret_ptr) -> errno: write the CURRENT thread's id. The main run has no :tl_thread_id,
  # so it reports 1; a spawned thread reports its tid (stamped at spawn). errno 0.
  defp call_host(_rt, {_m, "thread_id", _t}, [ret_ptr]) do
    store(wmem(), ret_ptr, Process.get(:tl_thread_id, 1), 8)
    0
  end

  # thread_join(tid) -> errno: BOUNDED-wait for thread `tid` to finish (mirrors proc_join). If the
  # tid is unknown (already reaped / never spawned) it is already terminal → errno 0. Otherwise we
  # monitor the worker pid and block until its :DOWN or the futex cap. NEVER infinite.
  defp call_host(_rt, {_m, "thread_join", _t}, [tid]) do
    case :ets.lookup(threads_table(), tid) do
      [{^tid, pid}] when is_pid(pid) ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          @futex_max_wait_ms -> Process.demonitor(ref, [:flush])
        end

        0

      _ ->
        0
    end
  end

  # thread_sleep(duration_ns:i64) -> errno: BOUNDED sleep (cap at the futex max). errno 0.
  defp call_host(_rt, {_m, "thread_sleep", _t}, [ns]) do
    ms = if ns <= 0, do: 0, else: min(@futex_max_wait_ms, ceil(ns / 1_000_000))
    if ms > 0, do: Process.sleep(ms)
    0
  end

  # stack_checkpoint(buf_ptr, ret_ptr) -> errno: WASIX asyncify setjmp hook. We model the FIRST-TIME
  # (setjmp-returns-0) path: write 0 to ret_ptr (this is the initial call, not a longjmp restore),
  # errno 0. True restore (stack_restore) is asyncify unwinding (wb-nsrp); never reached when no
  # panic/fork crosses the boundary — rayon's parallel-sum does not.
  defp call_host(_rt, {_m, "stack_checkpoint", _t}, [_buf_ptr, ret_ptr]) do
    store(wmem(), ret_ptr, 0, 8)
    0
  end

  # stack_restore(buf_ptr, val:i64) -> (): the longjmp back to a checkpoint via asyncify. Unsupported
  # without a real asyncify unwind (wb-nsrp); if a guest ever hits it, fail LOUDLY rather than silently
  # corrupt — rayon's parallel-sum path never restores, so this stays unhit.
  defp call_host(_rt, {_m, "stack_restore", _t}, [_buf_ptr, _val]) do
    raise "tinylasers: stack_restore (asyncify longjmp) unimplemented — needs true asyncify unwind (wb-nsrp)"
  end
  defp call_host(_rt, {_m, "fd_sync", _t}, _args), do: 0
  defp call_host(_rt, {_m, "fd_datasync", _t}, _args), do: 0

  # file stat: report a regular file with the VFS content's size; dir/path ops succeed minimally.
  defp call_host(rt, {_m, "fd_filestat_get", _t}, [fd, ptr]) do
    {ftype, size} =
      case TinyLasers.Wasm.FdTable.get(fd) do
        %{kind: :dir} -> {3, 0}
        %{kind: :file, ref: path} when is_binary(path) -> {4, byte_size(TinyLasers.Wasm.VFS.get(path) || "")}
        _ -> {4, 0}
      end

    # filestat: dev(8) ino(8) filetype(1) +pad(7) nlink(8) size(8) atim(8) mtim(8) ctim(8)
    store(wmem(), ptr + 16, ftype, 1)
    store(wmem(), ptr + 32, size, 8)
    0
  end

  # path stat: `flags` bit0 (LOOKUP_SYMLINK_FOLLOW) controls whether we stat the link's TARGET (set) or
  # the link itself (clear → report filetype SYMLINK=7 with the target-string length as size). A directory
  # is filetype 3, a regular file 4. Missing path → ENOENT(44); a broken/looping link target → ELOOP(32).
  defp call_host(rt, {_m, "path_filestat_get", _t}, [_dirfd, flags, path_ptr, path_len, ptr | _]) do
    rel = read_bytes(wmem(), path_ptr, path_len)
    follow = (flags &&& 1) != 0
    link = symlink_target(rel)

    cond do
      link != nil and not follow ->
        store(wmem(), ptr + 16, 7, 1)
        store(wmem(), ptr + 32, byte_size(link), 8)
        0

      link != nil ->
        case resolve_symlink(rel, 8) do
          {:error, :loop} -> 32
          {:ok, tgt} -> stat_path(tgt, ptr)
        end

      true ->
        stat_path(rel, ptr)
    end
  end

  # write a filestat record for a concrete (already symlink-resolved) path. dir → 3, file → 4, else ENOENT.
  defp stat_path(rel, ptr) do
    cond do
      dir_path?(rel) -> (store(wmem(), ptr + 16, 3, 1); store(wmem(), ptr + 32, 0, 8); 0)
      (c = TinyLasers.Wasm.VFS.get(rel)) != nil -> (store(wmem(), ptr + 16, 4, 1); store(wmem(), ptr + 32, byte_size(c), 8); 0)
      true -> 44
    end
  end

  # a path that names a DIRECTORY: the /work root (".", "", "/") or an implied subdir (a prefix of a key)
  defp dir_path?(rel) do
    rel in ["", ".", "/", "/work", "/work/", "./"] or
      MapSet.member?(tl_dirs(), rel) or
      Enum.any?(TinyLasers.Wasm.VFS.list(), &String.starts_with?(&1, rel <> "/"))
  end

  # ── explicit-directory tracking ─────────────────────────────────────────────────────────────────
  # The flat VFS has no native dir concept, so empty dirs created by `path_create_directory` would be
  # invisible (no key has them as a prefix). We track them in a per-run `:tl_dirs` MapSet so mkdir →
  # stat → rmdir behaves like POSIX. Implicit dirs (a prefix of an existing file key) stay handled above.
  defp tl_dirs, do: Process.get(:tl_dirs, MapSet.new())
  defp put_tl_dirs(set), do: Process.put(:tl_dirs, set)

  defp call_host(rt, {_m, "fd_tell", _t}, [fd, ptr]) do
    off = case TinyLasers.Wasm.FdTable.get(fd) do
      %{pos: o} -> o
      _ -> 0
    end
    store(wmem(), ptr, off, 8)
    0
  end

  # WASI fd_filestat_set_size == ftruncate(fd, size): actually resize the backing VFS content — pad with
  # NUL bytes when growing, slice when shrinking. Was a no-op stub, so truncate/grow silently did nothing.
  # 0 on success; EBADF(8) for a non-file/closed fd; EINVAL(28) for a negative size.
  defp call_host(_rt, {_m, "fd_filestat_set_size", _t}, [fd, size]) do
    cond do
      s64(size) < 0 -> 28

      true ->
        case TinyLasers.Wasm.FdTable.get(fd) do
          %{kind: :file, ref: path} when is_binary(path) ->
            content = TinyLasers.Wasm.VFS.get(path) || ""
            resized =
              if size >= byte_size(content),
                do: pad_to(content, size),
                else: binary_part(content, 0, size)

            TinyLasers.Wasm.VFS.put(path, resized)
            0

          _ ->
            8
        end
    end
  end
  defp call_host(_rt, {_m, "fd_filestat_set_times", _t}, _args), do: 0
  # list the /work directory: WASI dirents (24-byte header {d_next, d_ino, d_namlen, d_type} + name)
  # streamed from `cookie`, truncated to `buf_len`. `d_next = index+1` lets the guest resume. Previously
  # returned 8 (ENOSYS), so ls / os.listdir / fs.readdir all failed.
  defp call_host(rt, {_m, "fd_readdir", _t}, [_fd, buf, buf_len, cookie, bufused_ptr]) do
    stream =
      readdir_entries()
      |> Enum.with_index()
      |> Enum.drop(cookie)
      |> Enum.map(fn {{name, type}, idx} ->
        <<idx + 1::64-little, 0::64-little, byte_size(name)::32-little, type, 0::size(24)>> <> name
      end)
      |> IO.iodata_to_binary()

    out = binary_part(stream, 0, min(buf_len, byte_size(stream)))
    write_bytes(wmem(), buf, out)
    store(wmem(), bufused_ptr, byte_size(out), 4)
    0
  end

  # the /work entries: top-level files (type 4) + implied dirs from nested keys (type 3), plus . and ..
  defp readdir_entries do
    files =
      TinyLasers.Wasm.VFS.list()
      |> Enum.map(fn key ->
        case String.split(key, "/", parts: 2) do
          [name] -> {name, 4}
          [dir, _] -> {dir, 3}
        end
      end)
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort()

    [{".", 3}, {"..", 3} | files]
  end
  # WASI poll_oneoff(in, out, nsubscriptions, nevents_ptr) -> errno. REAL emulated poll: we compute
  # immediate readiness of the subscribed fds/clocks against the host store + real clock, and — for the
  # canonical libc nanosleep-via-poll path — bounded-sleep until a clock timeout elapses. Faithful to the
  # emulation thesis: the guest only needs the observable cause-and-effect (an event for each ready sub).
  #
  # Subscription = 48 bytes: userdata@0(u64), tag@8(u8), union@16. clock: clock_id@16(u32),
  # timeout@24(u64 ns), precision@32(u64), flags@40(u16; bit0=ABSTIME). fd_read/fd_write: fd@16(u32).
  # Event = 32 bytes: userdata@0(u64), error@8(u16), type@10(u8), nbytes@16(u64), rwflags@24(u16).
  @poll_clock_cap_ms 60_000
  # bounded cap for a TRUE fd-block (arm+receive) with NO clock sub — NEVER infinite (project rule).
  @poll_block_cap_ms 30_000
  @poll_subscription_clock 0
  @poll_subscription_fd_read 1
  @poll_subscription_fd_write 2
  @poll_abstime 0x0001
  @poll_eventrwflags_hangup 0x0001
  defp call_host(_rt, {_m, "poll_oneoff", _t}, [in_ptr, out_ptr, nsubs, nevents_ptr]) do
    mem = wmem()
    subs = for i <- 0..(nsubs - 1)//1, do: parse_subscription(mem, in_ptr + i * 48)

    # Pass 1: anything immediately ready (fds with data/EOF, writable fds, already-elapsed clocks).
    ready = Enum.filter(subs, &poll_immediate_ready?/1)

    events =
      if ready != [] do
        Enum.map(ready, &poll_event/1)
      else
        poll_block(subs)
      end

    Enum.with_index(events, fn ev, k -> write_event(mem, out_ptr + k * 32, ev) end)
    store(mem, nevents_ptr, length(events), 4)
    0
  end
  # mkdir: record the relpath in the tracked-dir set. EEXIST(20) if it already exists as a file/dir.
  defp call_host(rt, {_m, "path_create_directory", _t}, [_dirfd, path_ptr, path_len]) do
    rel = read_bytes(wmem(), path_ptr, path_len)

    cond do
      TinyLasers.Wasm.VFS.has?(rel) or MapSet.member?(tl_dirs(), rel) -> 20
      true -> (put_tl_dirs(MapSet.put(tl_dirs(), rel)); 0)
    end
  end

  # rmdir: reject a non-empty dir (any VFS key or tracked dir lives UNDER it) with ENOTEMPTY(55); remove an
  # empty tracked dir; ENOENT(44) for an unknown path. Was a no-op stub, so rmdir silently did nothing.
  defp call_host(rt, {_m, "path_remove_directory", _t}, [_dirfd, path_ptr, path_len]) do
    rel = read_bytes(wmem(), path_ptr, path_len)
    prefix = rel <> "/"
    nonempty =
      Enum.any?(TinyLasers.Wasm.VFS.list(), &String.starts_with?(&1, prefix)) or
        Enum.any?(tl_dirs(), &String.starts_with?(&1, prefix))

    cond do
      nonempty -> 55
      MapSet.member?(tl_dirs(), rel) -> (put_tl_dirs(MapSet.delete(tl_dirs(), rel)); 0)
      true -> 44
    end
  end

  # real file management over the VFS — was no-op stubs, so rm/mv silently did nothing.
  # unlink also drops a symlink entry (a link is removed, not its target).
  defp call_host(rt, {_m, "path_unlink_file", _t}, [_dirfd, path_ptr, path_len]) do
    rel = read_bytes(wmem(), path_ptr, path_len)

    cond do
      symlink_target(rel) != nil -> (del_symlink(rel); 0)
      TinyLasers.Wasm.VFS.has?(rel) -> (TinyLasers.Wasm.VFS.delete(rel); 0)
      true -> 44
    end
  end

  # rename(from → to): MOVE the content (or the symlink entry, if the source is a link). Also re-point any
  # open fd whose ref was `from` so a held descriptor keeps reading the moved bytes.
  defp call_host(rt, {_m, "path_rename", _t}, [_ofd, op, ol, _nfd, np, nl]) do
    from = read_bytes(wmem(), op, ol)
    to = read_bytes(wmem(), np, nl)

    cond do
      (tgt = symlink_target(from)) != nil ->
        del_symlink(from)
        put_symlink(to, tgt)
        0

      (content = TinyLasers.Wasm.VFS.get(from)) != nil ->
        TinyLasers.Wasm.VFS.put(to, content)
        TinyLasers.Wasm.VFS.delete(from)
        TinyLasers.Wasm.FdTable.repoint(from, to)
        0

      true ->
        44
    end
  end

  defp call_host(_rt, {_m, "path_link", _t}, _args), do: 0

  # path_symlink(old_path, dirfd, new_path): create a symlink at `new_path` pointing at `old_path`.
  # Stored in the per-run `:tl_symlinks` map (relpath → target string), a sibling to the VFS — the flat
  # VFS holds bytes, so links live alongside it rather than encoding a tagged value into content. → 0.
  defp call_host(rt, {_m, "path_symlink", _t}, [old_ptr, old_len, _dirfd, new_ptr, new_len]) do
    target = read_bytes(wmem(), old_ptr, old_len)
    link = read_bytes(wmem(), new_ptr, new_len)
    put_symlink(link, target)
    0
  end

  # path_readlink: write the link target into `buf` (truncated to buf_len), store the written length at
  # bufused_ptr. EINVAL(28) if the path is not a symlink; ENOENT(44) if nothing is there at all.
  defp call_host(rt, {_m, "path_readlink", _t}, [_dirfd, path_ptr, path_len, buf, buf_len, bufused_ptr]) do
    rel = read_bytes(wmem(), path_ptr, path_len)

    case symlink_target(rel) do
      nil ->
        if TinyLasers.Wasm.VFS.has?(rel) or dir_path?(rel), do: 28, else: 44

      target ->
        out = binary_part(target, 0, min(buf_len, byte_size(target)))
        write_bytes(wmem(), buf, out)
        store(wmem(), bufused_ptr, byte_size(out), 4)
        0
    end
  end

  # ── symlink model ───────────────────────────────────────────────────────────────────────────────
  # A per-run `:tl_symlinks` map (relpath → target relpath string), held in the process dict beside the
  # VFS. The VFS values are plain content bytes, so links can't ride inside them — this sibling map is the
  # cleanest home and threads through the same process the VFS does.
  defp tl_symlinks, do: Process.get(:tl_symlinks, %{})
  defp symlink_target(rel), do: Map.get(tl_symlinks(), rel)
  defp put_symlink(rel, target), do: Process.put(:tl_symlinks, Map.put(tl_symlinks(), rel, target))
  defp del_symlink(rel), do: Process.put(:tl_symlinks, Map.delete(tl_symlinks(), rel))

  # Follow a symlink chain to the concrete target path, bounded to `depth` hops to defeat loops (a→b→a).
  # → {:ok, final_relpath} when the path is not a link, or resolves to one; {:error, :loop} past the bound.
  defp resolve_symlink(_rel, 0), do: {:error, :loop}

  defp resolve_symlink(rel, depth) do
    case symlink_target(rel) do
      nil -> {:ok, rel}
      target -> resolve_symlink(target, depth - 1)
    end
  end

  # Generic host bridge (Wave 0 fan-out seam): __host(name,args) — sync. Decode JSON name+args, route to the
  # concern module by convention (HostFs/HostNet/…), JSON-encode the result back. Concerns add NO clause here.
  defp call_host(_rt, {_m, "host_call", _t}, [np, nl, ap, al, op, _oc]) do
    name = read_bytes(wmem(), np, nl)
    args = TinyLasers.Wasm.Actor.Term.from_json(read_bytes(wmem(), ap, al))
    json = TinyLasers.Wasm.HostIO.dispatch_call(name, List.wrap(args)) |> TinyLasers.Wasm.Actor.Term.to_json()
    write_bytes(wmem(), op, json)
    byte_size(json)
  end

  # __host_async(name,args) — fire-and-forget; the concern resolves the guest promise `id` later via
  # Actor.io_complete → the wb_complete re-entry. Returns 0.
  defp call_host(_rt, {_m, "host_call_async", _t}, [np, nl, ap, al, id]) do
    name = read_bytes(wmem(), np, nl)
    args = TinyLasers.Wasm.Actor.Term.from_json(read_bytes(wmem(), ap, al))
    TinyLasers.Wasm.HostIO.dispatch_async(name, List.wrap(args), id)
  end

  # Registrable host-import table — the general seam for running an ARBITRARY wasm module that needs
  # host-provided imports (the thesis's host-mediated multi-module invocation: e.g. QuickJS calling out
  # to Rollup's wasm parser running as a sibling Wasm module). A consumer installs
  # `Process.put(:tl_imports, %{{mod, name} => fun/1, name => fun/1})`; the fun gets the arg list and
  # returns the result int (or nil). Checked only AFTER all built-in WASI/WASIX clauses, so it never
  # shadows the core ABI. Falls through to the hard error when nothing matches.
  defp call_host(_rt, {m, name, _t}, args) do
    tbl = Process.get(:tl_imports, %{})

    case Map.get(tbl, {m, name}) || Map.get(tbl, name) do
      fun when is_function(fun, 1) -> fun.(args)
      _ -> raise("tinylasers: unimplemented host import '#{m}'.'#{name}'")
    end
  end

  @doc "Write `bin` byte-for-byte into the packed memory `mem` at `addr` (little-endian, same layout the guest sees)."
  def write_bytes(mem, addr, bin) do
    bin |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> store(mem, addr + i, b, 1) end)
  end

  # ── poll_oneoff helpers ─────────────────────────────────────────────────────────────────────────
  # Decode one 48-byte subscription into a tidy map (userdata + tag + the union slice we need).
  defp parse_subscription(mem, base) do
    %{
      userdata: load(mem, base + 0, 8),
      tag: load(mem, base + 8, 1),
      # clock fields
      clock_id: load(mem, base + 16, 4),
      timeout: load(mem, base + 24, 8),
      flags: load(mem, base + 40, 2),
      # fd_read/fd_write field (overlaps the union start @16)
      fd: load(mem, base + 16, 4)
    }
  end

  # TRUE fd-blocking branch (wb-clmb): nothing was immediately ready. Rather than busy-return 0 events
  # (which made a tokio/mio reactor polling sockets BUSY-SPIN), we ARM each socket fd_read sub for a
  # single mailbox event and bounded-`receive` until an fd becomes ready or the deadline elapses.
  #
  # Deadline: min(clock relative timeouts, cap) if there are clock subs; else the cap alone. NEVER
  # infinite — bounded by @poll_block_cap_ms (project rule: no unbounded block). On timeout we fire the
  # elapsed clock event(s) (the old nanosleep-via-poll behavior) or, with no clock, emit 0 events (the
  # guest re-polls — bounded fallback, not a hang).
  defp poll_block(subs) do
    clocks = Enum.filter(subs, &(&1.tag == @poll_subscription_clock))

    deadline_ms =
      case clocks do
        [] -> @poll_block_cap_ms
        _ -> clocks |> Enum.map(&clock_rel_ms/1) |> Enum.min() |> max(0) |> min(@poll_block_cap_ms)
      end

    # Arm every socket fd_read sub for one readiness message; collect the armed transport ports. Pipes
    # have no writer-notify wiring yet (see wb-clmb follow-up) — they ride the bounded-timeout fallback.
    armed =
      subs
      |> Enum.filter(&(&1.tag == @poll_subscription_fd_read))
      |> Enum.map(&TinyLasers.Wasm.HostSock.arm_readable(&1.fd))
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1, true})

    # Selective receive: ONLY match tcp messages whose port is one we armed (the guard
    # `is_map_key(armed, sock)`, with `armed` a plain `%{port => true}` map so the guard is BIF-safe).
    # Erlang leaves every non-matching message (timers `wb_timer`, worker IPC, …) untouched in the
    # mailbox — so we never swallow unrelated actor mail. On a wake we stash any bytes, then re-scan ALL
    # subs for readiness so a multi-fd poll reports every fd that is now ready.
    receive do
      {:tcp, sock, data} when is_map_key(armed, sock) ->
        TinyLasers.Wasm.HostSock.deliver(sock, data)
        subs |> Enum.filter(&poll_immediate_ready?/1) |> Enum.map(&poll_event/1)

      {:tcp_closed, sock} when is_map_key(armed, sock) ->
        # peer closed — POLLHUP. readable?/1 will report {true, 0, hangup} via the next recv.
        subs |> Enum.filter(&poll_immediate_ready?/1) |> Enum.map(&poll_event/1)

      {:tcp_error, sock, _reason} when is_map_key(armed, sock) ->
        subs |> Enum.filter(&poll_immediate_ready?/1) |> Enum.map(&poll_event/1)
    after
      deadline_ms ->
        # Timed out. Fire every clock whose (capped) wait has now elapsed (≥ the minimum one); with no
        # clock sub this is [] — 0 events, the bounded re-poll fallback.
        Enum.filter(clocks, &(min(max(clock_rel_ms(&1), 0), @poll_block_cap_ms) <= deadline_ms))
        |> Enum.map(&poll_event/1)
    end
  end

  # Is this subscription ready RIGHT NOW (no sleep)? Clocks: only a relative-0 / already-past abstime.
  defp poll_immediate_ready?(%{tag: @poll_subscription_clock} = s), do: clock_rel_ms(s) <= 0
  defp poll_immediate_ready?(%{tag: @poll_subscription_fd_read, fd: fd}) do
    {ready, _n, _hup} = TinyLasers.Wasm.FdTable.readable?(fd)
    ready
  end
  # fd_write: pipes/files/sockets are always writable in our emulation.
  defp poll_immediate_ready?(%{tag: @poll_subscription_fd_write}), do: true
  defp poll_immediate_ready?(_), do: false

  # Relative wait (ms) for a clock subscription: abstime → (timeout - now); relative → timeout. ns→ms.
  defp clock_rel_ms(%{tag: @poll_subscription_clock, clock_id: id, timeout: t, flags: f}) do
    rel_ns =
      if (f &&& @poll_abstime) != 0 do
        t - clock_now(id)
      else
        t
      end

    Integer.floor_div(max(rel_ns, 0) + 999_999, 1_000_000)
  end

  # Build the event tuple for a ready subscription: {userdata, errno, type, nbytes, rwflags}.
  defp poll_event(%{tag: @poll_subscription_clock, userdata: u}),
    do: {u, 0, @poll_subscription_clock, 0, 0}

  defp poll_event(%{tag: @poll_subscription_fd_read, userdata: u, fd: fd}) do
    {_ready, nbytes, hangup} = TinyLasers.Wasm.FdTable.readable?(fd)
    rwflags = if hangup, do: @poll_eventrwflags_hangup, else: 0
    {u, 0, @poll_subscription_fd_read, nbytes, rwflags}
  end

  defp poll_event(%{tag: @poll_subscription_fd_write, userdata: u}),
    do: {u, 0, @poll_subscription_fd_write, 65_536, 0}

  # Write a 32-byte event record.
  defp write_event(mem, base, {userdata, errno, type, nbytes, rwflags}) do
    store(mem, base + 0, userdata, 8)
    store(mem, base + 8, errno, 2)
    store(mem, base + 10, type, 1)
    store(mem, base + 16, nbytes, 8)
    store(mem, base + 24, rwflags, 2)
    :ok
  end

  defp stdin_take(n) do
    buf = Process.get(:tl_stdin, "")
    take = min(n, byte_size(buf))
    <<chunk::binary-size(take), rest::binary>> = buf
    Process.put(:tl_stdin, rest)
    chunk
  end

  # ── the virtual filesystem (files as an Elixir map: relpath => bytes; the node-graph model) ──────
  defp preopen_name, do: "/work"

  defp gather_iovs(mem, iovs, n) do
    for(i <- 0..(n - 1)//1, do: read_bytes(mem, load(mem, iovs + i * 8, 4), load(mem, iovs + i * 8 + 4, 4)))
    |> IO.iodata_to_binary()
  end

  defp iov_capacity(mem, iovs, n), do: Enum.reduce(0..(n - 1)//1, 0, fn i, acc -> acc + load(mem, iovs + i * 8 + 4, 4) end)

  defp scatter_iovs(mem, iovs, n, data) do
    {written, _} =
      Enum.reduce(0..(n - 1)//1, {0, data}, fn i, {w, rem} ->
        base = load(mem, iovs + i * 8, 4)
        len = load(mem, iovs + i * 8 + 4, 4)
        take = min(len, byte_size(rem))
        <<chunk::binary-size(take), rest::binary>> = rem
        write_bytes(mem, base, chunk)
        {w + take, rest}
      end)

    written
  end

  @doc "Read `len` bytes from packed memory `mem` at `addr` (little-endian, same layout the guest sees)."
  def read_bytes(_mem, _addr, 0), do: ""
  def read_bytes(mem, addr, len), do: for(j <- 0..(len - 1)//1, do: load(mem, addr + j, 1)) |> :erlang.list_to_binary()

  defp file_read(fd, n) do
    case TinyLasers.Wasm.FdTable.get(fd) do
      %{kind: :file, ref: path, pos: off} = d when is_binary(path) ->
        content = TinyLasers.Wasm.VFS.get(path) || ""
        take = max(0, min(n, byte_size(content) - off))
        chunk = if take > 0, do: binary_part(content, off, take), else: ""
        TinyLasers.Wasm.FdTable.put(fd, %{d | pos: off + take})
        chunk

      _ ->
        ""
    end
  end

  defp file_write(fd, data) do
    case TinyLasers.Wasm.FdTable.get(fd) do
      %{kind: :file, ref: path, pos: off} = d when is_binary(path) ->
        content = pad_to(TinyLasers.Wasm.VFS.get(path) || "", off)
        tail_start = off + byte_size(data)
        post = if byte_size(content) > tail_start, do: binary_part(content, tail_start, byte_size(content) - tail_start), else: ""
        TinyLasers.Wasm.VFS.put(path, binary_part(content, 0, off) <> data <> post)
        TinyLasers.Wasm.FdTable.put(fd, %{d | pos: tail_start})

      _ ->
        :ok
    end
  end

  defp pad_to(bin, n) when byte_size(bin) >= n, do: bin
  defp pad_to(bin, n), do: bin <> :binary.copy(<<0>>, n - byte_size(bin))

  # real wall-clock time in nanoseconds (always positive); used by clock_time_get for any clock id
  defp clock_now(_id), do: System.os_time(:nanosecond)

  # v128 load/store: 16 bytes <-> a 16-byte binary
  defp vload(mem, addr), do: for(i <- 0..15, do: mget(mem, addr + i)) |> :erlang.list_to_binary()
  defp vstore(mem, addr, <<bytes::binary-size(16)>>), do: bytes |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> mput(mem, addr + i, b) end)

  # Type-driven arity for a global function index (import or local).
  @doc """
  Packed `:atomics` slot count a fresh instance allocates for linear memory — `max(1, min) * 8192`
  (8 bytes/slot). Pure function of the module's declared `min` pages; the per-cell memory footprint
  is `mem_slots(mod) * 8` bytes. Used by density introspection / the ops gauge. `0` if no memory.
  """
  def mem_slots(%__MODULE__{mem: nil}), do: 0
  # shared memory is pre-allocated at its max (see new_mem); others at min.
  def mem_slots(%__MODULE__{mem: {_min, max, :shared}}) when is_integer(max), do: max * @page_words
  def mem_slots(%__MODULE__{mem: {min, _max, _share}}), do: max(1, min) * @page_words
  def mem_slots(%__MODULE__{mem: {min, _max}}), do: max(1, min) * @page_words

  @doc """
  Resolve an exported LOCAL function to `{arity, nlocals, instrs}` — the same structured body the
  interpreter runs, for the transpiler / static analysis to consume. Raises if `name` is an import.
  """
  def function_body(%__MODULE__{} = mod, name) do
    fidx = Map.fetch!(mod.exports, name)
    ni = length(mod.imports)
    if fidx < ni, do: raise(ArgumentError, "#{name} is an imported function, not transpilable")
    local_idx = fidx - ni
    {nlocals, instrs} = Enum.at(mod.code, local_idx)
    {params, _results} = Enum.at(mod.types, Enum.at(mod.funcs, local_idx))
    {length(params), nlocals, instrs}
  end

  # the resolved `{params, results}` signature of a function (import or local) by global index
  defp func_type(mod, fidx) do
    ni = length(mod.imports)
    tidx = if fidx < ni, do: elem(Enum.at(mod.imports, fidx), 2), else: Enum.at(mod.funcs, fidx - ni)
    Enum.at(mod.types, tidx)
  end

  defp func_arity(mod, fidx) do
    ni = length(mod.imports)

    tidx =
      if fidx < ni do
        {_, _, t} = Enum.at(mod.imports, fidx)
        t
      else
        Enum.at(mod.funcs, fidx - ni)
      end

    {params, _} = Enum.at(mod.types, tidx)
    length(params)
  end

  # Number of RESULTS a function returns (0 for void). Used to decide whether a `call` pushes a value —
  # must be arity-based, since the asm lane returns 0 (not nil) for void functions (wb-7jwh).
  defp func_result_arity(mod, fidx) do
    {_params, results} = func_type(mod, fidx)
    length(results)
  end

  # Run an instruction list, threading the operand stack + locals. Returns a SIGNAL so structured control
  # flow works: `{:next, stack, l}` (fell through), `{:br, n, stack, l}` (branch out n labels), or
  # `{:return, stack, l}`. A br/return stops the list and propagates up to the enclosing block/loop.
  defp run([], stack, l, _rt), do: {:next, stack, l}

  defp run([instr | rest], stack, l, rt) do
    # charge one unit of fuel per instruction; a guest that exhausts its budget traps (bounds runaway
    # work). `sub_get` is atomic + allocation-free — the safety tax on the hot path is one atomics op.
    if :atomics.sub_get(rt.fuel, 1, 1) < 0, do: trap!(:out_of_fuel)

    case step(instr, stack, l, rt) do
      {:next, stack, l} -> run(rest, stack, l, rt)
      other -> other
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────────────────
  # REIFIED-STACK INTERPRETER (`tramp`) — the fork-safe lane (wb-nsrp).
  #
  # `run/4` above keeps wasm control state on the BEAM call stack (native recursion through
  # block/loop/if/call), so a continuation can't be captured — that's why true return-twice
  # `proc_fork` was blocked. `tramp` is the SAME interpreter with the call/control stack made
  # EXPLICIT: it is tail-recursive (the BEAM stack stays flat), and the only stack is the
  # `frames` list — a plain copyable term. Snapshot `frames`+memory+globals at the `proc_fork`
  # host boundary and you have the continuation to resume twice (Stage 3).
  #
  # DRY: every LEAF op still goes through the existing `step/4` — only the 4 recursive cases
  # (block/loop/if/call) + br/return propagation are reified here. `try_table` subtrees delegate
  # to the recursive `step` (with `cps: false`) so exception unwinding stays native; the only
  # consequence is that a `proc_fork` *dynamically inside a try_table body* runs recursive and
  # can't be captured — fine for C fork()/Rust-without-catch_unwind (the real cases).
  #
  # Frame encodings (what each enclosing construct needs to resume):
  #   {:blk, rest}            — block / taken-if arm: br 0 or fallthrough → continue `rest`
  #   {:lop, body, rest}      — loop: br 0 → re-enter `body`; fallthrough/exit → continue `rest`
  #   {:cal, rest, cvs, cl}   — call return: callee done → push its result onto caller vs `cvs`,
  #                             resume caller `rest` with caller locals `cl`
  # Returns `{:done, vs, l}` when the top-level function's frames are exhausted.
  defp interp_invoke_cps(rt, local_idx, args) do
    if :atomics.add_get(rt.depth, 1, 1) > rt.max_depth, do: trap!(:stack_exhausted)
    {nlocals, instrs} = Enum.at(rt.mod.code, local_idx)
    locals = (args ++ List.duplicate(0, nlocals)) |> List.to_tuple()
    {:done, vs, _l} = tramp(instrs, [], locals, [], rt)
    :atomics.sub(rt.depth, 1, 1)

    case vs do
      [top | _] -> top
      [] -> nil
    end
  end

  # end of an instruction sequence = fallthrough; behaves like {:next,…} bubbling into the
  # enclosing frame (block/loop exit → continue after; call return → push result + resume caller).
  defp tramp([], vs, l, frames, rt), do: unwind_next(vs, l, frames, rt)

  defp tramp([instr | rest], vs, l, frames, rt) do
    if :atomics.sub_get(rt.fuel, 1, 1) < 0, do: trap!(:out_of_fuel)

    case instr do
      {:block, nres, body} ->
        tramp(body, vs, l, [{:blk, rest, nres, length(vs)} | frames], rt)

      {:if, nres, then_b, else_b} ->
        [c | vs2] = vs
        tramp(if(c != 0, do: then_b, else: else_b), vs2, l, [{:blk, rest, nres, length(vs2)} | frames], rt)

      {:loop, nres, body} ->
        tramp(body, vs, l, [{:lop, nres, body, rest, length(vs)} | frames], rt)

      {:call, f} ->
        ni = rt.ni

        if f < ni do
          # host import — leaf to the host seam. proc_fork is intercepted HERE: `frames`+`rest`+`vs2`
          # ARE the guest continuation (the only reason this lane exists), so we can resume it twice.
          {_m, fname, _t} = Enum.at(rt.mod.imports, f)
          {args, vs2} = Enum.split(vs, func_arity(rt.mod, f))
          args = Enum.reverse(args)

          case {fname, args} do
            {"proc_fork", [copy_mem, ret_pid_ptr]} ->
              fork_cps(rt, copy_mem, ret_pid_ptr, rest, vs2, l, frames)

            _ ->
              r = call_fn(rt, f, args)
              tramp(rest, push_res(r, vs2), l, frames, rt)
          end
        else
          # local call — inline as a {:cal} frame (NO native recursion), switch to the callee
          {args, vs2} = Enum.split(vs, func_arity(rt.mod, f))
          {nlocals, body} = Enum.at(rt.mod.code, f - ni)
          clocals = (Enum.reverse(args) ++ List.duplicate(0, nlocals)) |> List.to_tuple()
          if :atomics.add_get(rt.depth, 1, 1) > rt.max_depth, do: trap!(:stack_exhausted)
          tramp(body, [], clocals, [{:cal, rest, vs2, l} | frames], rt)
        end

      {:try_table, _catches, _body} ->
        # exception subtree stays native (recursive step, cps off) — see module note above.
        handle_ctrl(step(instr, vs, l, %{rt | cps: false}), rest, frames, rt)

      _ ->
        # every other op = leaf: reuse the existing step/4 (DRY), then route its control result.
        handle_ctrl(step(instr, vs, l, rt), rest, frames, rt)
    end
  end

  # route a leaf/try result tuple back into the trampoline
  defp handle_ctrl({:next, vs, l}, rest, frames, rt), do: tramp(rest, vs, l, frames, rt)
  defp handle_ctrl({:br, n, vs, l}, _rest, frames, rt), do: do_br(n, vs, l, frames, rt)
  defp handle_ctrl({:return, vs, l}, _rest, frames, rt), do: do_return(vs, l, frames, rt)

  # br n: peel n enclosing control frames, then the target frame handles label 0. On reaching the target,
  # truncate vs to [top results ++ block-entry operands] — a `br` may carry extra operands the spec drops.
  defp do_br(0, vs, l, [{:blk, rest, nres, entry} | frames], rt),
    do: tramp(rest, keep_arity(vs, entry, nres), l, frames, rt)

  # loop label 0 = re-enter the loop body with [params (0) ++ entry] (keep the loop frame).
  defp do_br(0, vs, l, [{:lop, _nres, body, _rest, entry} = f | frames], rt),
    do: tramp(body, keep_arity(vs, entry, 0), l, [f | frames], rt)

  defp do_br(n, vs, l, [{:blk, _, _, _} | frames], rt), do: do_br(n - 1, vs, l, frames, rt)
  defp do_br(n, vs, l, [{:lop, _, _, _, _} | frames], rt), do: do_br(n - 1, vs, l, frames, rt)

  # return: discard control frames up to the nearest call boundary, then return into the caller.
  defp do_return(vs, l, [{:cal, _, _, _} | _] = frames, rt), do: ret_into_caller(vs, frames, rt)
  defp do_return(vs, l, [_ | frames], rt), do: do_return(vs, l, frames, rt)
  defp do_return(vs, _l, [], _rt), do: {:done, vs, nil}

  # fallthrough at end of a sequence: block/loop exit → continue after; call → resume caller.
  defp unwind_next(vs, l, [{:blk, rest, nres, entry} | frames], rt), do: tramp(rest, keep_arity(vs, entry, nres), l, frames, rt)
  defp unwind_next(vs, l, [{:lop, nres, _body, rest, entry} | frames], rt), do: tramp(rest, keep_arity(vs, entry, nres), l, frames, rt)
  defp unwind_next(vs, _l, [{:cal, _, _, _} | _] = frames, rt), do: ret_into_caller(vs, frames, rt)
  defp unwind_next(vs, _l, [], _rt), do: {:done, vs, nil}

  # pop a {:cal} frame: drop depth, push the callee result (nil = void) onto the caller stack.
  defp ret_into_caller(vs, [{:cal, rest, cvs, cl} | frames], rt) do
    :atomics.sub(rt.depth, 1, 1)
    r = case vs do [top | _] -> top; [] -> nil end
    tramp(rest, push_res(r, cvs), cl, frames, rt)
  end

  defp push_res(nil, vs), do: vs
  defp push_res(r, vs), do: [r | vs]

  # ── TRUE return-twice proc_fork (wb-nsrp Stage 3) ───────────────────────────────────────────────
  # We are AT the proc_fork host boundary inside `tramp`, so the continuation is in hand: resuming
  # `tramp(rest, push_res(0, vs2), l, frames, _)` runs "everything after fork() returns". Run it TWICE:
  #   • CHILD  — a spawned BEAM process over a COPIED linear memory + globals + fd snapshot, with the
  #              pid-out-ptr set to 0 (so libc's fork() returns 0). It runs to _exit and reports status.
  #   • PARENT — the current process, pid-out-ptr set to the child pid (fork() returns the child pid).
  # Both resume with proc_fork's own result = 0 (errno OK). `copy_mem` (POSIX always copies) is honored.
  defp fork_cps(rt, _copy_mem, ret_pid_ptr, rest, vs2, l, frames) do
    parent = self()
    child_pid = TinyLasers.Wasm.HostProc.register_fork_child()

    # snapshot the parent run context the child must adopt — same keys as a thread spawn, but memory
    # and page-counter are DEEP COPIES (fork isolation), not shared refs.
    parent_mem = Process.get(:tl_mem)
    child_mem = copy_mem(parent_mem)
    child_globals = copy_globals(rt.globals)
    child_mem_pages = copy_globals(Process.get(:tl_mem_pages))

    ctx = %{
      mem_pages: child_mem_pages,
      max_pages: Process.get(:tl_max_pages),
      table: Process.get(:tl_table),
      table_size: Process.get(:tl_table_size),
      last_fuel: Process.get(:tl_last_fuel),
      programs: Process.get(:tl_programs),
      vfs: Process.get(:tl_vfs),
      fdmap: Process.get(:tl_fdmap),
      descs: Process.get(:tl_descs),
      nextfd: Process.get(:tl_nextfd),
      nextdesc: Process.get(:tl_nextdesc),
      pipes: Process.get(:tl_pipes),
      sockstate: Process.get(:tl_sockstate),
      socknext: Process.get(:tl_socknext)
    }

    # the child gets its OWN fuel + depth counters (the parent's are :atomics it keeps mutating; a
    # shared counter would let parent/child race each other's budget). Seed fuel from the parent's
    # remaining budget; depth starts fresh at 0.
    child_fuel = :atomics.new(1, signed: true)
    :atomics.put(child_fuel, 1, :atomics.get(rt.fuel, 1))
    child_depth = :atomics.new(1, signed: true)
    child_rt = %{rt | globals: child_globals, fuel: child_fuel, depth: child_depth, lazy: nil, cps: true}

    spawn(fn ->
      # install the child's PRIVATE run context (copied mem/globals/pages, fresh stdout).
      Process.put(:tl_mem, child_mem)
      Process.put(:tl_globals, child_globals)
      if child_mem_pages, do: Process.put(:tl_mem_pages, child_mem_pages)
      if ctx.max_pages, do: Process.put(:tl_max_pages, ctx.max_pages)
      if ctx.table, do: Process.put(:tl_table, ctx.table)
      if ctx.table_size, do: Process.put(:tl_table_size, ctx.table_size)
      if ctx.last_fuel, do: Process.put(:tl_last_fuel, ctx.last_fuel)
      Process.put(:tl_out, [])
      if ctx.programs, do: Process.put(:tl_programs, ctx.programs)
      if ctx.vfs, do: Process.put(:tl_vfs, ctx.vfs)
      if ctx.fdmap, do: Process.put(:tl_fdmap, ctx.fdmap)
      if ctx.descs, do: Process.put(:tl_descs, ctx.descs)
      if ctx.nextfd, do: Process.put(:tl_nextfd, ctx.nextfd)
      if ctx.nextdesc, do: Process.put(:tl_nextdesc, ctx.nextdesc)
      if ctx.pipes, do: Process.put(:tl_pipes, ctx.pipes)

      if ctx.sockstate do
        Process.put(:tl_sockstate, ctx.sockstate)
        if ctx.socknext, do: Process.put(:tl_socknext, ctx.socknext)
        TinyLasers.Wasm.HostSock.install()
      end

      Process.put(:tl_rt, child_rt)

      # child sees fork()==0: write 0 to the pid-out-ptr in the CHILD's own memory, then resume.
      store(child_mem, ret_pid_ptr, 0, 4)

      {code, output} =
        try do
          tramp(rest, push_res(0, vs2), l, frames, child_rt)
          # ran off the end without an explicit exit → status 0
          {0, child_out()}
        catch
          :throw, {:tl_exit, c} -> {c, child_out()}
        end

      send(parent, {:proc_exited, child_pid, code, output})
    end)

    # PARENT sees fork()==child_pid: write the pid into the parent's memory, resume with errno 0.
    store(parent_mem, ret_pid_ptr, child_pid, 4)
    tramp(rest, push_res(0, vs2), l, frames, rt)
  end

  defp child_out, do: Process.get(:tl_out, []) |> Enum.reverse() |> IO.iodata_to_binary()

  # block: a `br 0` exits to AFTER the block; deeper br decrements and propagates.
  # block: a `br 0` exits to AFTER the block. On exit (br 0 OR fall-through) the stack must be exactly
  # [block-entry ++ `nres` results] — a `br` may legally leave EXTRA operands above that, which the spec
  # DROPS. `keep_arity/3` does the drop (wb-h9ad: a `br` to a void block was leaking the memcmp result).
  defp step({:block, nres, body}, stack, l, rt) do
    entry = length(stack)

    case run(body, stack, l, rt) do
      {:next, s, l} -> {:next, keep_arity(s, entry, nres), l}
      {:br, 0, s, l} -> {:next, keep_arity(s, entry, nres), l}
      {:br, n, s, l} -> {:br, n - 1, s, l}
      {:return, s, l} -> {:return, s, l}
    end
  end

  # loop: a `br 0` jumps to the START (re-run the loop); falling through exits with `nres` results.
  # The back-edge target is the loop ENTRY, which carries the loop's PARAMS — 0 for every non-multivalue
  # loop — so we reset to the entry height (drop any operands the iteration left above it).
  defp step({:loop, nres, body} = loop, stack, l, rt) do
    entry = length(stack)

    case run(body, stack, l, rt) do
      {:next, s, l} -> {:next, keep_arity(s, entry, nres), l}
      {:br, 0, s, l} -> step(loop, keep_arity(s, entry, 0), l, rt)
      {:br, n, s, l} -> {:br, n - 1, s, l}
      {:return, s, l} -> {:return, s, l}
    end
  end

  defp step({:if, nres, then_b, else_b}, [c | stack], l, rt) do
    entry = length(stack)

    case run(if(c != 0, do: then_b, else: else_b), stack, l, rt) do
      {:next, s, l} -> {:next, keep_arity(s, entry, nres), l}
      {:br, 0, s, l} -> {:next, keep_arity(s, entry, nres), l}
      {:br, n, s, l} -> {:br, n - 1, s, l}
      {:return, s, l} -> {:return, s, l}
    end
  end

  # truncate a branch/exit stack to [top `arity` results ++ the `entry_depth` operands below the block],
  # dropping anything in between (operands the spec discards on a branch). No-op for balanced fall-through.
  defp keep_arity(s, entry_depth, arity) do
    Enum.take(s, arity) ++ Enum.drop(s, length(s) - entry_depth)
  end

  # ── Exception handling (exnref proposal, WASIX §0). An exception unwinds the BEAM stack via an Elixir
  # throw `{:wasm_exc, tag, vals}` until a try_table catches a matching tag. exnref = {:exnref, tag, vals}.
  # The catch's label is a br target in the try_table frame (label 0 = exit the try_table), same as block. ──
  defp step({:throw, tagidx}, stack, l, rt) do
    arity = tag_arity(rt, tagidx)
    {vals, _rest} = Enum.split(stack, arity)
    throw({:wasm_exc, tagidx, Enum.reverse(vals)})
  end

  defp step({:throw_ref}, [exnref | _s], l, _rt) do
    case exnref do
      {:exnref, tag, vals} -> throw({:wasm_exc, tag, vals})
      :null -> trap!(:null_exnref)
      _ -> trap!(:not_an_exnref)
    end
    {:next, [], l}
  end

  defp step({:try_table, catches, body}, stack, l, rt) do
    result =
      try do
        run(body, stack, l, rt)
      catch
        :throw, {:wasm_exc, tag, vals} = exc ->
          case match_catch(catches, tag) do
            nil -> throw(exc)
            clause -> {:caught, clause, tag, vals}
          end
      end

    case result do
      {:next, s, l} -> {:next, s, l}
      {:br, 0, s, l} -> {:next, s, l}
      {:br, n, s, l} -> {:br, n - 1, s, l}
      {:return, s, l} -> {:return, s, l}
      {:caught, clause, tag, vals} -> handle_catch(clause, tag, vals, stack, l)
    end
  end

  # legacy try/catch: run the body; on a {:wasm_exc,tag,vals} throw, find the first matching catch (or
  # catch_all) and run its handler with the caught values pushed (mirroring handle_catch). `delegate`
  # re-raises to the enclosing try. The try is a BLOCK for control flow (br 0 exits it; results truncated
  # to nres) — same shape as step({:block,…}). A throw INSIDE a handler escapes this try (handlers run
  # outside the catch). `rethrow` re-raises the exception of the Nth enclosing handler (a process-dict
  # stack of in-flight caught exceptions).
  defp step({:try_legacy, nres, body, clauses, delegate}, stack, l, rt) do
    entry = length(stack)

    outcome =
      try do
        {:fell, run(body, stack, l, rt)}
      catch
        :throw, {:wasm_exc, tag, vals} = exc ->
          if delegate != nil, do: throw(exc)

          case match_legacy(clauses, tag) do
            {:catch, _t, c} -> {:caught, c, Enum.reverse(vals) ++ stack, exc}
            {:catch_all, c} -> {:caught, c, stack, exc}
            nil -> throw(exc)
          end
      end

    finish =
      case outcome do
        {:fell, res} ->
          res

        {:caught, c, cstack, exc} ->
          prev = Process.get(:tl_caught, [])
          Process.put(:tl_caught, [exc | prev])

          try do
            run(c, cstack, l, rt)
          after
            Process.put(:tl_caught, prev)
          end
      end

    case finish do
      {:next, s, l} -> {:next, keep_arity(s, entry, nres), l}
      {:br, 0, s, l} -> {:next, keep_arity(s, entry, nres), l}
      {:br, n, s, l} -> {:br, n - 1, s, l}
      {:return, s, l} -> {:return, s, l}
    end
  end

  defp step({:rethrow, lbl}, _stack, _l, _rt) do
    case Enum.at(Process.get(:tl_caught, []), lbl) do
      nil -> trap!(:rethrow_no_exception)
      exc -> throw(exc)
    end
  end

  defp step({:br, n}, stack, l, _rt), do: {:br, n, stack, l}
  defp step({:br_if, n}, [c | stack], l, _rt), do: if(c != 0, do: {:br, n, stack, l}, else: {:next, stack, l})

  defp step({:br_table, labels, default}, [i | stack], l, _rt) do
    target = if i < length(labels), do: Enum.at(labels, i), else: default
    {:br, target, stack, l}
  end
  defp step({:return}, stack, l, _rt), do: {:return, stack, l}
  defp step({:unreachable}, _stack, _l, _rt), do: trap!(:unreachable)
  defp step({:nop}, stack, l, _rt), do: {:next, stack, l}
  defp step({:drop}, [_ | stack], l, _rt), do: {:next, stack, l}

  defp step({:i64_const, v}, stack, l, _rt), do: {:next, [v | stack], l}

  defp step({:i64_load, o, n, signed}, [a | s], l, rt) do
    v = gload(rt, a + o, n)
    v = if signed, do: sext64(v, n * 8), else: v
    {:next, [v | s], l}
  end

  defp step({:i64_store, o, n}, [v, a | s], l, rt), do: (gstore(rt, a + o, v, n); {:next, s, l})

  defp step({:global_get, i}, stack, l, rt), do: {:next, [gval(:atomics.get(rt.globals, i + 1), elem(rt.gtypes, i)) | stack], l}
  defp step({:global_set, i}, [v | stack], l, rt), do: (:atomics.put(rt.globals, i + 1, gbits(v, elem(rt.gtypes, i))); {:next, stack, l})
  defp step({:i32_const, v}, stack, l, _rt), do: {:next, [v &&& @mask32 | stack], l}
  defp step({:local_get, i}, stack, l, _rt), do: {:next, [elem(l, i) | stack], l}
  defp step({:local_set, i}, [v | stack], l, _rt), do: {:next, stack, put_elem(l, i, v)}
  defp step({:local_tee, i}, [v | _] = stack, l, _rt), do: {:next, stack, put_elem(l, i, v)}

  defp step({:call, f}, stack, l, rt) do
    if Process.get(:tl_callcount_on) do
      c = Process.get(:tl_callcount, %{})
      Process.put(:tl_callcount, Map.update(c, f, 1, &(&1 + 1)))
    end
    {args, stack} = Enum.split(stack, func_arity(rt.mod, f))
    result = call_fn(rt, f, Enum.reverse(args))
    # Push by STATIC result arity (NOT `result == nil`): the asm void tail returns 0 (not nil), so a value
    # test would push a phantom 0 when the interpreter calls an asm void fn (wb-7jwh). Multi-value returns
    # (n>1) arrive as a top-ordered LIST (Porffor's [value,type] pairs) and splice onto the stack.
    {:next, push_results(func_result_arity(rt.mod, f), result, stack), l}
  end

  # Splice a call's result(s) onto the operand stack per result arity: 0 → unchanged, 1 → `[v|stack]`,
  # n>1 → the list `vals` (already top-ordered) prepended.
  defp push_results(0, _result, stack), do: stack
  defp push_results(1, result, stack), do: [result | stack]
  defp push_results(_n, vals, stack) when is_list(vals), do: vals ++ stack

  # ── Reference types + table get/set (WASIX §0). funcref = func index; null = `:null`. The table is
  # mutable, held in `:tl_table` (seeded at run start), so table.set is visible to call_indirect. ──
  defp step({:ref_null}, stack, l, _rt), do: {:next, [:null | stack], l}
  defp step({:ref_is_null}, [r | s], l, _rt), do: {:next, [if(r == :null, do: 1, else: 0) | s], l}
  defp step({:ref_func, i}, stack, l, _rt), do: {:next, [i | stack], l}

  defp step({:table_get}, [i | s], l, rt) do
    {:next, [Map.get(Process.get(:tl_table, rt.table), i, :null) | s], l}
  end

  defp step({:table_set}, [v, i | s], l, rt) do
    Process.put(:tl_table, Map.put(Process.get(:tl_table, rt.table), i, v))
    {:next, s, l}
  end

  defp step({:table_size}, stack, l, rt), do: {:next, [table_size(rt) | stack], l}

  # table.grow(init, n) → old size, or -1 (u32) if it would exceed the declared max. New slots = init.
  defp step({:table_grow}, [n, init | s], l, rt) do
    old = table_size(rt)
    new = old + n
    max = case rt.mod.table_type do {_, m} -> m; _ -> nil end

    if max != nil and new > max do
      {:next, [(-1 &&& @mask32) | s], l}
    else
      table = Enum.reduce(grow_range(old, new), Process.get(:tl_table, rt.table), fn idx, t -> Map.put(t, idx, init) end)
      Process.put(:tl_table, table)
    Process.delete(:tl_table_size)
      Process.put(:tl_table_size, new)
      {:next, [old | s], l}
    end
  end

  defp step({:table_fill}, [n, val, i | s], l, rt) do
    table = Enum.reduce(grow_range(i, i + n), Process.get(:tl_table, rt.table), fn idx, t -> Map.put(t, idx, val) end)
    Process.put(:tl_table, table)
    Process.delete(:tl_table_size)
    {:next, s, l}
  end

  defp step({:table_copy}, [n, src, dst | s], l, rt) do
    table = Process.get(:tl_table, rt.table)
    vals = Enum.map(grow_range(0, n), fn k -> Map.get(table, src + k, :null) end)
    table = vals |> Enum.with_index() |> Enum.reduce(table, fn {v, k}, t -> Map.put(t, dst + k, v) end)
    Process.put(:tl_table, table)
    Process.delete(:tl_table_size)
    {:next, s, l}
  end

  # passive element-segment ops — active elements already loaded the table at start, so these are no-ops
  # in the common case (stack-balanced). table.init pops dst/src/n; elem.drop pops nothing.
  defp step({:table_init}, [_n, _src, _dst | s], l, _rt), do: {:next, s, l}
  defp step({:elem_drop}, stack, l, _rt), do: {:next, stack, l}

  defp step({:call_indirect, typeidx}, [i | stack], l, rt) do
    # spec traps: no/null table entry → :undefined_element; entry's type ≠ the expected type → mismatch.
    f = Map.get(Process.get(:tl_table, rt.table), i)
    if f == :null, do: trap!(:undefined_element)
    if f == nil, do: trap!(:undefined_element)
    expected = Enum.at(rt.mod.types, typeidx)
    if func_type(rt.mod, f) != expected, do: trap!(:indirect_call_type_mismatch)
    if Process.get(:tl_callcount_on) do
      c = Process.get(:tl_callcount, %{})
      Process.put(:tl_callcount, Map.update(c, {:ind, f}, 1, &(&1 + 1)))
    end
    {args, stack} = Enum.split(stack, length(elem(expected, 0)))
    result = call_fn(rt, f, Enum.reverse(args))
    # arity-based push (see {:call, …}), multi-value aware.
    {:next, push_results(length(elem(expected, 1)), result, stack), l}
  end

  defp step({:i32_load, o}, [a | s], l, rt), do: {:next, [gload(rt, a + o, 4) | s], l}
  defp step({:i32_load8u, o}, [a | s], l, rt), do: {:next, [gload(rt, a + o, 1) | s], l}
  defp step({:i32_load8s, o}, [a | s], l, rt), do: {:next, [sext(gload(rt, a + o, 1), 8) | s], l}
  defp step({:i32_load16u, o}, [a | s], l, rt), do: {:next, [gload(rt, a + o, 2) | s], l}
  defp step({:i32_load16s, o}, [a | s], l, rt), do: {:next, [sext(gload(rt, a + o, 2), 16) | s], l}
  defp step({:i32_store, o}, [v, a | s], l, rt), do: (gstore(rt, a + o, v, 4); {:next, s, l})
  defp step({:i32_store8, o}, [v, a | s], l, rt), do: (gstore(rt, a + o, v, 1); {:next, s, l})
  defp step({:i32_store16, o}, [v, a | s], l, rt), do: (gstore(rt, a + o, v, 2); {:next, s, l})

  # ── ATOMICS (WASIX §0). The memory is `:atomics`-backed so single-thread access is naturally atomic;
  # read-modify-write under contention (multiple BEAM "threads" on one shared memory) is the threads
  # milestone (§2). Atomic loads are always zero-extended (unsigned); fence is a no-op on this model. ──
  defp step({:atomic_fence}, stack, l, _rt), do: {:next, stack, l}
  defp step({:atomic_load, o, n}, [a | s], l, rt), do: {:next, [gload(rt, a + o, n) | s], l}
  defp step({:atomic_store, o, n}, [v, a | s], l, rt), do: (gstore(rt, a + o, v, n); {:next, s, l})

  # Atomic RMW / cmpxchg delegate to the SAME word-CAS impl the asm lane uses (guest_atomic_*) — one
  # oracle-shared implementation (DRY). An inline gload+compute+gstore here would be a NON-atomic RMW that
  # loses updates under emulated threads (BEAM procs sharing wmem); the CAS impl is the only correct one.
  @rmw_opc %{add: 0, sub: 1, and: 2, or: 3, xor: 4, xchg: 5}

  defp step({:atomic_rmw, :cmpxchg, o, n}, [repl, expected, a | s], l, _rt) do
    {:next, [guest_atomic_cmpxchg(a + o, expected, repl, n) | s], l}
  end

  defp step({:atomic_rmw, opname, o, n}, [v, a | s], l, _rt) do
    {:next, [guest_atomic_rmw(a + o, v, n, Map.fetch!(@rmw_opc, opname)) | s], l}
  end

  # memory.atomic.notify(addr, count) → woken count (real futex; §2). ONE impl = guest_atomic_notify,
  # shared with the asm lane (AsmOps.Atomics) — DRY, oracle-gated interp≡asm.
  defp step({:atomic_notify, o}, [count, a | s], l, _rt) do
    {:next, [guest_atomic_notify(a + o, count) | s], l}
  end

  # memory.atomic.wait(addr, expected, timeout) → 0 woken / 1 not-equal / 2 timed-out (real futex; §2).
  # ONE impl = guest_atomic_wait (bounded receive on {:wb_wake, addr}); shared with the asm lane.
  defp step({:atomic_wait, n, o}, [timeout, expected, a | s], l, _rt) do
    {:next, [guest_atomic_wait(a + o, expected, n, timeout) | s], l}
  end
  defp step({:memory_size}, stack, l, rt), do: {:next, [:atomics.get(rt.mem_pages, 1) | stack], l}

  defp step({:memory_grow}, [n | s], l, rt) do
    old = :atomics.get(rt.mem_pages, 1)
    new = old + n
    # grow by REALLOCATING a larger packed backing + copying live words, then swap it into the dict.
    # Bounded by the per-run max_pages ceiling so a guest can never OOM the host.
    result =
      cond do
        n < 0 or new > rt.max_pages ->
          -1 &&& @mask32

        # SHARED memory (threads): backing was pre-allocated at max — only bump the page counter so the
        # `:atomics` ref stays stable + shareable across spawned threads. No realloc, no copy.
        Process.get(:tl_mem_shared) ->
          :atomics.put(rt.mem_pages, 1, new)
          old

        true ->
          oldmem = wmem()
          newmem = :atomics.new(new * @page_words, signed: false)
          for i <- 1..(old * @page_words)//1, do: :atomics.put(newmem, i, :atomics.get(oldmem, i))
          Process.put(:tl_mem, newmem)
          :atomics.put(rt.mem_pages, 1, new)
          old
      end

    {:next, [result | s], l}
  end

  # bulk memory: copy n bytes src->dst (overlap-safe); fill n bytes at dst with a byte value
  defp step({:memory_copy}, [n, src, dst | s], l, rt), do: (if n > 0, do: (bounds!(rt, dst, n); bounds!(rt, src, n); mem_copy(wmem(), dst, src, n)); {:next, s, l})
  defp step({:memory_fill}, [n, val, dst | s], l, rt), do: (if n > 0, do: bounds!(rt, dst, n); for(i <- 0..(n - 1)//1, do: store(wmem(), dst + i, val, 1)); {:next, s, l})
  defp step({:data_drop}, stack, l, _rt), do: {:next, stack, l}

  # memory.init(dst, src, n): copy n bytes from data segment `dataidx` (at src) into memory (at dst).
  # OOB on either side traps; n=0 is a no-op. Closes the last §0 bulk-memory gap.
  defp step({:memory_init, dataidx}, [n, src, dst | s], l, rt) do
    bytes =
      case Enum.at(rt.mod.data, dataidx) do
        {:passive, b} -> b
        {:active, _o, b} -> b
        _ -> <<>>
      end

    if n > 0 do
      if src + n > byte_size(bytes), do: trap!(:out_of_bounds_data)
      bounds!(rt, dst, n)
      for i <- 0..(n - 1)//1, do: store(wmem(), dst + i, :binary.at(bytes, src + i), 1)
    end

    {:next, s, l}
  end
  defp step({:trunc_sat, n}, [a | s], l, _rt) do
    {lo, hi, mask} = trunc_sat_range(n)
    {:next, [(sat_trunc(a, lo, hi) &&& mask) | s], l}
  end

  # floats live on the stack as BEAM floats (heterogeneous w/ ints — validation keeps types correct).
  defp step({:fconst, v}, stack, l, _rt), do: {:next, [v | stack], l}
  defp step({:f32_load, o}, [a | s], l, rt), do: {:next, [gfload(rt, a + o, 4) | s], l}
  defp step({:f64_load, o}, [a | s], l, rt), do: {:next, [gfload(rt, a + o, 8) | s], l}
  defp step({:f32_store, o}, [v, a | s], l, rt), do: (gfstore(rt, a + o, v, 4); {:next, s, l})
  defp step({:f64_store, o}, [v, a | s], l, rt), do: (gfstore(rt, a + o, v, 8); {:next, s, l})

  # v128 values live on the stack as 16-byte binaries.
  defp step({:simd, 0, off}, [a | s], l, rt), do: {:next, [gvload(rt, a + off) | s], l}      # v128.load
  defp step({:simd, 11, off}, [v, a | s], l, rt), do: (gvstore(rt, a + off, v); {:next, s, l})  # v128.store
  defp step({:simd, 12, c}, s, l, _rt), do: {:next, [c | s], l}                                   # v128.const
  # Bitwise v128 ops — the only SIMD Porffor emits, in the string-equality fast path (builtins/string.ts
  # __Porffor_strcmp: load two 16-byte chunks, `xor`, `or`-reduce, `any_true` to detect a differing byte).
  # v128 values are 16-byte binaries; the ops are byte/bit-wise so decoding the whole 16 bytes as one 128-bit
  # integer is endian-agnostic (both operands decode identically, the result re-encodes identically). xor/or
  # are commutative so the `[b, a | s]` pop order is irrelevant.
  defp step({:simd, 80, _imm}, [<<b::128>>, <<a::128>> | s], l, _rt), do: {:next, [<<bor(a, b)::128>> | s], l}   # v128.or
  defp step({:simd, 81, _imm}, [<<b::128>>, <<a::128>> | s], l, _rt), do: {:next, [<<bxor(a, b)::128>> | s], l}  # v128.xor
  defp step({:simd, 83, _imm}, [<<v::128>> | s], l, _rt), do: {:next, [(if v == 0, do: 0, else: 1) | s], l}      # v128.any_true (1 iff any bit set)
  defp step({:simd, sub, _imm}, _stack, _l, _rt), do: raise("tinylasers: unimplemented SIMD op 0xFD #{sub}")
  defp step({:op, op}, stack, l, _rt), do: {:next, binop(op, stack), l}

  # ── pure stack ops: arithmetic + comparisons. `[b, a | s]` — a pushed first, b on top. ──
  defp binop(0x1B, [c, b, a | s]), do: [if(c != 0, do: a, else: b) | s]             # select
  defp binop(0x67, [a | s]), do: [clz(a, 32) | s]                                   # i32.clz
  defp binop(0x68, [a | s]), do: [ctz(a, 32) | s]                                   # i32.ctz
  defp binop(0x69, [a | s]), do: [pop(a) | s]                                       # i32.popcnt
  defp binop(0x6A, [b, a | s]), do: [(a + b) &&& @mask32 | s]                       # i32.add
  defp binop(0x6B, [b, a | s]), do: [(a - b) &&& @mask32 | s]                       # i32.sub
  defp binop(0x6C, [b, a | s]), do: [(a * b) &&& @mask32 | s]                       # i32.mul
  defp binop(0x6D, [b, a | s]), do: [idiv(s32(a), s32(b), -0x80000000) &&& @mask32 | s]  # i32.div_s
  defp binop(0x6E, [b, a | s]), do: [udiv(a, b) &&& @mask32 | s]                     # i32.div_u
  defp binop(0x6F, [b, a | s]), do: [irem(s32(a), s32(b)) &&& @mask32 | s]           # i32.rem_s
  defp binop(0x70, [b, a | s]), do: [urem(a, b) &&& @mask32 | s]                     # i32.rem_u
  defp binop(0x71, [b, a | s]), do: [a &&& b | s]                                   # i32.and
  defp binop(0x72, [b, a | s]), do: [a ||| b | s]                                   # i32.or
  defp binop(0x73, [b, a | s]), do: [bxor(a, b) | s]                                # i32.xor
  defp binop(0x74, [b, a | s]), do: [(a <<< (b &&& 31)) &&& @mask32 | s]            # i32.shl
  defp binop(0x75, [b, a | s]), do: [(s32(a) >>> (b &&& 31)) &&& @mask32 | s]       # i32.shr_s
  defp binop(0x76, [b, a | s]), do: [a >>> (b &&& 31) | s]                          # i32.shr_u
  defp binop(0x77, [b, a | s]), do: [rotl32(a, b &&& 31) | s]                       # i32.rotl
  defp binop(0x78, [b, a | s]), do: [rotr32(a, b &&& 31) | s]                       # i32.rotr
  defp binop(0x45, [a | s]), do: [bool(a == 0) | s]                                 # i32.eqz
  defp binop(0x46, [b, a | s]), do: [bool(a == b) | s]                              # i32.eq
  defp binop(0x47, [b, a | s]), do: [bool(a != b) | s]                              # i32.ne
  defp binop(0x48, [b, a | s]), do: [bool(s32(a) < s32(b)) | s]                     # i32.lt_s
  defp binop(0x49, [b, a | s]), do: [bool(a < b) | s]                               # i32.lt_u
  defp binop(0x4A, [b, a | s]), do: [bool(s32(a) > s32(b)) | s]                     # i32.gt_s
  defp binop(0x4B, [b, a | s]), do: [bool(a > b) | s]                               # i32.gt_u
  defp binop(0x4C, [b, a | s]), do: [bool(s32(a) <= s32(b)) | s]                    # i32.le_s
  defp binop(0x4D, [b, a | s]), do: [bool(a <= b) | s]                              # i32.le_u
  defp binop(0x4E, [b, a | s]), do: [bool(s32(a) >= s32(b)) | s]                    # i32.ge_s
  defp binop(0x4F, [b, a | s]), do: [bool(a >= b) | s]                              # i32.ge_u
  # ── f32 (round results to single precision) ──
  defp binop(0x8B, [a | s]), do: [fabs(a, 32) | s]                                  # f32.abs
  defp binop(0x8C, [a | s]), do: [fneg(a, 32) | s]                                  # f32.neg
  defp binop(0x91, [a | s]), do: [fsqrt(a, 32) | s]                                 # f32.sqrt
  defp binop(0x92, [b, a | s]), do: [farith(a, b, :add, 32) | s]                    # f32.add
  defp binop(0x93, [b, a | s]), do: [farith(a, b, :sub, 32) | s]                    # f32.sub
  defp binop(0x94, [b, a | s]), do: [farith(a, b, :mul, 32) | s]                    # f32.mul
  defp binop(0x95, [b, a | s]), do: [farith(a, b, :div, 32) | s]                    # f32.div
  defp binop(0x96, [b, a | s]), do: [fminmax(a, b, :min, 32) | s]                   # f32.min
  defp binop(0x97, [b, a | s]), do: [fminmax(a, b, :max, 32) | s]                   # f32.max
  defp binop(0x8B, [a | s]), do: [f32r(abs(a)) | s]                                 # f32.abs
  defp binop(0x8C, [a | s]), do: [f32r(-a) | s]                                     # f32.neg
  defp binop(0x8D, [a | s]), do: [fround_unary(a, 32, &Float.ceil/1) | s]           # f32.ceil
  defp binop(0x8E, [a | s]), do: [fround_unary(a, 32, &Float.floor/1) | s]          # f32.floor
  defp binop(0x8F, [a | s]), do: [fround_unary(a, 32, fn x -> trunc(x) * 1.0 end) | s]  # f32.trunc
  defp binop(0x90, [a | s]), do: [fround_unary(a, 32, &fnearest/1) | s]             # f32.nearest
  defp binop(0x91, [a | s]), do: [f32r(:math.sqrt(a)) | s]                          # f32.sqrt
  defp binop(0x98, [b, a | s]), do: [fcopysign_nf(a, b, 32) | s]                    # f32.copysign
  defp binop(0x5B, [b, a | s]), do: [bool(fcmp(a, b, :eq)) | s]                      # f32.eq
  defp binop(0x5C, [b, a | s]), do: [bool(fcmp(a, b, :ne)) | s]                      # f32.ne
  defp binop(0x5D, [b, a | s]), do: [bool(fcmp(a, b, :lt)) | s]                      # f32.lt
  defp binop(0x5E, [b, a | s]), do: [bool(fcmp(a, b, :gt)) | s]                      # f32.gt
  defp binop(0x5F, [b, a | s]), do: [bool(fcmp(a, b, :le)) | s]                      # f32.le
  defp binop(0x60, [b, a | s]), do: [bool(fcmp(a, b, :ge)) | s]                      # f32.ge
  # ── f64 ──
  defp binop(0x99, [a | s]), do: [fabs(a, 64) | s]                                  # f64.abs
  defp binop(0x9A, [a | s]), do: [fneg(a, 64) | s]                                  # f64.neg
  defp binop(0x9F, [a | s]), do: [fsqrt(a, 64) | s]                                 # f64.sqrt
  defp binop(0xA0, [b, a | s]), do: [farith(a, b, :add, 64) | s]                    # f64.add
  defp binop(0xA1, [b, a | s]), do: [farith(a, b, :sub, 64) | s]                    # f64.sub
  defp binop(0xA2, [b, a | s]), do: [farith(a, b, :mul, 64) | s]                    # f64.mul
  defp binop(0xA3, [b, a | s]), do: [farith(a, b, :div, 64) | s]                    # f64.div
  defp binop(0xA4, [b, a | s]), do: [fminmax(a, b, :min, 64) | s]                   # f64.min
  defp binop(0xA5, [b, a | s]), do: [fminmax(a, b, :max, 64) | s]                   # f64.max
  defp binop(0x9B, [a | s]), do: [fround_unary(a, 64, &Float.ceil/1) | s]           # f64.ceil
  defp binop(0x9C, [a | s]), do: [fround_unary(a, 64, &Float.floor/1) | s]          # f64.floor
  defp binop(0x9D, [a | s]), do: [fround_unary(a, 64, fn x -> trunc(x) * 1.0 end) | s]  # f64.trunc
  defp binop(0x9E, [a | s]), do: [fround_unary(a, 64, &fnearest/1) | s]             # f64.nearest
  defp binop(0xA6, [b, a | s]), do: [fcopysign_nf(a, b, 64) | s]                    # f64.copysign
  defp binop(0x61, [b, a | s]), do: [bool(fcmp(a, b, :eq)) | s]                      # f64.eq
  defp binop(0x62, [b, a | s]), do: [bool(fcmp(a, b, :ne)) | s]                      # f64.ne
  defp binop(0x63, [b, a | s]), do: [bool(fcmp(a, b, :lt)) | s]                      # f64.lt
  defp binop(0x64, [b, a | s]), do: [bool(fcmp(a, b, :gt)) | s]                      # f64.gt
  defp binop(0x65, [b, a | s]), do: [bool(fcmp(a, b, :le)) | s]                      # f64.le
  defp binop(0x66, [b, a | s]), do: [bool(fcmp(a, b, :ge)) | s]                      # f64.ge
  # ── conversions (i32 ⇄ f32/f64) ──
  defp binop(0xA8, [a | s]), do: [ftrunc(a, -0x80000000, 0x7FFFFFFF) &&& @mask32 | s]  # i32.trunc_f32_s
  defp binop(0xA9, [a | s]), do: [ftrunc(a, 0, 0xFFFFFFFF) &&& @mask32 | s]             # i32.trunc_f32_u
  defp binop(0xAA, [a | s]), do: [ftrunc(a, -0x80000000, 0x7FFFFFFF) &&& @mask32 | s]  # i32.trunc_f64_s
  defp binop(0xAB, [a | s]), do: [ftrunc(a, 0, 0xFFFFFFFF) &&& @mask32 | s]             # i32.trunc_f64_u
  defp binop(0xB2, [a | s]), do: [f32r(s32(a) * 1.0) | s]                           # f32.convert_i32_s
  defp binop(0xB3, [a | s]), do: [f32r(a * 1.0) | s]                                # f32.convert_i32_u
  defp binop(0xB6, [a | s]), do: [f32r(a) | s]                                      # f32.demote_f64
  defp binop(0xB7, [a | s]), do: [s32(a) * 1.0 | s]                                 # f64.convert_i32_s
  defp binop(0xB8, [a | s]), do: [a * 1.0 | s]                                      # f64.convert_i32_u
  defp binop(0xBB, [a | s]), do: [a * 1.0 | s]                                      # f64.promote_f32
  # reinterpret = same bits, different type (no value change). decode_f handles non-finite bit patterns.
  defp binop(0xBC, [a | s]), do: [reinterpret_to_i(a, 32) | s]                      # i32.reinterpret_f32
  defp binop(0xBD, [a | s]), do: [reinterpret_to_i(a, 64) | s]                      # i64.reinterpret_f64
  defp binop(0xBE, [a | s]), do: [decode_f(a &&& @mask32, 32) | s]                  # f32.reinterpret_i32
  defp binop(0xBF, [a | s]), do: [decode_f(a &&& @mask64, 64) | s]                  # f64.reinterpret_i64
  defp binop(0xBC, [a | s]), do: [(<<i::32-little>> = <<a::float-32-little>>; i) | s]  # i32.reinterpret_f32
  defp binop(0xBE, [a | s]), do: [(<<f::float-32-little>> = <<a::32-little>>; f) | s]  # f32.reinterpret_i32

  # ── i64 (BEAM integers masked to 64 bits) ──
  defp binop(0x50, [a | s]), do: [bool(a == 0) | s]                                 # i64.eqz
  defp binop(0x51, [b, a | s]), do: [bool(a == b) | s]                             # i64.eq
  defp binop(0x52, [b, a | s]), do: [bool(a != b) | s]                             # i64.ne
  defp binop(0x53, [b, a | s]), do: [bool(s64(a) < s64(b)) | s]                    # i64.lt_s
  defp binop(0x54, [b, a | s]), do: [bool(a < b) | s]                              # i64.lt_u
  defp binop(0x55, [b, a | s]), do: [bool(s64(a) > s64(b)) | s]                    # i64.gt_s
  defp binop(0x56, [b, a | s]), do: [bool(a > b) | s]                              # i64.gt_u
  defp binop(0x57, [b, a | s]), do: [bool(s64(a) <= s64(b)) | s]                   # i64.le_s
  defp binop(0x58, [b, a | s]), do: [bool(a <= b) | s]                             # i64.le_u
  defp binop(0x59, [b, a | s]), do: [bool(s64(a) >= s64(b)) | s]                   # i64.ge_s
  defp binop(0x5A, [b, a | s]), do: [bool(a >= b) | s]                             # i64.ge_u
  defp binop(0x79, [a | s]), do: [clz(a, 64) | s]                                  # i64.clz
  defp binop(0x7A, [a | s]), do: [ctz(a, 64) | s]                                  # i64.ctz
  defp binop(0x7B, [a | s]), do: [pop(a) | s]                                      # i64.popcnt
  defp binop(0x7C, [b, a | s]), do: [(a + b) &&& @mask64 | s]                       # i64.add
  defp binop(0x7D, [b, a | s]), do: [(a - b) &&& @mask64 | s]                       # i64.sub
  defp binop(0x7E, [b, a | s]), do: [(a * b) &&& @mask64 | s]                       # i64.mul
  defp binop(0x7F, [b, a | s]), do: [idiv(s64(a), s64(b), -0x8000000000000000) &&& @mask64 | s]  # i64.div_s
  defp binop(0x80, [b, a | s]), do: [udiv(a, b) &&& @mask64 | s]                     # i64.div_u
  defp binop(0x81, [b, a | s]), do: [irem(s64(a), s64(b)) &&& @mask64 | s]           # i64.rem_s
  defp binop(0x82, [b, a | s]), do: [urem(a, b) &&& @mask64 | s]                     # i64.rem_u
  defp binop(0x83, [b, a | s]), do: [a &&& b | s]                                   # i64.and
  defp binop(0x84, [b, a | s]), do: [a ||| b | s]                                   # i64.or
  defp binop(0x85, [b, a | s]), do: [bxor(a, b) | s]                                # i64.xor
  defp binop(0x86, [b, a | s]), do: [(a <<< (b &&& 63)) &&& @mask64 | s]            # i64.shl
  defp binop(0x87, [b, a | s]), do: [(s64(a) >>> (b &&& 63)) &&& @mask64 | s]       # i64.shr_s
  defp binop(0x88, [b, a | s]), do: [a >>> (b &&& 63) | s]                          # i64.shr_u
  defp binop(0x89, [b, a | s]), do: [rotl64(a, b &&& 63) | s]                       # i64.rotl
  defp binop(0x8A, [b, a | s]), do: [rotr64(a, b &&& 63) | s]                       # i64.rotr
  # conversions involving i64
  defp binop(0xA7, [a | s]), do: [a &&& @mask32 | s]                                # i32.wrap_i64
  defp binop(0xAC, [a | s]), do: [sext64(a, 32) | s]                               # i64.extend_i32_s
  defp binop(0xAD, [a | s]), do: [a &&& @mask64 | s]                               # i64.extend_i32_u
  defp binop(0xB0, [a | s]), do: [ftrunc(a, -0x8000000000000000, 0x7FFFFFFFFFFFFFFF) &&& @mask64 | s]  # i64.trunc_f64_s
  defp binop(0xB1, [a | s]), do: [ftrunc(a, 0, 0xFFFFFFFFFFFFFFFF) &&& @mask64 | s]                     # i64.trunc_f64_u

  # non-saturating float→int truncation: traps on NaN/Inf (non-finite, a {:nonfinite,_,_} stack value)
  # and on out-of-range — exactly the spec's "invalid conversion" / "integer overflow" traps.
  defp ftrunc(a, lo, hi) when is_float(a) do
    t = trunc(a)
    if t < lo or t > hi, do: trap!(:conversion_overflow), else: t
  end

  defp ftrunc(_a, _lo, _hi), do: trap!(:invalid_conversion)
  defp binop(0xB9, [a | s]), do: [s64(a) * 1.0 | s]                                 # f64.convert_i64_s
  defp binop(0xBA, [a | s]), do: [a * 1.0 | s]                                      # f64.convert_i64_u

  # sign-extension ops (within a type)
  defp binop(0xC0, [a | s]), do: [sext(a &&& 0xFF, 8) | s]                          # i32.extend8_s
  defp binop(0xC1, [a | s]), do: [sext(a &&& 0xFFFF, 16) | s]                       # i32.extend16_s
  defp binop(0xC2, [a | s]), do: [sext64(a &&& 0xFF, 8) | s]                        # i64.extend8_s
  defp binop(0xC3, [a | s]), do: [sext64(a &&& 0xFFFF, 16) | s]                     # i64.extend16_s
  defp binop(0xC4, [a | s]), do: [sext64(a &&& @mask32, 32) | s]                    # i64.extend32_s

  defp binop(op, _), do: raise("tinylasers: unimplemented stack op 0x#{Integer.to_string(op, 16)}")

  defp s64(x) when x >= 0x8000000000000000, do: x - 0x10000000000000000
  defp s64(x), do: x
  defp sext64(v, bits) when v >= 1 <<< (bits - 1), do: (v - (1 <<< bits)) &&& @mask64
  defp sext64(v, _bits), do: v

  # round a double to f32 precision (pack→unpack as 32-bit IEEE-754). NB: raises on NaN/Inf (refine later).
  # round to single precision; an f32-overflowing magnitude becomes ±Inf (decode_f → {:nonfinite,_,32})
  # rather than raising on the (non-finite) bit pattern.
  defp f32r({:nonfinite, _, _} = x), do: x
  defp f32r(x), do: decode_f(:binary.decode_unsigned(<<x::float-32-little>>, :little), 32)

  # round to nearest integer, ties to EVEN (wasm f.nearest), as a float
  defp fnearest(a) do
    f = Float.floor(a)
    case a - f do
      d when d < 0.5 -> f
      d when d > 0.5 -> f + 1.0
      _ -> if rem(trunc(f), 2) == 0, do: f, else: f + 1.0
    end
  end

  # magnitude of `a`, sign of `b` (signed-zero edge ignored — BEAM has no -0.0 distinction here)
  defp fcopysign(a, b), do: if(b < 0, do: -abs(a), else: abs(a))

  # non-finite-safe rounding ops: ceil/floor/trunc/nearest of ±Inf = ±Inf, of NaN = NaN; finite via `f`.
  defp fround_unary(a, size, f) do
    case fclass(a) do
      {:fin, x} -> fround(f.(x), size)
      {:inf, s} -> finf(size, s)
      :nan -> fnan(size)
    end
  end

  # copysign with non-finite operands: magnitude of `a` (incl. Inf/NaN) carrying the sign of `b`.
  defp fcopysign_nf(a, b, size) do
    bsign = case fclass(b) do
      {:inf, s} -> s
      {:fin, y} -> if(y < 0.0, do: -1, else: 1)
      :nan -> 1
    end

    case fclass(a) do
      {:fin, x} -> fround(if(bsign < 0, do: -abs(x), else: abs(x)), size)
      {:inf, _} -> finf(size, bsign)
      :nan -> fnan(size)
    end
  end

  # decode raw IEEE-754 bits → a BEAM float when finite, else a non-finite placeholder (BEAM has no NaN/Inf)
  # a float's raw bit pattern as an unsigned integer (non-finite floats are carried as {:nonfinite, bits, _})
  defp reinterpret_to_i({:nonfinite, bits, _}, _size), do: bits
  defp reinterpret_to_i(a, 32) when is_float(a), do: (<<i::32-little>> = <<a::float-32-little>>; i)
  defp reinterpret_to_i(a, 64) when is_float(a), do: (<<i::64-little>> = <<a::float-64-little>>; i)

  defp decode_f(bits, size) do
    bin = <<bits::size(size)-little>>

    try do
      case size do
        32 -> <<f::float-32-little>> = bin; f
        64 -> <<f::float-64-little>> = bin; f
      end
    rescue
      _ -> {:nonfinite, bits, size}
    end
  end

  # FAST PATH: a word-aligned 4/8-byte float access is a single `:atomics` op + a binary reinterpret,
  # instead of the per-byte mget/mput loop (which re-reads the SAME backing word up to 8×). The backing
  # is `signed: false` 8-byte slots (see `load/3` above), so a bare `get` yields the full 64-bit LE
  # pattern — `decode_f` reinterprets it bit-identically to the byte loop's `decode_unsigned` result.
  defp fload(mem, addr, 8) when (addr &&& 7) == 0 do
    decode_f(:atomics.get(mem, (addr >>> 3) + 1) &&& @mask64, 64)
  end

  defp fload(mem, addr, 4) when (addr &&& 7) == 0 do
    decode_f(:atomics.get(mem, (addr >>> 3) + 1) &&& 0xFFFFFFFF, 32)
  end

  defp fload(mem, addr, 4) when (addr &&& 7) == 4 do
    decode_f((:atomics.get(mem, (addr >>> 3) + 1) >>> 32) &&& 0xFFFFFFFF, 32)
  end

  defp fload(mem, addr, n) do
    bin = for(i <- 0..(n - 1)//1, do: mget(mem, addr + i)) |> :erlang.list_to_binary()
    # decode via the bit pattern so non-finite values (±Inf/NaN) survive as {:nonfinite, bits, size}
    decode_f(:binary.decode_unsigned(bin, :little), n * 8)
  end

  # the LE integer bit-pattern of a float value (finite float OR {:nonfinite, bits, size}).
  defp fbits({:nonfinite, bits, _}, _n), do: bits
  defp fbits(v, 4), do: <<v::float-32-little>> |> :binary.decode_unsigned(:little)
  defp fbits(v, 8), do: <<v::float-64-little>> |> :binary.decode_unsigned(:little)

  defp fstore(mem, addr, v, 8) when (addr &&& 7) == 0 do
    :atomics.put(mem, (addr >>> 3) + 1, fbits(v, 8) &&& @mask64)
    :ok
  end

  defp fstore(mem, addr, v, 4) when (addr &&& 7) == 0 do
    idx = (addr >>> 3) + 1
    w = :atomics.get(mem, idx)
    :atomics.put(mem, idx, ((w &&& bnot(0xFFFFFFFF)) ||| (fbits(v, 4) &&& 0xFFFFFFFF)) &&& @mask64)
    :ok
  end

  defp fstore(mem, addr, v, 4) when (addr &&& 7) == 4 do
    idx = (addr >>> 3) + 1
    w = :atomics.get(mem, idx)
    :atomics.put(mem, idx, ((w &&& 0xFFFFFFFF) ||| ((fbits(v, 4) &&& 0xFFFFFFFF) <<< 32)) &&& @mask64)
    :ok
  end

  defp fstore(mem, addr, v, n) do
    bin =
      case v do
        {:nonfinite, bits, _} -> <<bits::size(n * 8)-little>>
        _ when n == 4 -> <<v::float-32-little>>
        _ -> <<v::float-64-little>>
      end

    bin |> :binary.bin_to_list() |> Enum.with_index() |> Enum.each(fn {b, i} -> mput(mem, addr + i, b) end)
  end

  # ── IEEE-754 special-value arithmetic (wb-8mdz.3) ────────────────────────────────────────────────
  # BEAM floats cannot represent ±Inf/NaN/-0; finite values stay Elixir floats, non-finite ones are
  # carried as {:nonfinite, bits, size} (the same shape decode_f / reinterpret already use). Every float
  # op routes through these so a div-by-zero / overflow / sqrt(-1) yields the right special instead of
  # raising ArithmeticError.
  @inf_bits %{64 => 0x7FF0000000000000, 32 => 0x7F800000}
  @ninf_bits %{64 => 0xFFF0000000000000, 32 => 0xFF800000}
  @nan_bits %{64 => 0x7FF8000000000000, 32 => 0x7FC00000}

  defp finf(size, 1), do: {:nonfinite, @inf_bits[size], size}
  defp finf(size, -1), do: {:nonfinite, @ninf_bits[size], size}
  defp fnan(size), do: {:nonfinite, @nan_bits[size], size}

  # classify an operand into {:fin, float} | {:inf, +1|-1} | :nan
  defp fclass(x) when is_float(x), do: {:fin, x}
  # An uninitialized f64/f32 local zero-inits to the integer 0 (locals carry no per-type zero), so a float
  # op can see an integer operand. Coerce it: an integer N in an f64 op IS the float N (and 0 -> 0.0).
  defp fclass(x) when is_integer(x), do: {:fin, x * 1.0}
  # An uninitialized f64/f32 local zero-inits to the integer 0 (locals carry no per-type zero), so a float
  # op can see an integer operand. Coerce it: an integer N in an f64 op IS the float N (and 0 → 0.0).
  defp fclass(x) when is_integer(x), do: {:fin, x * 1.0}

  defp fclass({:nonfinite, bits, size}) do
    {ew, mmask} = if size == 64, do: {0x7FF, 0xFFFFFFFFFFFFF}, else: {0xFF, 0x7FFFFF}
    sbit = if size == 64, do: 63, else: 31
    ebit = if size == 64, do: 52, else: 23
    exp = (bits >>> ebit) &&& ew
    mant = bits &&& mmask
    sign = if ((bits >>> sbit) &&& 1) == 1, do: -1, else: 1

    cond do
      exp == ew and mant == 0 -> {:inf, sign}
      exp == ew -> :nan
      true -> {:fin, decode_f(bits, size)}
    end
  end

  defp fsignf(x) when is_float(x), do: if(x < 0.0, do: -1, else: 1)
  defp fround(r, 32), do: f32r(r)
  defp fround(r, 64), do: r

  defp farith(a, b, op, size) do
    case {fclass(a), fclass(b)} do
      {:nan, _} -> fnan(size)
      {_, :nan} -> fnan(size)
      {ca, cb} -> farith2(ca, cb, op, size)
    end
  end

  defp farith2({:fin, x}, {:fin, y}, op, size) do
    try do
      fround(
        case op do
          :add -> x + y
          :sub -> x - y
          :mul -> x * y
          :div -> x / y
        end,
        size
      )
    rescue
      ArithmeticError ->
        # div-by-zero or overflow → the IEEE special with the correct sign
        case op do
          :div -> if x == 0.0, do: fnan(size), else: finf(size, fsignf(x) * fsignf(y))
          :mul -> finf(size, fsignf(x) * fsignf(y))
          _ -> finf(size, fsignf(x))
        end
    end
  end

  defp farith2({:inf, sa}, {:inf, sb}, op, size) do
    case op do
      :add -> if sa == sb, do: finf(size, sa), else: fnan(size)
      :sub -> if sa != sb, do: finf(size, sa), else: fnan(size)
      :mul -> finf(size, sa * sb)
      :div -> fnan(size)
    end
  end

  defp farith2({:inf, sa}, {:fin, y}, op, size) do
    case op do
      :mul -> if y == 0.0, do: fnan(size), else: finf(size, sa * fsignf(y))
      :div -> finf(size, sa * fsignf(y))
      _ -> finf(size, sa)
    end
  end

  defp farith2({:fin, x}, {:inf, sb}, op, size) do
    case op do
      :add -> finf(size, sb)
      :sub -> finf(size, -sb)
      :mul -> if x == 0.0, do: fnan(size), else: finf(size, fsignf(x) * sb)
      :div -> fround(0.0, size)
    end
  end

  # comparisons — NaN is unordered (only `ne` is true); otherwise a 3-way compare over the classified forms
  # (±Inf handled explicitly, since Elixir term order would mis-rank a float vs an atom sentinel).
  defp fcmp(a, b, op) do
    ca = fclass(a)
    cb = fclass(b)

    if ca == :nan or cb == :nan do
      op == :ne
    else
      c = fcompare(ca, cb)

      case op do
        :eq -> c == 0
        :ne -> c != 0
        :lt -> c < 0
        :gt -> c > 0
        :le -> c <= 0
        :ge -> c >= 0
      end
    end
  end

  defp fcompare({:fin, x}, {:fin, y}), do: cond(do: (x < y -> -1; x > y -> 1; true -> 0))
  defp fcompare({:inf, s}, {:inf, t}), do: cond(do: (s == t -> 0; s < t -> -1; true -> 1))
  defp fcompare({:inf, 1}, _), do: 1
  defp fcompare({:inf, -1}, _), do: -1
  defp fcompare(_, {:inf, 1}), do: -1
  defp fcompare(_, {:inf, -1}), do: 1

  defp fminmax(a, b, which, size) do
    case {fclass(a), fclass(b)} do
      {:nan, _} -> fnan(size)
      {_, :nan} -> fnan(size)
      _ -> if fcmp(a, b, if(which == :min, do: :le, else: :ge)), do: a, else: b
    end
  end

  defp fabs(a, size) do
    case fclass(a) do
      {:fin, x} -> fround(abs(x), size)
      {:inf, _} -> finf(size, 1)
      :nan -> fnan(size)
    end
  end

  defp fneg(a, size) do
    case fclass(a) do
      {:fin, x} -> fround(-x, size)
      {:inf, s} -> finf(size, -s)
      :nan -> fnan(size)
    end
  end

  defp fsqrt(a, size) do
    case fclass(a) do
      {:fin, x} when x < 0.0 -> fnan(size)
      {:fin, x} -> fround(:math.sqrt(x), size)
      {:inf, 1} -> finf(size, 1)
      {:inf, -1} -> fnan(size)
      :nan -> fnan(size)
    end
  end

  # copy n bytes within memory, src->dst, overlap-safe (forward when dst<=src, else backward)
  defp mem_copy(mem, dst, src, n) when dst <= src,
    do: for(i <- 0..(n - 1)//1, do: mput(mem, dst + i, mget(mem, src + i)))

  defp mem_copy(mem, dst, src, n),
    do: for(i <- (n - 1)..0//-1, do: mput(mem, dst + i, mget(mem, src + i)))

  # saturating float→int truncation: NaN→0, else truncate (simple; clamp edges refined later)
  # Saturating float→int (i32.trunc_sat_* / i64.trunc_sat_*, opcode 0xFC n). Unlike the trapping `ftrunc`,
  # this NEVER traps: NaN→0, +Inf→hi, -Inf→lo, finite→trunc-then-clamp to [lo,hi]. Result is masked to the
  # destination width by the caller. `n` selects width+signedness (0..3 → i32, 4..7 → i64; even=signed).
  defp trunc_sat_range(n) when n in [0, 2], do: {-0x80000000, 0x7FFFFFFF, @mask32}
  defp trunc_sat_range(n) when n in [1, 3], do: {0, 0xFFFFFFFF, @mask32}
  defp trunc_sat_range(n) when n in [4, 6], do: {-0x8000000000000000, 0x7FFFFFFFFFFFFFFF, @mask64}
  defp trunc_sat_range(n) when n in [5, 7], do: {0, 0xFFFFFFFFFFFFFFFF, @mask64}

  defp sat_trunc(a, lo, hi) when is_float(a) do
    t = trunc(a)
    cond do
      t < lo -> lo
      t > hi -> hi
      true -> t
    end
  end

  defp sat_trunc({:nonfinite, bits, width}, lo, hi) do
    {exp_mask, mant_mask, sign_bit} =
      if width == 64,
        do: {0x7FF0000000000000, 0x000FFFFFFFFFFFFF, 0x8000000000000000},
        else: {0x7F800000, 0x007FFFFF, 0x80000000}

    cond do
      (bits &&& exp_mask) == exp_mask and (bits &&& mant_mask) != 0 -> 0      # NaN → 0
      (bits &&& sign_bit) != 0 -> lo                                          # -Inf → lo
      true -> hi                                                              # +Inf → hi
    end
  end

  defp sat_trunc(a, lo, hi) when is_integer(a), do: a |> max(lo) |> min(hi)

  defp bool(true), do: 1
  defp bool(false), do: 0
  defp s32(x) when x >= 0x80000000, do: x - 0x100000000
  defp s32(x), do: x

  # sign-extend an n-bit value to the 32-bit unsigned representation
  defp sext(v, bits) do
    if v >= 1 <<< (bits - 1), do: (v - (1 <<< bits)) &&& @mask32, else: v
  end

  defp rotl32(a, 0), do: a
  defp rotl32(a, n), do: ((a <<< n) ||| (a >>> (32 - n))) &&& @mask32
  defp rotr32(a, 0), do: a
  defp rotr32(a, n), do: ((a >>> n) ||| (a <<< (32 - n))) &&& @mask32
  defp rotl64(a, 0), do: a
  defp rotl64(a, n), do: ((a <<< n) ||| (a >>> (64 - n))) &&& @mask64
  defp rotr64(a, 0), do: a
  defp rotr64(a, n), do: ((a >>> n) ||| (a <<< (64 - n))) &&& @mask64

  # precise bit-length (no float imprecision) → clz; ctz/pop by scanning bits
  defp bitlen(a, acc \\ 0)
  defp bitlen(0, acc), do: acc
  defp bitlen(a, acc), do: bitlen(a >>> 1, acc + 1)
  defp clz(a, bits), do: bits - bitlen(a)
  defp ctz(0, bits), do: bits
  defp ctz(a, _bits), do: ctz_(a, 0)
  defp ctz_(a, n), do: if((a &&& 1) == 1, do: n, else: ctz_(a >>> 1, n + 1))
  defp pop(a), do: pop_(a, 0)
  defp pop_(0, n), do: n
  defp pop_(a, n), do: pop_(a >>> 1, n + (a &&& 1))

  # memarg = align (uleb) + offset (uleb); we only need offset (alignment is a hint).
  defp memarg(bin) do
    {_align, bin} = uleb(bin)
    uleb(bin)
  end

  # byte-addressed load/store over the `:atomics` memory (1-indexed). Little-endian, `n` bytes.
  #
  # FAST PATH: a word-aligned 4/8-byte access is a single `:atomics` op instead of the per-byte
  # mget/mput loop (which re-reads the SAME backing word up to 8× and does 8 RMWs for one store).
  # The backing is `signed: false`, so a bare `get` already yields 0..2^64-1 — identical to what the
  # byte loop reconstructs — and `&&& @mask64` on a store matches the loop's two's-complement packing
  # for negative `val`. Everything unaligned / 1- / 2-byte falls through to the byte loop unchanged.
  defp load(mem, addr, 8) when (addr &&& 7) == 0, do: :atomics.get(mem, (addr >>> 3) + 1) &&& @mask64
  defp load(mem, addr, 4) when (addr &&& 7) == 0, do: :atomics.get(mem, (addr >>> 3) + 1) &&& 0xFFFFFFFF
  defp load(mem, addr, 4) when (addr &&& 7) == 4, do: (:atomics.get(mem, (addr >>> 3) + 1) >>> 32) &&& 0xFFFFFFFF

  defp load(mem, addr, n) do
    Enum.reduce(0..(n - 1), 0, fn i, acc -> acc ||| (mget(mem, addr + i) <<< (i * 8)) end)
  end

  defp store(mem, addr, val, 8) when (addr &&& 7) == 0 do
    :atomics.put(mem, (addr >>> 3) + 1, val &&& @mask64)
    :ok
  end

  defp store(mem, addr, val, 4) when (addr &&& 7) == 0 do
    idx = (addr >>> 3) + 1
    w = :atomics.get(mem, idx)
    :atomics.put(mem, idx, ((w &&& bnot(0xFFFFFFFF)) ||| (val &&& 0xFFFFFFFF)) &&& @mask64)
    :ok
  end

  defp store(mem, addr, val, 4) when (addr &&& 7) == 4 do
    idx = (addr >>> 3) + 1
    w = :atomics.get(mem, idx)
    :atomics.put(mem, idx, ((w &&& 0xFFFFFFFF) ||| ((val &&& 0xFFFFFFFF) <<< 32)) &&& @mask64)
    :ok
  end

  defp store(mem, addr, val, n) do
    for i <- 0..(n - 1), do: mput(mem, addr + i, (val >>> (i * 8)) &&& 0xFF)
    :ok
  end

  # Linear memory is PACKED: one 64-bit `:atomics` slot holds 8 consecutive bytes (little-endian
  # within the word), so the backing is 8x smaller than one-slot-per-byte. Byte access is a
  # read-modify-write of the containing word — safe without atomicity since one guest = one process.
  defp mget(mem, addr) do
    w = :atomics.get(mem, (addr >>> 3) + 1)
    (w >>> ((addr &&& 7) * 8)) &&& 0xFF
  end

  defp mput(mem, addr, byte) do
    idx = (addr >>> 3) + 1
    sh = (addr &&& 7) * 8
    w = :atomics.get(mem, idx)
    w = ((w &&& bnot(0xFF <<< sh)) ||| ((byte &&& 0xFF) <<< sh)) &&& @mask64
    :atomics.put(mem, idx, w)
  end

  # a small bounded fuel counter for const-expression evaluation (global init / element offsets) —
  # these are tiny + trusted, but still flow through the fuel-charging `run/4`.
  defp cfuel do
    f = :atomics.new(1, signed: true)
    :atomics.put(f, 1, 1_000_000)
    f
  end

  # ── traps ───────────────────────────────────────────────────────────────────────────────────────
  # Integer division: wasm traps on a zero divisor and on the single signed-overflow case
  # (INT_MIN / -1). `smin` is the type's signed minimum; the `idiv(a, -1, a)` head matches when the
  # dividend equals it. rem_s has no overflow trap (INT_MIN % -1 == 0, which Erlang already yields).
  defp idiv(_a, 0, _smin), do: trap!(:div_by_zero)
  defp idiv(a, -1, a), do: trap!(:int_overflow)
  defp idiv(a, b, _smin), do: div(a, b)
  defp udiv(_a, 0), do: trap!(:div_by_zero)
  defp udiv(a, b), do: div(a, b)
  defp irem(_a, 0), do: trap!(:div_by_zero)
  defp irem(a, b), do: rem(a, b)
  defp urem(_a, 0), do: trap!(:div_by_zero)
  defp urem(a, b), do: rem(a, b)

  # Guest memory access is bounds-checked against the LOGICAL memory size (pages × 64KB), not the
  # over-allocated atomics cap: an access past `memory.size` traps, exactly as the spec requires (and
  # the transpiler will lower to the same trap, so the oracle can compare). Host-internal `store/4`
  # writes (iovecs/argv/stat structs) stay unchecked — they're trusted runtime bookkeeping.
  defp bounds!(rt, addr, n) do
    limit = :atomics.get(rt.mem_pages, 1) * 65536
    if addr < 0 or addr + n > limit do
      if Process.get(:tl_oob_debug), do: IO.inspect({:OOB, addr: addr, n: n, limit: limit, pages: div(limit, 65536)}, label: "TL_OOB")
      trap!(:out_of_bounds)
    end
  end

  defp gload(rt, addr, n), do: (bounds!(rt, addr, n); load(wmem(), addr, n))
  defp gstore(rt, addr, v, n), do: (bounds!(rt, addr, n); store(wmem(), addr, v, n))
  defp gfload(rt, addr, n), do: (bounds!(rt, addr, n); fload(wmem(), addr, n))
  defp gfstore(rt, addr, v, n), do: (bounds!(rt, addr, n); fstore(wmem(), addr, v, n))
  defp gvload(rt, addr), do: (bounds!(rt, addr, 16); vload(wmem(), addr))
  defp gvstore(rt, addr, v), do: (bounds!(rt, addr, 16); vstore(wmem(), addr, v))
end
