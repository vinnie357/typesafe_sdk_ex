defmodule TypeSafe.Error.Timeout do
  @moduledoc """
  A request attempt hit the timeout while connecting or waiting for a response. A kind of
  transport failure, kept as its own struct rather than a
  `TypeSafe.Error.Connection` subtype because Elixir has no inheritance.

  The timeout bounds each socket read, not connecting, and a per-call
  `timeout:` overrides the client's. `timeout_ms` is that configured per-read
  value, not the elapsed time, so a connect timeout reports it too. `message`
  is `"Request timed out after <timeout_ms>ms."`.
  """

  @enforce_keys [:message, :timeout_ms]
  defexception [:message, :timeout_ms]

  @type t :: %__MODULE__{message: String.t(), timeout_ms: pos_integer()}
end
