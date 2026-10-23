defmodule RateLimiter.Algorithm.LeakyBucketTest do
  use ExUnit.Case, async: true

  alias RateLimiter.Algorithm.LeakyBucket
  alias RateLimiter.OptionError

  test "three requests per second space starts 334 ms apart" do
    {:ok, bucket} = LeakyBucket.init(requests_per_second: 3)
    {:ok, bucket} = LeakyBucket.acquire(bucket, 0)

    assert LeakyBucket.acquire(bucket, 333) == {:wait, 1, bucket}
    assert {:ok, _bucket} = LeakyBucket.acquire(bucket, 334)
  end

  test "a rate that does not divide a second rounds the interval up" do
    {:ok, bucket} = LeakyBucket.init(requests_per_second: 7)
    {:ok, bucket} = LeakyBucket.acquire(bucket, 0)

    assert LeakyBucket.acquire(bucket, 142) == {:wait, 1, bucket}
    assert {:ok, _bucket} = LeakyBucket.acquire(bucket, 143)
  end

  test "a rate that divides a second uses the exact interval" do
    {:ok, bucket} = LeakyBucket.init(requests_per_second: 4)
    {:ok, bucket} = LeakyBucket.acquire(bucket, 0)

    assert LeakyBucket.acquire(bucket, 249) == {:wait, 1, bucket}
    assert {:ok, _bucket} = LeakyBucket.acquire(bucket, 250)
  end

  test "the fastest supported rate spaces starts one millisecond apart" do
    {:ok, bucket} = LeakyBucket.init(requests_per_second: 1_000)
    {:ok, bucket} = LeakyBucket.acquire(bucket, 0)

    assert LeakyBucket.acquire(bucket, 0) == {:wait, 1, bucket}
    assert {:ok, _bucket} = LeakyBucket.acquire(bucket, 1)
  end

  test "the first start is granted immediately, even at a negative monotonic time" do
    {:ok, bucket} = LeakyBucket.init(requests_per_second: 3)

    assert {:ok, _bucket} = LeakyBucket.acquire(bucket, -576_460_752_303)
  end

  test "a second acquire at the same instant waits the full interval" do
    {:ok, state} = LeakyBucket.init(requests_per_second: 3)

    {:ok, bucket} = LeakyBucket.acquire(state, 1_000)
    assert LeakyBucket.acquire(bucket, 1_000) == {:wait, 334, bucket}
  end

  test "a late acquire grants one start and measures the next from it, with no catch-up" do
    {:ok, state} = LeakyBucket.init(requests_per_second: 3)

    {:ok, bucket} = LeakyBucket.acquire(state, 0)
    {:ok, late_bucket} = LeakyBucket.acquire(bucket, 5_000)

    assert LeakyBucket.acquire(late_bucket, 5_333) == {:wait, 1, late_bucket}
  end

  test "allowed_options lists the rate" do
    assert LeakyBucket.allowed_options() == [:requests_per_second]
  end

  test "init ignores options that belong to others" do
    assert LeakyBucket.init(requests_per_second: 3, max_active: 5) ==
             LeakyBucket.init(requests_per_second: 3)
  end

  test "init requires :requests_per_second" do
    assert LeakyBucket.init([]) ==
             {:error,
              %OptionError{
                key: :requests_per_second,
                value: nil,
                reason: :missing,
                message: "missing required option: :requests_per_second"
              }}
  end

  test "init rejects a rate below one request per second" do
    assert LeakyBucket.init(requests_per_second: 0) ==
             {:error,
              %OptionError{
                key: :requests_per_second,
                value: 0,
                reason: :invalid,
                message:
                  "invalid value for option: :requests_per_second, got: 0; expected an integer in range 1..1000 with step 1"
              }}
  end

  test "init rejects a rate above one request per millisecond" do
    assert LeakyBucket.init(requests_per_second: 1_001) ==
             {:error,
              %OptionError{
                key: :requests_per_second,
                value: 1_001,
                reason: :invalid,
                message:
                  "invalid value for option: :requests_per_second, got: 1001; expected an integer in range 1..1000 with step 1"
              }}
  end

  test "init rejects a non-integer rate" do
    assert LeakyBucket.init(requests_per_second: 2.5) ==
             {:error,
              %OptionError{
                key: :requests_per_second,
                value: 2.5,
                reason: :invalid,
                message:
                  "invalid value for option: :requests_per_second, got: 2.5; expected an integer in range 1..1000 with step 1"
              }}
  end

  test "a raised rate measures the next start from the previous one" do
    {:ok, bucket} = LeakyBucket.init(requests_per_second: 1)
    {:ok, bucket} = LeakyBucket.acquire(bucket, 0)

    {:ok, faster} = LeakyBucket.reconfigure(bucket, [requests_per_second: 4], 100)

    assert LeakyBucket.acquire(faster, 249) == {:wait, 1, faster}
    assert {:ok, _bucket} = LeakyBucket.acquire(faster, 250)
  end

  test "a lowered rate measures the next start from the previous one" do
    {:ok, bucket} = LeakyBucket.init(requests_per_second: 4)
    {:ok, bucket} = LeakyBucket.acquire(bucket, 0)

    {:ok, slower} = LeakyBucket.reconfigure(bucket, [requests_per_second: 1], 100)

    assert LeakyBucket.acquire(slower, 250) == {:wait, 750, slower}
    assert {:ok, _bucket} = LeakyBucket.acquire(slower, 1_000)
  end

  test "a rate changed before the first start paces from that start" do
    {:ok, bucket} = LeakyBucket.init(requests_per_second: 1)

    {:ok, faster} = LeakyBucket.reconfigure(bucket, [requests_per_second: 4], 0)
    {:ok, started} = LeakyBucket.acquire(faster, 0)

    assert LeakyBucket.acquire(started, 0) == {:wait, 250, started}
  end

  test "reconfigure rejects a rate above one request per millisecond" do
    {:ok, bucket} = LeakyBucket.init(requests_per_second: 1)

    assert LeakyBucket.reconfigure(bucket, [requests_per_second: 1_001], 0) ==
             {:error,
              %OptionError{
                key: :requests_per_second,
                value: 1_001,
                reason: :invalid,
                message:
                  "invalid value for option: :requests_per_second, got: 1001; expected an integer in range 1..1000 with step 1"
              }}
  end

  test "reconfigure requires :requests_per_second" do
    {:ok, bucket} = LeakyBucket.init(requests_per_second: 1)

    assert LeakyBucket.reconfigure(bucket, [], 0) ==
             {:error,
              %OptionError{
                key: :requests_per_second,
                value: nil,
                reason: :missing,
                message: "missing required option: :requests_per_second"
              }}
  end
end
