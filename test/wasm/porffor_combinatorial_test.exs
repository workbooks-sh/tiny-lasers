defmodule TinyLasers.JsPorfforCombinatorialTest do
  @moduledoc "Hard-fail: combinatorial generators run without transform throw."
  use ExUnit.Case, async: false

  @moduletag :porffor

  @generators ~w(async_generate.cjs generator_generate.cjs destructure_generate.cjs cc_generate.cjs)

  test "combinatorial generators execute" do
    root = Path.expand("compilers/js/porffor")

    for gen <- @generators do
      path = Path.join(root, gen)
      assert File.regular?(path)
      {out, code} = System.cmd("node", [path], cd: root, stderr_to_stdout: true)
      assert code == 0, "#{gen} failed: #{String.slice(out, 0, 200)}"
    end
  end
end
