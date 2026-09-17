defmodule TypeSafe.Error.RateLimit do
  @moduledoc """
  HTTP 429: the rate limit was exceeded.

  Carries the same field contract as every mapped HTTP error (`status`,
  `body`, `headers`, `request_id`, `message`), plus `retry_after_ms` — the
  server's requested retry delay parsed from the `Retry-After` response
  header (integer seconds), or `nil` when the header is absent or not a
  valid non-negative integer.
  """

  @enforce_keys [:status, :body, :headers, :request_id, :message, :retry_after_ms]
  defexception [:status, :body, :headers, :request_id, :message, :retry_after_ms]

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          body: term(),
          headers: %{optional(String.t()) => [String.t()]},
          request_id: String.t() | nil,
          message: String.t(),
          retry_after_ms: non_neg_integer() | nil
        }
end
