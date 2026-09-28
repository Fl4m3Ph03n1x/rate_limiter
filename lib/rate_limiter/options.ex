defmodule RateLimiter.Options do
  @moduledoc """
  Validates the options of function calls, usually passed as keyword lists.

  Each function fetches one option and raises when it is missing or invalid.
  Algorithms can use it in `c:RateLimiter.Algorithm.init/1` to validate their
  own options.
  """

  @doc """
  Fetches `key` from `opts` and returns it if it is a positive integer.

  Raises `KeyError` when `key` is missing and `ArgumentError` when its value is
  not a positive integer.
  """
  @spec positive_integer!(keyword(), atom()) :: pos_integer()
  def positive_integer!(opts, key) do
    value = Keyword.fetch!(opts, key)

    if is_integer(value) and value > 0 do
      value
    else
      raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
    end
  end
end
