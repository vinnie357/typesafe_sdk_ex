defmodule TypeSafe.Error do
  @moduledoc """
  Base TypeSafe SDK error, used for client configuration and question-validation
  failures (spec `docs/spec.md` §6). HTTP-status-mapped error structs land under
  `TypeSafe.Error.*` in a later slice.
  """

  @type t :: %__MODULE__{message: String.t() | nil}

  defexception [:message]
end
