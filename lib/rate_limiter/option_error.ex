defmodule RateLimiter.OptionError do
  @moduledoc """
  Describes why a set of options was rejected.

  Functions that validate options return it as
  `{:error, %RateLimiter.OptionError{}}` instead of raising. Match on its fields
  to tell failures apart, or pass it to `raise/1` or `Exception.message/1`.
  Any code that validates options, including code outside this package, builds
  it with `exception/1`, which derives the message.

  The message is for people, not for code: match on `:reason`, `:key`, and
  `:value`, never on `:message`, whose wording may change in any release.

  Returning an exception struct inside an error tuple follows libraries such as
  [`NimbleOptions.ValidationError`](https://hexdocs.pm/nimble_options/NimbleOptions.ValidationError.html),
  [`Jason.DecodeError`](https://hexdocs.pm/jason/Jason.DecodeError.html), and
  [`Mint.TransportError`](https://hexdocs.pm/mint/Mint.TransportError.html).
  Deriving the message in `exception/1` follows the recommendation in
  `Kernel.defexception/1`.

  Its fields are public:

    * `:key` - the option at fault; a list of keys for `:unknown` and
      `:duplicate`, and `nil` for `:empty`.
    * `:value` - the offending value; `nil` for `:missing`, the offending
      entries as a keyword list for `:unknown` and `:duplicate`, and `[]` for
      `:empty`.
    * `:reason` - why the options were rejected, see `t:reason/0`.
    * `:message` - a human-readable description, derived from the fields
      above and the optional `:details` given to `exception/1`.
  """

  @enforce_keys [:key, :value, :reason, :message]
  defexception [:key, :value, :reason, :message]

  @typedoc """
  Why the options were rejected:

    * `:missing` - a required option is absent.
    * `:invalid` - an option has an invalid value.
    * `:unknown` - one or more options are not accepted.
    * `:empty` - no options were given where at least one is required.
    * `:duplicate` - an option was given more than once.
  """
  @type reason :: :missing | :invalid | :unknown | :empty | :duplicate

  @typedoc "An option error and its public fields."
  @type t :: %__MODULE__{
          key: atom() | [atom()] | nil,
          value: any(),
          reason: reason(),
          message: String.t()
        }

  @doc """
  Builds the error from `:key`, `:value`, and `:reason`, and derives its message.

  An optional `:details` string, such as `"expected a positive integer"`, is
  appended to the message after `"; "`, for any reason. It is not stored as a
  field, so code cannot match on it.

  Raises `KeyError` when `:key`, `:value`, or `:reason` is missing.
  """
  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) when is_list(opts) do
    key = Keyword.fetch!(opts, :key)
    value = Keyword.fetch!(opts, :value)
    reason = Keyword.fetch!(opts, :reason)
    details = Keyword.get(opts, :details)

    message =
      case reason do
        :missing -> "missing required option: #{inspect(key)}"
        :invalid -> "invalid value for option: #{inspect(key)}, got: #{inspect(value)}"
        :unknown -> "unknown options: #{inspect(value)}"
        :empty -> "no options were given where at least one is required"
        :duplicate -> "duplicate options: #{inspect(value)}"
      end

    complete_message =
      if is_nil(details) do
        message
      else
        "#{message}; #{details}"
      end
      |> String.trim()

    %__MODULE__{
      key: key,
      value: value,
      reason: reason,
      message: complete_message
    }
  end
end
