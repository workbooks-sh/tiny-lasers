defmodule TinyLasers.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :tiny_lasers,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: ["test"],
      description: "Isolated multi-language execution + build sandbox on the BEAM.",
      name: "tiny-lasers"
    ]
  end

  def application do
    [mod: {TinyLasers.Application, []}, extra_applications: [:logger]]
  end

  # No third-party deps in the core. Keep it lean — tiny-lasers is the substrate, not the product.
  defp deps, do: []

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
