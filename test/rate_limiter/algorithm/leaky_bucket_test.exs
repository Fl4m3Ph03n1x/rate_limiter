defmodule RateLimiter.Algorithm.LeakyBucketTest do
  use ExUnit.Case, async: true

  alias RateLimiter.Algorithm.LeakyBucket

  test "three requests per second space starts 334 ms apart" do
    {:ok, bucket} = LeakyBucket.acquire(LeakyBucket.init(requests_per_second: 3), 0)

    assert LeakyBucket.acquire(bucket, 333) == {:wait, 1, bucket}
    assert {:ok, _bucket} = LeakyBucket.acquire(bucket, 334)
  end

  test "a rate that does not divide a second rounds the interval up" do
    {:ok, bucket} = LeakyBucket.acquire(LeakyBucket.init(requests_per_second: 7), 0)

    assert LeakyBucket.acquire(bucket, 142) == {:wait, 1, bucket}
    assert {:ok, _bucket} = LeakyBucket.acquire(bucket, 143)
  end

  test "a rate that divides a second uses the exact interval" do
    {:ok, bucket} = LeakyBucket.acquire(LeakyBucket.init(requests_per_second: 4), 0)

    assert LeakyBucket.acquire(bucket, 249) == {:wait, 1, bucket}
    assert {:ok, _bucket} = LeakyBucket.acquire(bucket, 250)
  end

  test "the fastest supported rate spaces starts one millisecond apart" do
    {:ok, bucket} = LeakyBucket.acquire(LeakyBucket.init(requests_per_second: 1_000), 0)

    assert LeakyBucket.acquire(bucket, 0) == {:wait, 1, bucket}
    assert {:ok, _bucket} = LeakyBucket.acquire(bucket, 1)
  end

  test "the first start is granted immediately, even at a negative monotonic time" do
    bucket = LeakyBucket.init(requests_per_second: 3)

    assert {:ok, _bucket} = LeakyBucket.acquire(bucket, -576_460_752_303)
  end

  test "a second acquire at the same instant waits the full interval" do
    state = LeakyBucket.init(requests_per_second: 3)

    {:ok, bucket} = LeakyBucket.acquire(state, 1_000)
    assert LeakyBucket.acquire(bucket, 1_000) == {:wait, 334, bucket}
  end

  test "a late acquire grants one start and measures the next from it, with no catch-up" do
    state = LeakyBucket.init(requests_per_second: 3)

    {:ok, bucket} = LeakyBucket.acquire(state, 0)
    {:ok, late_bucket} = LeakyBucket.acquire(bucket, 5_000)

    assert LeakyBucket.acquire(late_bucket, 5_333) == {:wait, 1, late_bucket}
  end

  test "init requires :requests_per_second" do
    assert_raise KeyError, fn -> LeakyBucket.init([]) end
  end

  test "init rejects a rate below one request per second" do
    assert_raise ArgumentError,
                 ":requests_per_second must be a positive integer, got: 0",
                 fn -> LeakyBucket.init(requests_per_second: 0) end
  end

  test "init rejects a rate above one request per millisecond" do
    assert_raise ArgumentError,
                 ":requests_per_second must be an integer less than or equal to 1000, got: 1001",
                 fn -> LeakyBucket.init(requests_per_second: 1_001) end
  end

  test "init rejects a non-integer rate" do
    assert_raise ArgumentError,
                 ":requests_per_second must be a positive integer, got: 2.5",
                 fn -> LeakyBucket.init(requests_per_second: 2.5) end
  end
end
