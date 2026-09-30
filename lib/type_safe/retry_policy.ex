defmodule TypeSafe.RetryPolicy do
  @moduledoc """
  Retry policy for the TypeSafe client: the defaults every client is built
  with, and `merge/2`, which validates a `retry:` keyword list and layers it
  onto a base policy.

  `TypeSafe.new/1` accepts `retry:` and stores the resolved policy in
  `client.retry`; `TypeSafe.system_one/3` and `TypeSafe.list_models/2` accept a
  per-call `retry:` that is merged field by field onto the client's policy.

  Fields and defaults:

    * `:max_retries` - retries after the first attempt (`2`). `0` disables retries.
    * `:backoff_initial_ms` - delay before the first retry (`500`); doubles per attempt.
    * `:backoff_max_ms` - ceiling for the exponential backoff (`5000`).
    * `:backoff_jitter` - fraction from `0` to `1` by which a backoff delay may be
      shortened at random (`0.25`).
    * `:http_statuses` - statuses that are retried (`408`, `429`, and `500..599`).
      Given as a list, `Range`, or `MapSet` of integers from 100 to 999; stored as
      a `MapSet`. A 2xx response is never retried, whatever this set contains.
    * `:respect_retry_after` - honor a `Retry-After` / `retry-after-ms` header (`true`).
    * `:max_retry_after_ms` - a server-requested delay above this falls back to
      backoff (`60_000`).
    * `:api_connection_error` - retry transport failures other than timeouts (`true`).
    * `:api_timeout_error` - retry timeouts (`false`). This differs from the JS SDK:
      a timed-out `POST /v1/systemone` may already have run and billed.

  The millisecond fields and `:max_retries` are non-negative integers.
  """

  @type t :: %__MODULE__{
          max_retries: non_neg_integer(),
          backoff_initial_ms: non_neg_integer(),
          backoff_max_ms: non_neg_integer(),
          backoff_jitter: number(),
          http_statuses: MapSet.t(non_neg_integer()),
          respect_retry_after: boolean(),
          max_retry_after_ms: non_neg_integer(),
          api_connection_error: boolean(),
          api_timeout_error: boolean()
        }

  @defaults [
    max_retries: 2,
    backoff_initial_ms: 500,
    backoff_max_ms: 5000,
    backoff_jitter: 0.25,
    http_statuses: MapSet.new([408, 429] ++ Enum.to_list(500..599)),
    respect_retry_after: true,
    max_retry_after_ms: 60_000,
    api_connection_error: true,
    api_timeout_error: false
  ]

  defstruct @defaults

  @fields Keyword.keys(@defaults)
  @ms_fields [:backoff_initial_ms, :backoff_max_ms, :max_retry_after_ms]
  @boolean_fields [:respect_retry_after, :api_connection_error, :api_timeout_error]

  @doc """
  Validates `overrides` (a keyword list of the fields above) and returns
  `{:ok, policy}` with those fields replaced, or `{:error, %TypeSafe.Error{}}`
  whose message names the problem: `retry must be a keyword list, got <value>`,
  `retry has unknown option(s): <keys>`, `retry.<key> given more than once`, or
  `retry.<field> must be <expected>, got <value>`. Never raises.
  """
  @spec merge(t(), term()) :: {:ok, t()} | {:error, TypeSafe.Error.t()}
  def merge(%__MODULE__{} = policy, overrides) do
    with :ok <- check_keyword(overrides),
         :ok <- check_duplicates(overrides),
         {:ok, known} <- check_keys(overrides),
         {:ok, values} <- normalize_all(known) do
      {:ok, struct(policy, values)}
    end
  end

  defp check_keyword(overrides) do
    case Keyword.keyword?(overrides) do
      true ->
        :ok

      false ->
        error("retry must be a keyword list, got #{inspect(overrides, charlists: :as_lists)}")
    end
  end

  # Must run before `Keyword.validate/2`, which reports a duplicate as unknown.
  defp check_duplicates(overrides) do
    keys = Keyword.keys(overrides)

    case keys -- Enum.uniq(keys) do
      [] -> :ok
      [key | _] -> error("retry.#{key} given more than once")
    end
  end

  defp check_keys(overrides) do
    case Keyword.validate(overrides, @fields) do
      {:ok, known} -> {:ok, known}
      {:error, unknown} -> error("retry has unknown option(s): #{Enum.join(unknown, ", ")}")
    end
  end

  defp normalize_all(known) do
    Enum.reduce_while(known, {:ok, []}, fn {field, value}, {:ok, acc} ->
      case normalize(field, value) do
        {:ok, normalized} ->
          {:cont, {:ok, [{field, normalized} | acc]}}

        :error ->
          {:halt,
           error(
             "retry.#{field} must be #{expected(field)}, got #{inspect(value, charlists: :as_lists)}"
           )}
      end
    end)
  end

  defp normalize(:max_retries, value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp normalize(field, value) when field in @ms_fields and is_integer(value) and value >= 0,
    do: {:ok, value}

  defp normalize(:backoff_jitter, value) when is_number(value) and value >= 0 and value <= 1,
    do: {:ok, value}

  defp normalize(field, value) when field in @boolean_fields and is_boolean(value),
    do: {:ok, value}

  defp normalize(:http_statuses, %Range{first: first, last: last} = range) do
    case first in 100..999 and last in 100..999 do
      true -> {:ok, MapSet.new(range)}
      false -> :error
    end
  end

  defp normalize(:http_statuses, value) when is_list(value) or is_struct(value, MapSet) do
    set = MapSet.new(value)

    case Enum.all?(set, &(is_integer(&1) and &1 in 100..999)) do
      true -> {:ok, set}
      false -> :error
    end
  end

  defp normalize(_field, _value), do: :error

  defp expected(:max_retries), do: "a non-negative integer"
  defp expected(field) when field in @ms_fields, do: "a non-negative integer"
  defp expected(:backoff_jitter), do: "a number from 0 to 1"
  defp expected(:http_statuses), do: "a list, Range, or MapSet of integers from 100 to 999"
  defp expected(field) when field in @boolean_fields, do: "a boolean"

  defp error(message), do: {:error, %TypeSafe.Error{message: message}}

  defimpl Inspect do
    @moduledoc false

    # Custom rendering (ADR 0007): the derived Inspect
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
