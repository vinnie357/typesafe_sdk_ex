defmodule TypeSafe.Error.Connection do
  @moduledoc """
  The request or response-body delivery failed at the transport level (DNS,
  TLS, connection closed, etc.). Unlike the HTTP status errors, there is no
  response — no `status`, `body`, `headers`, or `request_id`.

  `reason` is the underlying transport failure reason (e.g. the `:reason`
  field of a `Req.TransportError`, such as `:closed`), or `nil` when the
  underlying exception carries none. `message` is `"Connection error: <cause>"`,
  where `<cause>` is `Exception.message/1` of the underlying exception.
  """

  @enforce_keys [:message, :reason]
  defexception [:message, :reason]

  @type t :: %__MODULE__{message: String.t(), reason: term()}
end
