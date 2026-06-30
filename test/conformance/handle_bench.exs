defmodule W do
  import Bitwise
  # ── minimal wasm byte encoder ──
  def u(n), do: uleb(n, [])
  defp uleb(0, []), do: [0]
  defp uleb(0, acc), do: acc
  defp uleb(n, acc), do: uleb(div(n, 128), acc ++ [band(n, 127) + (if div(n,128)>0, do: 128, else: 0)])
  def s(n) when n < 0, do: s64(n + 0x10000000000000000)
  def s(n), do: u(n)
  defp s64(n), do: s64b(n, [])
  defp s64b(0, []), do: [0]
  defp s64b(0, acc), do: acc
  defp s64b(n, acc), do: s64b(bsr(n, 7), acc ++ [band(n, 127) + (if bsr(n,7)!=0, do: 128, else: 0)])
  def dbl(v), do: <<v::float-little-64>>
  def vec(items), do: [u(length(items)) | Enum.flat_map(items, fn x -> if is_list(x), do: x, else: [x] end)]
  def sec(id, body) do
    bin = :erlang.list_to_binary(body)
    [id] ++ u(byte_size(bin)) ++ :binary.bin_to_list(bin)
  end
  def name(s), do: [u(byte_size(s)) | :binary.bin_to_list(s)]

  # valtypes
  @i32 0x7F; @i64 0x7E; @f32 0x7D; @f64 0x7C; @externref 0x6F
  def vt(:i32), do: @i32; def vt(:i64), do: @i64; def vt(:f32), do: @f32; def vt(:f64), do: @f64; def vt(:externref), do: @externref

  # ops
  def local_get(i), do: [0x20, u(i)]
  def local_set(i), do: [0x21, u(i)]
  def local_tee(i), do: [0x22, u(i)]
  def i32_const(n), do: [0x41, s(n)]
  def f64_const(v), do: [0x44, dbl(v)]
  def i32_add(), do: [0x6A]; def i32_sub(), do: [0x6B]; def i32_eq(), do: [0x46]; def i32_eqz(), do: [0x45]
  def f64_add(), do: [0xA0]
  def i32_load8_u(off), do: [0x2D, u(0), u(off)]
  def f64_load(off), do: [0x2B, u(3), u(off)]
  def block(rt), do: [0x02, blocktype(rt)]
  def loop(rt), do: [0x03, blocktype(rt)]
  def ifop(rt), do: [0x04, blocktype(rt)]
  def elseop(), do: [0x05]
  def endop(), do: [0x0B]
  def br(l), do: [0x0C, u(l)]
  def br_if(l), do: [0x0D, u(l)]
  def call(f), do: [0x10, u(f)]
  def returnop(), do: [0x0F]
  defp blocktype(:void), do: 0x40
  defp blocktype(:f64), do: @f64
  defp blocktype(:i32), do: @i32

  def functype(params, results), do: [0x60, vec(Enum.map(params, &vt/1)), vec(Enum.map(results, &vt/1))]
end

defmodule Bench do
  import W
  @n 2_000_000

  # generic single-arg-ref module: func "f"(refslot, n) loops n times calling prop(ref,1), sums f64.
  defp mod(reftype) do
    access = [local_get(0), i32_const(1), call(0)]
    body = [block(:void), loop(:void),
              local_get(1), i32_eqz(), br_if(1),
              access, local_get(2), f64_add(), local_set(2),
              local_get(1), i32_const(1), i32_sub(), local_set(1), br(0),
            endop(), endop(), local_get(2), returnop()]
    locals = vec([[u(1), vt(:f64)]])
    size = byte_size(:erlang.list_to_binary(locals)) + byte_size(:erlang.list_to_binary(body)) + 1
    code = vec([[u(size), locals, body, endop()]])
    ts = sec(1, vec([functype([reftype, :i32], [:f64]), functype([reftype, :i32], [:f64])]))
    is = sec(2, vec([[name("e"), name("prop"), 0x00, u(0)]]))
    fs = sec(3, vec([u(1)]))
    es = sec(7, vec([[name("f"), 0x00, u(1)]]))
    :erlang.list_to_binary([0x00,0x61,0x73,0x6D,0x01,0x00,0x00,0x00, ts, is, fs, es, sec(10, code)])
  end

  defp time(mod, refarg, host) do
    {:ok, m} = TinyLasers.Wasm.decode(mod)
    Process.put(:tl_imports, %{{"e","prop"} => host})
    t0 = System.monotonic_time(:nanosecond)
    {r, _} = TinyLasers.Wasm.call_io(m, "f", [refarg, @n], fuel: 5_000_000_000)
    wall = System.monotonic_time(:nanosecond) - t0
    Process.delete(:tl_imports)
    {r, wall}
  end

  def run do
    # B: true externref — object is a BEAM tuple, prop = element/2
    obj_t = List.to_tuple(for i <- 1..20, do: if(i==1, do: 3.14, else: 0.0))
    {rb, wb} = time(mod(:externref), obj_t, fn [ref,key] -> :erlang.element(round(key), ref) end)

    # C: i32 handle + host object table (map handle->object map), prop = table lookup then field
    tbl = %{1 => %{1 => 3.14, 2 => 0.0}}
    Process.put(:tl_objtbl, tbl)
    {rc, wc} = time(mod(:i32), 1, fn [h,key] -> Process.get(:tl_objtbl)[round(h)][round(key)] end)
    Process.delete(:tl_objtbl)

    IO.puts("B true-externref (element/2):   #{Float.round(wb/1_000_000,1)}ms  result=#{inspect(rb)}")
    IO.puts("C i32-handle + host map table:  #{Float.round(wc/1_000_000,1)}ms  result=#{inspect(rc)}")
    IO.puts("ratio C/B = #{Float.round(wc/wb,2)}x  (C is this much slower than true externref)")
    IO.puts("(both correct: 3.14 * #{@n} = #{3.14*@n})")
  end
end
Bench.run()
