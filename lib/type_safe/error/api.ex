defmodule TypeSafe.Error.API do
  @moduledoc """
  Any other non-2xx HTTP response with no more specific mapping (e.g. 409 or
  418).

  Carries the same field contract as every mapped HTTP error: `status`,
  `body` (decoded JSON, text, or `nil`), `headers` (a Req header map),
  `request_id` (from `x-typesafe-request-id`, or `nil`), and `message`.
  """

  @enforce_keys [:status, :body, :headers, :request_id, :message]
  defexception [:status, :body, :headers, :request_id, :message]

  @type t :: %__MODULE__{
          status: non_neg_integer(),
          body: term(),
          headers: %{optional(String.t()) => [String.t()]},
          request_id: String.t() | nil,
          message: String.t()
        }
end
