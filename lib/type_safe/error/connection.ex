defmodule TypeSafe.Error.Connection do
  @moduledoc """
  The request or response-body delivery failed at the transport level (DNS,
  TLS, connection closed, etc.). Unlike the HTTP status errors, there is no
  response — no `status`, `body`, `headers`, or `request_id`.

  `reason` is the underlying transport failure reason (e.g. the `:reason`
  field of a `Req.TransportError`, such as `:closed`), or `nil` when the
  underlying exception carries none. `message` is `"Connection error: <cause>"`,
  where `<cause>` is `Exception.message/1` of the underlying exception.

  `reason: :pool_timeout` means the connection pool was exhausted: more calls ran
  at once than the pool holds, and none freed up within the pool timeout (5_000 ms
  by default). No request was sent, and the SDK does not retry it. `message` is
  `"Connection error: connection pool exhausted (no connection available within
  the pool timeout)"`. Use a larger pool, `req_options: [finch: [size: n]]`, or
  a longer wait, `req_options: [finch: [pool_timeout: ms]]`.
  """

  @enforce_keys [:message, :reason]
  defexception [:message, :reason]

  @type t :: %__MODULE__{message: String.t(), reason: term()}
end
