defmodule TypeSafe.Error.Timeout do
  @moduledoc """
  The full response did not arrive within the timeout (spec `docs/spec.md`
  §6). A kind of transport failure, kept as its own struct rather than a
  `TypeSafe.Error.Connection` subtype because Elixir has no inheritance.

  `timeout_ms` is the configured per-attempt timeout that was exceeded
  (`client.timeout`, until S3 adds a per-call override). `message` is
  `"Request timed out after <timeout_ms>ms."`.
  """

  @enforce_keys [:message, :timeout_ms]
  defexception [:message, :timeout_ms]

  @type t :: %__MODULE__{message: String.t(), timeout_ms: pos_integer()}
end
