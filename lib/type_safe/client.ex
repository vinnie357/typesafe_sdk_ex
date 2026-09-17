defmodule TypeSafe.Client do
  @moduledoc """
  Configured TypeSafe API client. The API key lives only as the
  `authorization` header on `req` — never as a plain struct field.

  **Default `inspect/2` never prints the key**, because Req's `Inspect`
  implementation for `Req.Request` redacts the `authorization` header value.
  That redaction is specific to *default* `inspect` — it is bypassed by
  `inspect(client, structs: false)` (which skips custom `Inspect`
  implementations entirely) and by direct field access such as
  `client.req.headers`. Neither of those is redacted.
  """

  @enforce_keys [:base_url, :default_model, :log_level, :retry, :timeout, :default_headers, :req]
  defstruct [:base_url, :default_model, :log_level, :retry, :timeout, :default_headers, :req]

  @type t :: %__MODULE__{
          base_url: String.t(),
          default_model: String.t(),
          log_level: TypeSafe.log_level(),
          retry: TypeSafe.RetryPolicy.t(),
          timeout: pos_integer(),
          default_headers: %{optional(String.t()) => String.t()},
          req: Req.Request.t()
        }
end
