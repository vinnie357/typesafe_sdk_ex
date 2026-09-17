defmodule TypeSafe.Error do
  @moduledoc """
  Generic TypeSafe SDK error, used for client-configuration failures,
  question-validation failures, and an unexpected `/v1/models` response
  shape.

  A non-2xx HTTP response from `system_one/3` or `list_models/2` returns one
  of the status-mapped structs under `TypeSafe.Error.*` instead (see
  `TypeSafe.Error.BadRequest`, `TypeSafe.Error.Authentication`, and friends).
  There is no shared base struct between this module and those — match on
  `{:error, exception}` for a catch-all clause.
  """

  @type t :: %__MODULE__{message: String.t() | nil}

  defexception [:message]
end
