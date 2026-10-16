defmodule RateLimiter.OptionErrorTest do
  use ExUnit.Case, async: true

  alias RateLimiter.OptionError

  describe "exception/1 without details" do
    test "describes a missing option" do
      assert OptionError.exception(key: :rate, value: nil, reason: :missing) ==
               %OptionError{
                 key: :rate,
                 value: nil,
                 reason: :missing,
                 message: "missing required option: :rate"
               }
    end

    test "describes an invalid value" do
      assert OptionError.exception(key: :rate, value: 0, reason: :invalid) ==
               %OptionError{
                 key: :rate,
                 value: 0,
                 reason: :invalid,
                 message: "invalid value for option: :rate, got: 0"
               }
    end

    test "describes unknown options" do
      assert OptionError.exception(key: [:foo], value: [foo: 1, foo: 2], reason: :unknown) ==
               %OptionError{
                 key: [:foo],
                 value: [foo: 1, foo: 2],
                 reason: :unknown,
                 message: "unknown options: [foo: 1, foo: 2]"
               }
    end

    test "describes empty options" do
      assert OptionError.exception(key: nil, value: [], reason: :empty) ==
               %OptionError{
                 key: nil,
                 value: [],
                 reason: :empty,
                 message: "no options were given where at least one is required"
               }
    end

    test "describes duplicate options" do
      assert OptionError.exception(key: [:rate], value: [rate: 1, rate: 2], reason: :duplicate) ==
               %OptionError{
                 key: [:rate],
                 value: [rate: 1, rate: 2],
                 reason: :duplicate,
                 message: "duplicate options: [rate: 1, rate: 2]"
               }
    end
  end

  describe "exception/1 with details" do
    test "adds the details to a missing option" do
      assert OptionError.exception(
               key: :rate,
               value: nil,
               reason: :missing,
               details: "expected a positive integer"
             ) ==
               %OptionError{
                 key: :rate,
                 value: nil,
                 reason: :missing,
                 message: "missing required option: :rate; expected a positive integer"
               }
    end

    test "adds the details to an invalid value" do
      assert OptionError.exception(
               key: :rate,
               value: 0,
               reason: :invalid,
               details: "expected a positive integer"
             ) ==
               %OptionError{
                 key: :rate,
                 value: 0,
                 reason: :invalid,
                 message: "invalid value for option: :rate, got: 0; expected a positive integer"
               }
    end

    test "adds the details to unknown options" do
      assert OptionError.exception(
               key: [:foo],
               value: [foo: 1],
               reason: :unknown,
               details: "allowed options: [:rate]"
             ) ==
               %OptionError{
                 key: [:foo],
                 value: [foo: 1],
                 reason: :unknown,
                 message: "unknown options: [foo: 1]; allowed options: [:rate]"
               }
    end

    test "adds the details to empty options" do
      assert OptionError.exception(
               key: nil,
               value: [],
               reason: :empty,
               details: "allowed options: [:rate]"
             ) ==
               %OptionError{
                 key: nil,
                 value: [],
                 reason: :empty,
                 message:
                   "no options were given where at least one is required; allowed options: [:rate]"
               }
    end

    test "adds the details to duplicate options" do
      assert OptionError.exception(
               key: [:rate],
               value: [rate: 1, rate: 2],
               reason: :duplicate,
               details: "give each option once"
             ) ==
               %OptionError{
                 key: [:rate],
                 value: [rate: 1, rate: 2],
                 reason: :duplicate,
                 message: "duplicate options: [rate: 1, rate: 2]; give each option once"
               }
    end
  end

  describe "exception/1 with missing fields" do
    test "raises without a key" do
      error =
        assert_raise KeyError, fn ->
          OptionError.exception(value: 0, reason: :invalid)
        end

      assert error.key == :key
    end

    test "raises without a value" do
      error =
        assert_raise KeyError, fn ->
          OptionError.exception(key: :rate, reason: :invalid)
        end

      assert error.key == :value
    end

    test "raises without a reason" do
      error =
        assert_raise KeyError, fn ->
          OptionError.exception(key: :rate, value: 0)
        end

      assert error.key == :reason
    end
  end

  test "exception/1 accepts only a keyword list" do
    assert_raise FunctionClauseError, fn ->
      OptionError.exception(%{key: :rate, value: 0, reason: :invalid})
    end
  end
end
