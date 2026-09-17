defmodule TypeSafe.RetryPolicy do
  @moduledoc """
  Retry policy defaults for the TypeSafe client (spec `docs/spec.md` §5). Retry
  execution (backoff, jitter, Req wiring) is implemented in a later slice; this
  struct only carries the default values every client is built with.
  """

  @type t :: %__MODULE__{
          max_retries: non_neg_integer(),
          backoff_initial_ms: non_neg_integer(),
          backoff_max_ms: non_neg_integer(),
          backoff_jitter: float(),
          http_statuses: MapSet.t(non_neg_integer()),
          respect_retry_after: boolean(),
          max_retry_after_ms: non_neg_integer(),
          api_connection_error: boolean(),
          api_timeout_error: boolean()
        }

  defstruct max_retries: 2,
            backoff_initial_ms: 500,
            backoff_max_ms: 5000,
            backoff_jitter: 0.25,
            http_statuses: MapSet.new([408, 429] ++ Enum.to_list(500..599)),
            respect_retry_after: true,
            max_retry_after_ms: 60_000,
            api_connection_error: true,
            api_timeout_error: true
end
