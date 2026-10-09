defmodule EventstoreSqlite.MixProject do
  use Mix.Project

  def project do
    [
      app: :eventstore_sqlite,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      consolidate_protocols: Mix.env() != :test
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test, "eventstore.sync_stress": :test]]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {EventstoreSqlite.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]
  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_sql, "~> 3.14"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:jason, "~> 1.4"},
      {:mneme, "~> 0.9.3", only: [:dev, :test]},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:telemetry, "~> 1.0"},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:fluxon, "~> 3.0", repo: :fluxon, optional: true},
      {:tailwind, "~> 0.3", only: :dev, runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:bandit, "~> 1.5", only: :dev},
      {:typed_struct, "~> 0.3.0"},
      {:uniq, "~> 0.1"},
      {:benchee, ">= 0.0.0", only: [:bench]},
      {:rewrite, ">= 0.0.0", only: [:dev, :test], override: true},
      {:styler, "~> 1.9", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"],
      "assets.build": ["tailwind live_eventstore --minify"],
      "eventstore.sync_stress": ["test --only stress test/eventstore_sqlite/sync/stress_test.exs"]
    ]
  end
end
