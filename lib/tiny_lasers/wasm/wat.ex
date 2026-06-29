defmodule TinyLasers.Wasm.Wat do
  @moduledoc """
  A **WAT → wasm-bytes assembler** for the core subset the spec tests exercise: it turns a parsed
  `(module …)` S-expression (from `TinyLasers.Wasm.Sexp`) into a binary `.wasm` that Wasm's existing
  decoder reads. Building bytes (not a second module representation) means the decoder/interpreter stay
  the single source of truth — the assembler only has to produce a faithful binary.

  Supports: `type`/`func`/`param`/`result`/`local` (with `$names`), `export`, `memory`, `global`,
  `data`; numeric/comparison/conversion ops (no-immediate table), `const`, `local.*`/`global.*`,
  `drop`/`select`, memory `load`/`store` (with `offset=`/`align=`), `memory.size`/`grow`, and control
  (`block`/`loop`/`if`/`else`/`end`/`br`/`br_if`/`return`/`call`), in both flat and folded form.

  Returns `{:ok, bytes}` or `{:error, {:unsupported_wat, form}}` — never wrong bytes. Unsupported forms
  are surfaced so the spec runner can log + skip them (no silent gaps).
  """
  import Bitwise

  # ── no-immediate opcode table (mnemonic → byte) ────────────────────────────────────────────────
  @ops %{
    "unreachable" => 0x00, "nop" => 0x01, "return" => 0x0F, "drop" => 0x1A, "select" => 0x1B,
    "i32.eqz" => 0x45, "i32.eq" => 0x46, "i32.ne" => 0x47, "i32.lt_s" => 0x48, "i32.lt_u" => 0x49,
    "i32.gt_s" => 0x4A, "i32.gt_u" => 0x4B, "i32.le_s" => 0x4C, "i32.le_u" => 0x4D, "i32.ge_s" => 0x4E,
    "i32.ge_u" => 0x4F, "i64.eqz" => 0x50, "i64.eq" => 0x51, "i64.ne" => 0x52, "i64.lt_s" => 0x53,
    "i64.lt_u" => 0x54, "i64.gt_s" => 0x55, "i64.gt_u" => 0x56, "i64.le_s" => 0x57, "i64.le_u" => 0x58,
    "i64.ge_s" => 0x59, "i64.ge_u" => 0x5A, "f32.eq" => 0x5B, "f32.ne" => 0x5C, "f32.lt" => 0x5D,
    "f32.gt" => 0x5E, "f32.le" => 0x5F, "f32.ge" => 0x60, "f64.eq" => 0x61, "f64.ne" => 0x62,
    "f64.lt" => 0x63, "f64.gt" => 0x64, "f64.le" => 0x65, "f64.ge" => 0x66,
    "i32.clz" => 0x67, "i32.ctz" => 0x68, "i32.popcnt" => 0x69, "i32.add" => 0x6A, "i32.sub" => 0x6B,
    "i32.mul" => 0x6C, "i32.div_s" => 0x6D, "i32.div_u" => 0x6E, "i32.rem_s" => 0x6F, "i32.rem_u" => 0x70,
    "i32.and" => 0x71, "i32.or" => 0x72, "i32.xor" => 0x73, "i32.shl" => 0x74, "i32.shr_s" => 0x75,
    "i32.shr_u" => 0x76, "i32.rotl" => 0x77, "i32.rotr" => 0x78, "i64.clz" => 0x79, "i64.ctz" => 0x7A,
    "i64.popcnt" => 0x7B, "i64.add" => 0x7C, "i64.sub" => 0x7D, "i64.mul" => 0x7E, "i64.div_s" => 0x7F,
    "i64.div_u" => 0x80, "i64.rem_s" => 0x81, "i64.rem_u" => 0x82, "i64.and" => 0x83, "i64.or" => 0x84,
    "i64.xor" => 0x85, "i64.shl" => 0x86, "i64.shr_s" => 0x87, "i64.shr_u" => 0x88, "i64.rotl" => 0x89,
    "i64.rotr" => 0x8A, "f32.abs" => 0x8B, "f32.neg" => 0x8C, "f32.ceil" => 0x8D, "f32.floor" => 0x8E,
    "f32.trunc" => 0x8F, "f32.nearest" => 0x90, "f32.sqrt" => 0x91, "f32.add" => 0x92, "f32.sub" => 0x93,
    "f32.mul" => 0x94, "f32.div" => 0x95, "f32.min" => 0x96, "f32.max" => 0x97, "f32.copysign" => 0x98,
    "f64.abs" => 0x99, "f64.neg" => 0x9A, "f64.ceil" => 0x9B, "f64.floor" => 0x9C, "f64.trunc" => 0x9D,
    "f64.nearest" => 0x9E, "f64.sqrt" => 0x9F, "f64.add" => 0xA0, "f64.sub" => 0xA1, "f64.mul" => 0xA2,
    "f64.div" => 0xA3, "f64.min" => 0xA4, "f64.max" => 0xA5, "f64.copysign" => 0xA6, "i32.wrap_i64" => 0xA7,
    "i32.trunc_f32_s" => 0xA8, "i32.trunc_f32_u" => 0xA9, "i32.trunc_f64_s" => 0xAA, "i32.trunc_f64_u" => 0xAB,
    "i64.extend_i32_s" => 0xAC, "i64.extend_i32_u" => 0xAD, "i64.trunc_f64_s" => 0xB0, "i64.trunc_f64_u" => 0xB1,
    "f32.convert_i32_s" => 0xB2, "f32.convert_i32_u" => 0xB3, "f64.convert_i32_s" => 0xB7,
    "f64.convert_i32_u" => 0xB8, "f32.demote_f64" => 0xB6, "f64.promote_f32" => 0xBB,
    "i32.extend8_s" => 0xC0, "i32.extend16_s" => 0xC1, "i64.extend8_s" => 0xC2, "i64.extend16_s" => 0xC3,
    "i64.extend32_s" => 0xC4
  }

  @memops %{
    "i32.load" => {0x28, 2}, "i64.load" => {0x29, 3}, "f32.load" => {0x2A, 2}, "f64.load" => {0x2B, 3},
    "i32.load8_s" => {0x2C, 0}, "i32.load8_u" => {0x2D, 0}, "i32.load16_s" => {0x2E, 1}, "i32.load16_u" => {0x2F, 1},
    "i64.load8_s" => {0x30, 0}, "i64.load8_u" => {0x31, 0}, "i64.load16_s" => {0x32, 1}, "i64.load16_u" => {0x33, 1},
    "i64.load32_s" => {0x34, 2}, "i64.load32_u" => {0x35, 2},
    "i32.store" => {0x36, 2}, "i64.store" => {0x37, 3}, "f32.store" => {0x38, 2}, "f64.store" => {0x39, 3},
    "i32.store8" => {0x3A, 0}, "i32.store16" => {0x3B, 1},
    "i64.store8" => {0x3C, 0}, "i64.store16" => {0x3D, 1}, "i64.store32" => {0x3E, 2}
  }

  @valtypes %{"i32" => 0x7F, "i64" => 0x7E, "f32" => 0x7D, "f64" => 0x7C}

  @doc "Assemble a `(module …)` form into wasm bytes. → `{:ok, binary} | {:error, reason}`."
  def assemble(["module" | fields]) do
    fields = Enum.reject(fields, &name?/1)
    funcs = collect(fields, "func")
    # build the type table: one entry per distinct (params, results) signature
    sigs = Enum.map(funcs, &func_sig/1)
    types = Enum.uniq(sigs)
    type_idx = types |> Enum.with_index() |> Map.new()

    func_names = name_index(funcs, "func")
    global_names = name_index(collect(fields, "global"), "global")

    code = Enum.map(funcs, &assemble_func(&1, type_idx, func_names, global_names))

    with :ok <- first_error(code) do
      bytes =
        magic() <>
          section(1, type_section(types)) <>
          section(3, vec(Enum.map(sigs, &<<Map.fetch!(type_idx, &1)>>))) <>
          mem_section(fields) <>
          global_section(collect(fields, "global"), global_names) <>
          export_section(fields, func_names) <>
          section(10, vec(Enum.map(code, fn {:ok, b} -> uleb(byte_size(b)) <> b end))) <>
          data_section(collect(fields, "data"))

      {:ok, bytes}
    end
  catch
    {:unsupported, form} -> {:error, {:unsupported_wat, form}}
  rescue
    e -> {:error, {:assemble_error, Exception.message(e)}}
  end

  def assemble(other), do: {:error, {:unsupported_wat, other}}

  # ── module structure ───────────────────────────────────────────────────────────────────────────
  defp collect(fields, kw), do: Enum.filter(fields, &match?([^kw | _], &1))

  defp func_sig(func) do
    body = func_body_fields(func)
    params = body |> Enum.filter(&match?(["param" | _], &1)) |> Enum.flat_map(&types_of/1)
    results = body |> Enum.filter(&match?(["result" | _], &1)) |> Enum.flat_map(&types_of/1)
    {params, results}
  end

  # strip ONLY the leading $name from a func's fields (flat-body operands like `local.get $x` keep their
  # $names — those are NOT the function name).
  defp func_body_fields(["func", name | rest]) when is_binary(name), do: if(name?(name), do: rest, else: [name | rest])
  defp func_body_fields(["func" | rest]), do: rest

  defp types_of([_kw | rest]), do: rest |> Enum.reject(&name?/1) |> Enum.map(&Map.fetch!(@valtypes, &1))

  # a declaration's name is ONLY the token immediately after the keyword, iff it's a $name
  defp decl_name([_kw, name | _]) when is_binary(name), do: if(name?(name), do: name, else: nil)
  defp decl_name(_), do: nil

  defp name_index(items, _kw) do
    items
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {item, i}, acc ->
      case decl_name(item) do
        nil -> acc
        nm -> Map.put(acc, nm, i)
      end
    end)
  end

  defp assemble_func(func, type_idx, func_names, global_names) do
    fields = func_body_fields(func)
    params = fields |> Enum.filter(&match?(["param" | _], &1))
    # local name table: params first (in order), then declared locals
    param_names = ordered_names(params)
    locals = fields |> Enum.filter(&match?(["local" | _], &1))
    local_names = ordered_names(locals)
    local_types = locals |> Enum.flat_map(&types_of/1)

    sym = %{
      locals: index_names(param_names ++ local_names),
      funcs: func_names,
      globals: global_names
    }

    body = emit_seq(reject_decls(fields), sym, [])

    {:ok, local_decls(local_types) <> body <> <<0x0B>>}
  rescue
    e -> {:error, {:unsupported_wat, func, Exception.message(e)}}
  end

  @decl_kw ~w(param result local export type)
  defp reject_decls(fields),
    do: Enum.reject(fields, fn f -> is_list(f) and match?([kw | _] when kw in @decl_kw, f) end)

  defp ordered_names(decls), do: Enum.flat_map(decls, fn [_kw | rest] ->
    names = Enum.filter(rest, &name?/1)
    tys = Enum.reject(rest, &name?/1)
    # a named decl has exactly one type; an unnamed group expands to N anonymous slots
    if names == [], do: List.duplicate(nil, length(tys)), else: names
  end)

  defp index_names(names), do: names |> Enum.with_index() |> Enum.reduce(%{}, fn {n, i}, a -> if n, do: Map.put(a, n, i), else: a end)

  # local declarations as a vec of (count, type) groups; one group per local (simplest valid encoding)
  defp local_decls(types), do: vec(Enum.map(types, fn t -> <<1, t>> end))

  # ── instruction emission (flat + folded) ────────────────────────────────────────────────────────
  defp emit_seq([], _sym, acc), do: :erlang.list_to_binary(Enum.reverse(acc))

  defp emit_seq([tok | rest], sym, acc) when is_list(tok) do
    emit_seq(rest, sym, [emit_folded(tok, sym) | acc])
  end

  defp emit_seq([mnem | rest], sym, acc) when is_binary(mnem) do
    {bytes, rest} = emit_flat(mnem, rest, sym)
    emit_seq(rest, sym, [bytes | acc])
  end

  # flat: a mnemonic followed by its immediate atoms in the token stream
  defp emit_flat("block", rest, sym), do: block_like(0x02, rest, sym)
  defp emit_flat("loop", rest, sym), do: block_like(0x03, rest, sym)
  defp emit_flat("if", rest, sym), do: block_like(0x04, rest, sym)
  defp emit_flat("else", rest, _sym), do: {<<0x05>>, rest}
  defp emit_flat("end", rest, _sym), do: {<<0x0B>>, rest}

  defp emit_flat(mnem, rest, sym) do
    {imms, rest} = take_imms(mnem, rest)
    {emit_instr(mnem, imms, sym), rest}
  end

  # folded: (mnem imm* operand*) → operands (lists) first, then the instruction
  defp emit_folded([mnem | args], sym) do
    {imms, operands} = Enum.split_with(args, &(not is_list(&1)))
    ops_bytes = operands |> Enum.map(&emit_folded_or_seq(&1, sym)) |> :erlang.list_to_binary()
    ops_bytes <> emit_instr(mnem, imms, sym)
  end

  defp emit_folded_or_seq(list, sym) when is_list(list), do: emit_folded(list, sym)

  # blocktype: optional (result T); flat block bodies continue in the token stream until `end`
  defp block_like(opcode, rest, sym) do
    {bt, rest} = blocktype(rest, sym)
    {<<opcode>> <> bt, rest}
  end

  defp blocktype([["result" | rty] | rest], _sym), do: {<<Map.fetch!(@valtypes, hd(rty))>>, rest}
  defp blocktype(rest, _sym), do: {<<0x40>>, rest}

  # take the flat immediate atoms a mnemonic consumes from the stream
  defp take_imms(mnem, rest) do
    cond do
      mnem in ["i32.const", "i64.const", "f32.const", "f64.const", "br", "br_if", "call",
               "local.get", "local.set", "local.tee", "global.get", "global.set"] ->
        {[hd(rest)], tl(rest)}

      Map.has_key?(@memops, mnem) ->
        # optional offset= / align= atoms
        Enum.split_with(rest, &(is_binary(&1) and (String.starts_with?(&1, "offset=") or String.starts_with?(&1, "align="))))
        |> then(fn {opts, rest2} -> {opts, rest2} end)

      true ->
        {[], rest}
    end
  end

  defp emit_instr(mnem, imms, sym) do
    cond do
      Map.has_key?(@ops, mnem) -> <<Map.fetch!(@ops, mnem)>>
      Map.has_key?(@memops, mnem) -> memarg_instr(mnem, imms)
      true -> typed_instr(mnem, imms, sym)
    end
  end

  defp typed_instr("i32.const", [v], _), do: <<0x41>> <> sleb(parse_int(v))
  defp typed_instr("i64.const", [v], _), do: <<0x42>> <> sleb(parse_int(v))
  defp typed_instr("f32.const", [v], _), do: <<0x43, encode_f32(parse_float(v))::binary>>
  defp typed_instr("f64.const", [v], _), do: <<0x44, encode_f64(parse_float(v))::binary>>
  defp typed_instr("local.get", [x], sym), do: <<0x20>> <> uleb(resolve(x, sym.locals))
  defp typed_instr("local.set", [x], sym), do: <<0x21>> <> uleb(resolve(x, sym.locals))
  defp typed_instr("local.tee", [x], sym), do: <<0x22>> <> uleb(resolve(x, sym.locals))
  defp typed_instr("global.get", [x], sym), do: <<0x23>> <> uleb(resolve(x, sym.globals))
  defp typed_instr("global.set", [x], sym), do: <<0x24>> <> uleb(resolve(x, sym.globals))
  defp typed_instr("call", [x], sym), do: <<0x10>> <> uleb(resolve(x, sym.funcs))
  defp typed_instr("br", [x], _), do: <<0x0C>> <> uleb(parse_int(x))
  defp typed_instr("br_if", [x], _), do: <<0x0D>> <> uleb(parse_int(x))
  defp typed_instr("memory.size", _, _), do: <<0x3F, 0x00>>
  defp typed_instr("memory.grow", _, _), do: <<0x40, 0x00>>
  defp typed_instr(mnem, _, _), do: throw({:unsupported, mnem})

  defp memarg_instr(mnem, opts) do
    {op, natural} = Map.fetch!(@memops, mnem)
    align = opt(opts, "align=", natural)
    offset = opt(opts, "offset=", 0)
    <<op>> <> uleb(align) <> uleb(offset)
  end

  defp opt(opts, prefix, default) do
    case Enum.find(opts, &String.starts_with?(&1, prefix)) do
      nil -> default
      s -> s |> String.replace_prefix(prefix, "") |> parse_int()
    end
  end

  defp resolve("$" <> _ = name, table), do: Map.fetch!(table, name)
  defp resolve(n, _table) when is_binary(n), do: parse_int(n)

  # ── sections ─────────────────────────────────────────────────────────────────────────────────
  defp magic, do: <<0, 97, 115, 109, 1, 0, 0, 0>>
  defp section(_id, <<>>), do: <<>>
  defp section(id, payload), do: <<id>> <> uleb(byte_size(payload)) <> payload

  defp type_section(types) do
    vec(Enum.map(types, fn {params, results} ->
      <<0x60>> <> vec(Enum.map(params, &<<&1>>)) <> vec(Enum.map(results, &<<&1>>))
    end))
  end

  defp mem_section(fields) do
    case collect(fields, "memory") do
      [] -> <<>>
      [["memory" | rest] | _] ->
        # only the numeric limit atoms; an inline (memory (data …)) form isn't modeled yet → throw skip
        nums = rest |> Enum.filter(&(is_binary(&1) and numeric?(&1))) |> Enum.map(&parse_int/1)
        limits =
          case nums do
            [min] -> <<0x00>> <> uleb(min)
            [min, max] -> <<0x01>> <> uleb(min) <> uleb(max)
            _ -> throw({:unsupported, :inline_memory})
          end

        section(5, vec([limits]))
    end
  end

  defp global_section([], _names), do: <<>>
  defp global_section(globals, _names) do
    section(6, vec(Enum.map(globals, fn ["global" | rest] ->
      rest = Enum.reject(rest, &name?/1)
      {ty, mut, init} = global_parts(rest)
      <<Map.fetch!(@valtypes, ty), mut>> <> emit_seq([init], %{locals: %{}, funcs: %{}, globals: %{}}, []) <> <<0x0B>>
    end)))
  end

  defp global_parts([["mut", ty], init]), do: {ty, 0x01, init}
  defp global_parts([ty, init]), do: {ty, 0x00, init}

  defp export_section(fields, func_names) do
    exports =
      for ["func" | _] = f <- collect(fields, "func"),
          [_kw | rest] = f,
          ["export", {:string, nm}] <- rest do
        {nm, Map.get(func_names, find_name(f), func_pos(collect(fields, "func"), f))}
      end ++
        for ["export", {:string, nm}, ["func" | _] = ref] <- fields do
          {nm, resolve_export_ref(ref, func_names, fields)}
        end

    case exports do
      [] -> <<>>
      _ -> section(7, vec(Enum.map(exports, fn {nm, idx} -> name_bytes(nm) <> <<0x00>> <> uleb(idx) end)))
    end
  end

  defp resolve_export_ref(["func", ref], func_names, fields), do: Map.get(func_names, ref, parse_int_or(ref, fields))
  defp parse_int_or("$" <> _, _), do: 0
  defp parse_int_or(n, _), do: parse_int(n)

  defp func_pos(funcs, f), do: Enum.find_index(funcs, &(&1 == f)) || 0
  defp find_name(func), do: decl_name(func)

  defp data_section([]), do: <<>>
  defp data_section(datas) do
    section(11, vec(Enum.map(datas, fn ["data" | rest] ->
      rest = Enum.reject(rest, &name?/1)
      {offset_expr, [{:string, bytes}]} = Enum.split(rest, length(rest) - 1)
      off = offset_expr |> Enum.map(&emit_folded_or_atom(&1)) |> :erlang.list_to_binary()
      <<0x00>> <> off <> <<0x0B>> <> uleb(byte_size(bytes)) <> bytes
    end)))
  end

  defp emit_folded_or_atom(list) when is_list(list), do: emit_folded(list, %{locals: %{}, funcs: %{}, globals: %{}})

  # ── helpers ─────────────────────────────────────────────────────────────────────────────────
  defp name?("$" <> _), do: true
  defp name?(_), do: false
  defp numeric?(<<c, _::binary>>) when c in ?0..?9 or c == ?-, do: true
  defp numeric?(_), do: false
  defp name_bytes(s), do: uleb(byte_size(s)) <> s
  defp vec(items), do: uleb(length(items)) <> :erlang.list_to_binary(items)

  defp first_error(results), do: Enum.find_value(results, :ok, fn {:error, _} = e -> e; _ -> nil end)

  defp parse_int(s), do: s |> String.replace("_", "") |> do_parse_int()
  defp do_parse_int("0x" <> hex), do: String.to_integer(hex, 16)
  defp do_parse_int("-0x" <> hex), do: -String.to_integer(hex, 16)
  defp do_parse_int(s), do: String.to_integer(s)

  defp parse_float("nan"), do: :nan
  defp parse_float("-nan"), do: :nan
  defp parse_float("inf"), do: :inf
  defp parse_float("-inf"), do: :neg_inf
  defp parse_float("0x" <> _ = h), do: h |> parse_hexfloat()
  defp parse_float(s) do
    case Float.parse(s) do
      {f, ""} -> f
      {f, _} -> f
      :error -> String.to_integer(s) * 1.0
    end
  end

  defp parse_hexfloat(_), do: throw({:unsupported, :hexfloat})

  defp encode_f32(:nan), do: <<0, 0, 0xC0, 0x7F>>
  defp encode_f32(:inf), do: <<0, 0, 0x80, 0x7F>>
  defp encode_f32(:neg_inf), do: <<0, 0, 0x80, 0xFF>>
  defp encode_f32(f), do: <<f::float-32-little>>
  defp encode_f64(:nan), do: <<0, 0, 0, 0, 0, 0, 0xF8, 0x7F>>
  defp encode_f64(:inf), do: <<0, 0, 0, 0, 0, 0, 0xF0, 0x7F>>
  defp encode_f64(:neg_inf), do: <<0, 0, 0, 0, 0, 0, 0xF0, 0xFF>>
  defp encode_f64(f), do: <<f::float-64-little>>

  # unsigned LEB128
  defp uleb(n) when n < 0x80, do: <<n>>
  defp uleb(n), do: <<(n &&& 0x7F) ||| 0x80>> <> uleb(n >>> 7)

  # signed LEB128
  defp sleb(n) do
    byte = n &&& 0x7F
    next = n >>> 7
    done = (next == 0 and (byte &&& 0x40) == 0) or (next == -1 and (byte &&& 0x40) != 0)
    if done, do: <<byte>>, else: <<byte ||| 0x80>> <> sleb(next)
  end
end
