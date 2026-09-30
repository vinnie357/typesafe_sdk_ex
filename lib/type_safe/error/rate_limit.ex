defmodule TypeSafe.Error.RateLimit do
  @moduledoc """
  HTTP 429: the rate limit was exceeded.

  Carries the same field contract as every mapped HTTP error (`status`,
  `body`, `headers`, `request_id`, `message`), plus `retry_after_ms` — the
  server's requested retry delay as a whole number of milliseconds. It is read
  from the `retry-after-ms` response header when valid, otherwise from
  `Retry-After` as decimal seconds or an HTTP date (relative to the current
  time, never negative); dates are read as UTC and any timezone token is
  ignored. It is `nil` when both headers are absent or invalid.
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
