defmodule TypeSafe.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/vinnie357/typesafe_sdk_ex"

  def project do
    [
      app: :typesafe_sdk,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_options: elixirc_options(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_options(:test), do: [warnings_as_errors: true]
  defp elixirc_options(_), do: []

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:plug, "~> 1.16", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Elixir port of the TypeSafe AI SDK, built on Req."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp aliases do
    [
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --warnings-as-errors --max-failures=1"
      ]
    ]
  end
end
