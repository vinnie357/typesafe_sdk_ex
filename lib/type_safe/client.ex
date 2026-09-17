defmodule TypeSafe.Client do
  @moduledoc """
  Configured TypeSafe API client (spec `docs/spec.md` §2, §4). The API key lives
  only as the `authorization` header on `req` — never as a plain struct field —
  so it never appears in `inspect/2`: Req's `Inspect` implementation for
  `Req.Request` redacts the `authorization` header value.
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
