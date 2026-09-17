defmodule TypeSafe.RetryPolicy do
  @moduledoc """
  Retry policy defaults for the TypeSafe client. Retry execution (backoff,
  jitter, Req wiring) is implemented in a later slice; this struct only
  carries the default values every client is built with.
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

  defimpl Inspect do
    @moduledoc false

    # Custom rendering (spec §4, operator decision): the derived Inspect
    # enumerates every member of the ~100-element `http_statuses` MapSet in
    # hash order, which is unreadable. All nine fields stay visible — nothing
    # is hidden — and `http_statuses` alone is summarized as compact ranges
    # (e.g. "408, 429, 500..599"), derived from the actual MapSet so a
    # customized policy renders its own real ranges rather than a hardcoded
    # string. Because this is a nested field of `TypeSafe.Client`, it also
    # fixes `inspect/1` on a client.
    def inspect(policy, _opts) do
      fields = [
        {"max_retries", Kernel.inspect(policy.max_retries)},
        {"backoff_initial_ms", Kernel.inspect(policy.backoff_initial_ms)},
        {"backoff_max_ms", Kernel.inspect(policy.backoff_max_ms)},
        {"backoff_jitter", Kernel.inspect(policy.backoff_jitter)},
        {"http_statuses", "[" <> summarize_statuses(policy.http_statuses) <> "]"},
        {"respect_retry_after", Kernel.inspect(policy.respect_retry_after)},
        {"max_retry_after_ms", Kernel.inspect(policy.max_retry_after_ms)},
        {"api_connection_error", Kernel.inspect(policy.api_connection_error)},
        {"api_timeout_error", Kernel.inspect(policy.api_timeout_error)}
      ]

      rendered = Enum.map_join(fields, ", ", fn {name, value} -> "#{name}: #{value}" end)
      "#TypeSafe.RetryPolicy<#{rendered}>"
    end

    defp summarize_statuses(http_statuses) do
      http_statuses
      |> MapSet.to_list()
      |> Enum.sort()
      |> collapse_ranges()
      |> Enum.join(", ")
    end

    defp collapse_ranges([]), do: []

    defp collapse_ranges([first | rest]) do
      {last, remaining} = extend_run(rest, first)
      [format_range(first, last) | collapse_ranges(remaining)]
    end

    defp extend_run([next | rest], prev) when next == prev + 1, do: extend_run(rest, next)
    defp extend_run(rest, prev), do: {prev, rest}

    defp format_range(first, first), do: Integer.to_string(first)
    defp format_range(first, last), do: "#{first}..#{last}"
  end
end
