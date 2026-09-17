defmodule TypeSafe do
  @moduledoc """
  Elixir port of the TypeSafe AI SDK, built on Req.
  """

  @doc """
  Returns the library's version string, as declared in `mix.exs`.

  ## Examples

      iex> TypeSafe.version()
      "0.1.0"

  """
  @spec version() :: String.t()
  def version do
    Application.spec(:typesafe_sdk, :vsn) |> to_string()
  end
end
