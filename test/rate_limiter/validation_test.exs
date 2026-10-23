defmodule RateLimiter.ValidationTest do
  use ExUnit.Case, async: true

  alias RateLimiter.{OptionError, Validation}

  defmodule RateOnly do
    @moduledoc """
    Allows a single algorithm option, `:rate`.

    `Validation` only calls `allowed_options/0`, so a test controls which
    algorithm options are known without involving a real algorithm.
    """

    def allowed_options, do: [:rate]
  end

  describe "reject_invalid_start_options/1" do
    test "accepts the limiter's options and the algorithm's" do
      assert Validation.reject_invalid_start_options(
               name: :limiter,
               algorithm: RateOnly,
               max_waiting: 1,
               max_active: 1,
               rate: 3
             ) == :ok
    end

    test "accepts the test-only clock and send_after" do
      assert Validation.reject_invalid_start_options(
               name: :limiter,
               algorithm: RateOnly,
               max_waiting: 1,
               max_active: 1,
               clock: fn -> 0 end,
               send_after: fn _pid, _message, _delay -> make_ref() end
             ) == :ok
    end

    test "leaves the algorithm's values to the algorithm" do
      assert Validation.reject_invalid_start_options(
               name: :limiter,
               algorithm: RateOnly,
               max_waiting: 1,
               max_active: 1,
               rate: "anything"
             ) == :ok
    end

    test "requires an algorithm" do
      assert Validation.reject_invalid_start_options(
               name: :limiter,
               max_waiting: 1,
               max_active: 1
             ) ==
               {:error,
                %OptionError{
                  key: :algorithm,
                  value: nil,
                  reason: :missing,
                  message: "missing required option: :algorithm"
                }}
    end

    test "rejects an algorithm that is not a module name" do
      assert Validation.reject_invalid_start_options(
               name: :limiter,
               algorithm: "RateOnly",
               max_waiting: 1,
               max_active: 1
             ) ==
               {:error,
                %OptionError{
                  key: :algorithm,
                  value: "RateOnly",
                  reason: :invalid,
                  message:
                    "invalid value for option: :algorithm, got: \"RateOnly\"; expected a valid module name"
                }}
    end

    test "raises for a module that is not an algorithm" do
      assert_raise UndefinedFunctionError, fn ->
        Validation.reject_invalid_start_options(
          name: :limiter,
          algorithm: RateLimiter.ValidationTest.Misspelled,
          max_waiting: 1,
          max_active: 1
        )
      end
    end

    test "rejects an option neither the limiter nor the algorithm knows" do
      assert Validation.reject_invalid_start_options(
               name: :limiter,
               algorithm: RateOnly,
               max_waiting: 1,
               max_active: 1,
               burst: 5
             ) ==
               {:error,
                %OptionError{
                  key: [:burst],
                  value: [burst: 5],
                  reason: :unknown,
                  message:
                    "unknown options: [burst: 5]; allowed keys are: name, algorithm, max_waiting, max_active, clock, send_after, rate"
                }}
    end

    test "rejects a repeated option" do
      assert Validation.reject_invalid_start_options(
               name: :limiter,
               algorithm: RateOnly,
               max_waiting: 1,
               max_active: 1,
               max_active: 2
             ) ==
               {:error,
                %OptionError{
                  key: [:max_active],
                  value: [max_active: 1, max_active: 2],
                  reason: :duplicate,
                  message: "duplicate options: [max_active: 1, max_active: 2]"
                }}
    end

    test "requires a name" do
      assert Validation.reject_invalid_start_options(
               algorithm: RateOnly,
               max_waiting: 1,
               max_active: 1
             ) ==
               {:error,
                %OptionError{
                  key: :name,
                  value: nil,
                  reason: :missing,
                  message: "missing required option: :name"
                }}
    end

    test "rejects a nil name" do
      assert Validation.reject_invalid_start_options(
               name: nil,
               algorithm: RateOnly,
               max_waiting: 1,
               max_active: 1
             ) ==
               {:error,
                %OptionError{
                  key: :name,
                  value: nil,
                  reason: :invalid,
                  message:
                    "invalid value for option: :name, got: nil; expected a valid module name"
                }}
    end

    test "requires max_waiting" do
      assert Validation.reject_invalid_start_options(
               name: :limiter,
               algorithm: RateOnly,
               max_active: 1
             ) ==
               {:error,
                %OptionError{
                  key: :max_waiting,
                  value: nil,
                  reason: :missing,
                  message: "missing required option: :max_waiting"
                }}
    end

    test "rejects a max_active that is not a positive integer" do
      assert Validation.reject_invalid_start_options(
               name: :limiter,
               algorithm: RateOnly,
               max_waiting: 1,
               max_active: 0
             ) ==
               {:error,
                %OptionError{
                  key: :max_active,
                  value: 0,
                  reason: :invalid,
                  message:
                    "invalid value for option: :max_active, got: 0; expected a positive integer (> 0)"
                }}
    end

    test "reports an unknown option before an invalid value" do
      assert {:error, %OptionError{reason: :unknown}} =
               Validation.reject_invalid_start_options(
                 name: :limiter,
                 algorithm: RateOnly,
                 max_waiting: 0,
                 max_active: 1,
                 burst: 5
               )
    end

    test "reports a repeated option before an invalid value" do
      assert {:error, %OptionError{reason: :duplicate}} =
               Validation.reject_invalid_start_options(
                 name: :limiter,
                 algorithm: RateOnly,
                 max_waiting: 0,
                 max_active: 1,
                 max_active: 2
               )
    end

    test "checks max_waiting before max_active" do
      assert {:error, %OptionError{key: :max_waiting}} =
               Validation.reject_invalid_start_options(
                 name: :limiter,
                 algorithm: RateOnly,
                 max_waiting: 0,
                 max_active: 0
               )
    end
  end

  describe "reject_empty_reconfiguration/1" do
    test "rejects an empty request" do
      assert Validation.reject_empty_reconfiguration([]) ==
               {:error,
                %OptionError{
                  key: nil,
                  value: [],
                  reason: :empty,
                  message: "no options were given where at least one is required"
                }}
    end

    test "accepts any other request, without checking it" do
      assert Validation.reject_empty_reconfiguration(burst: 5) == :ok
    end
  end

  describe "reject_invalid_reconfiguration/2" do
    test "accepts a change to the algorithm's options alone" do
      assert Validation.reject_invalid_reconfiguration(RateOnly, rate: 5) == :ok
    end

    test "accepts a change to max_active alone" do
      assert Validation.reject_invalid_reconfiguration(RateOnly, max_active: 5) == :ok
    end

    test "accepts a change to max_waiting alone" do
      assert Validation.reject_invalid_reconfiguration(RateOnly, max_waiting: 5) == :ok
    end

    test "leaves the algorithm's values to the algorithm" do
      assert Validation.reject_invalid_reconfiguration(RateOnly, rate: "anything") == :ok
    end

    test "rejects an empty request" do
      assert Validation.reject_invalid_reconfiguration(RateOnly, []) ==
               {:error,
                %OptionError{
                  key: nil,
                  value: [],
                  reason: :empty,
                  message: "no options were given where at least one is required"
                }}
    end

    test "rejects a startup-only option" do
      assert Validation.reject_invalid_reconfiguration(RateOnly, name: :other) ==
               {:error,
                %OptionError{
                  key: [:name],
                  value: [name: :other],
                  reason: :unknown,
                  message:
                    "unknown options: [name: :other]; allowed keys are: max_active, max_waiting, rate"
                }}
    end

    test "rejects a repeated option" do
      assert Validation.reject_invalid_reconfiguration(RateOnly, rate: 1, rate: 2) ==
               {:error,
                %OptionError{
                  key: [:rate],
                  value: [rate: 1, rate: 2],
                  reason: :duplicate,
                  message: "duplicate options: [rate: 1, rate: 2]"
                }}
    end

    test "rejects a max_waiting that is not a positive integer" do
      assert Validation.reject_invalid_reconfiguration(RateOnly, max_waiting: 0) ==
               {:error,
                %OptionError{
                  key: :max_waiting,
                  value: 0,
                  reason: :invalid,
                  message:
                    "invalid value for option: :max_waiting, got: 0; expected a positive integer (> 0)"
                }}
    end

    test "reports an unknown option before an invalid value" do
      assert {:error, %OptionError{reason: :unknown}} =
               Validation.reject_invalid_reconfiguration(RateOnly, max_active: 0, burst: 5)
    end

    test "checks max_waiting before max_active" do
      assert {:error, %OptionError{key: :max_waiting}} =
               Validation.reject_invalid_reconfiguration(RateOnly, max_active: 0, max_waiting: 0)
    end
  end
end
