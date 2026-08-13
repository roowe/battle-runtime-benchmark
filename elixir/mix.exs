defmodule BattleBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :battle_bench,
      version: "0.1.0",
      elixir: "~> 1.17",
      escript: [main_module: BattleBench],
      start_permanent: Mix.env() == :prod
    ]
  end

  def application do
    [extra_applications: []]
  end
end
