defmodule TypeSafe.Questions do
  @moduledoc """
  Question builders and pre-send validation (spec `docs/spec.md` §8).
  `TypeSafe.noul/0,1,2`, `TypeSafe.choice/2`, and `TypeSafe.score/2` delegate
  here; see their `@doc` for the full contract.
  """

  @doc "Builds a `noul` question with no instructions and no criteria."
  @spec noul() :: TypeSafe.question()
  def noul, do: %{type: "noul", instructions: nil}

  @doc "Builds a `noul` question with `instructions` and no criteria key."
  @spec noul(term()) :: TypeSafe.question()
  def noul(instructions), do: %{type: "noul", instructions: instructions}

  @doc "Builds a `noul` question with `instructions` and `criteria` (may be `nil`)."
  @spec noul(term(), map() | nil) :: TypeSafe.question()
  def noul(instructions, criteria) do
    %{type: "noul", instructions: instructions, criteria: criteria}
  end

  @doc "Builds a `choice` question. `criteria` must be a map."
  @spec choice(term(), map()) :: TypeSafe.question()
  def choice(instructions, criteria) when is_map(criteria) do
    %{type: "choice", instructions: instructions, criteria: criteria}
  end

  @doc "Builds a `score` question. `criteria` must be a list."
  @spec score(term(), list()) :: TypeSafe.question()
  def score(instructions, criteria) when is_list(criteria) do
    %{type: "score", instructions: instructions, criteria: criteria}
  end

  @doc """
  Validates `questions` before sending (spec §8): non-empty, and every `score`
  question (atom- or string-keyed `type`) has a `criteria` list (atom- or
  string-keyed) with at least two entries. Returns `{:ok, questions}`
  unchanged on success — this never rewrites a question.
  """
  @spec validate(map()) :: {:ok, map()} | {:error, TypeSafe.Error.t()}
  def validate(questions) when map_size(questions) == 0 do
    {:error, %TypeSafe.Error{message: "At least one question is required."}}
  end

  def validate(questions) do
    Enum.reduce_while(questions, {:ok, %{}}, fn {id, question}, {:ok, acc} ->
      case validate_question(id, question) do
        :ok -> {:cont, {:ok, Map.put(acc, id, question)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_question(id, question) do
    case question_type(question) do
      "score" -> validate_score(id, question)
      _other_type -> :ok
    end
  end

  defp question_type(%{type: type}), do: type
  defp question_type(%{"type" => type}), do: type
  defp question_type(_question), do: nil

  defp validate_score(id, question) do
    case fetch_criteria(question) do
      {:ok, criteria} when is_list(criteria) -> validate_score_length(id, criteria)
      _missing_or_not_list -> {:error, score_not_list_error(id)}
    end
  end

  defp fetch_criteria(%{criteria: criteria}), do: {:ok, criteria}
  defp fetch_criteria(%{"criteria" => criteria}), do: {:ok, criteria}
  defp fetch_criteria(_question), do: :error

  defp validate_score_length(id, criteria) when length(criteria) < 2 do
    {:error, score_count_error(id, criteria)}
  end

  defp validate_score_length(_id, _criteria), do: :ok

  defp score_not_list_error(id) do
    %TypeSafe.Error{
      message:
        ~s(Score question "#{id}" has criteria that are not a list; ) <>
          "score criteria must be a list of descriptions indexed by score from zero."
    }
  end

  defp score_count_error(id, criteria) do
    %TypeSafe.Error{
      message:
        ~s(Score question "#{id}" has #{length(criteria)} criteria; ) <>
          "at least two scores are required."
    }
  end
end
