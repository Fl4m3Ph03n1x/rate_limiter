defmodule RateLimiter.Algorithm.FixedWindowTest do
  use ExUnit.Case, async: true

  alias RateLimiter.Algorithm.FixedWindow

  test "a window allows requests_per_window starts at the same instant, then waits for it to end" do
    window = FixedWindow.init(requests_per_window: 3, window_duration_ms: 1_000)

    {:ok, window} = FixedWindow.acquire(window, 0)
    {:ok, window} = FixedWindow.acquire(window, 0)
    {:ok, full} = FixedWindow.acquire(window, 0)

    assert FixedWindow.acquire(full, 0) == {:wait, 1_000, full}
  end

  test "the wait is measured from the start of the window, not from the last start" do
    window = FixedWindow.init(requests_per_window: 2, window_duration_ms: 1_000)

    {:ok, window} = FixedWindow.acquire(window, 0)
    {:ok, full} = FixedWindow.acquire(window, 300)

    assert FixedWindow.acquire(full, 400) == {:wait, 600, full}
  end

  test "repeated waits leave the window unchanged" do
    window = FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)
    {:ok, full} = FixedWindow.acquire(window, 0)

    assert FixedWindow.acquire(full, 100) == {:wait, 900, full}
    assert FixedWindow.acquire(full, 200) == {:wait, 800, full}
  end

  test "a new window opens exactly when the previous one ends, with a full limit" do
    window = FixedWindow.init(requests_per_window: 2, window_duration_ms: 1_000)
    {:ok, window} = FixedWindow.acquire(window, 0)
    {:ok, full} = FixedWindow.acquire(window, 0)

    assert FixedWindow.acquire(full, 999) == {:wait, 1, full}

    {:ok, window} = FixedWindow.acquire(full, 1_000)
    {:ok, full} = FixedWindow.acquire(window, 1_000)

    assert FixedWindow.acquire(full, 1_000) == {:wait, 1_000, full}
  end

  test "after an idle period a window opens at the next start, not on a grid" do
    window = FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)
    {:ok, window} = FixedWindow.acquire(window, 0)

    {:ok, full} = FixedWindow.acquire(window, 2_500)

    # A grid anchored at 0 would end this window at 3_000.
    assert FixedWindow.acquire(full, 2_500) == {:wait, 1_000, full}
  end

  test "up to twice requests_per_window starts can happen across a window boundary" do
    window = FixedWindow.init(requests_per_window: 2, window_duration_ms: 1_000)
    {:ok, window} = FixedWindow.acquire(window, 0)
    {:ok, window} = FixedWindow.acquire(window, 999)
    {:ok, window} = FixedWindow.acquire(window, 1_000)

    assert {:ok, _window} = FixedWindow.acquire(window, 1_000)
  end

  test "windows work at negative monotonic times" do
    window = FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)

    {:ok, full} = FixedWindow.acquire(window, -576_460_752_303)

    assert FixedWindow.acquire(full, -576_460_751_803) == {:wait, 500, full}
  end

  test "init accepts limits with no upper bound" do
    window = FixedWindow.init(requests_per_window: 10_000_000, window_duration_ms: 86_400_000)

    assert {:ok, _window} = FixedWindow.acquire(window, 0)
  end

  test "init ignores options that belong to others" do
    assert FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000, max_active: 5) ==
             FixedWindow.init(requests_per_window: 1, window_duration_ms: 1_000)
  end

  test "init requires :requests_per_window" do
    assert_raise KeyError, fn -> FixedWindow.init(window_duration_ms: 1_000) end
  end

  test "init requires :window_duration_ms" do
    assert_raise KeyError, fn -> FixedWindow.init(requests_per_window: 1) end
  end

  test "init rejects a window that allows no requests" do
    assert_raise ArgumentError,
                 ":requests_per_window must be a positive integer, got: 0",
                 fn -> FixedWindow.init(requests_per_window: 0, window_duration_ms: 1_000) end
  end

  test "init rejects a non-integer request limit" do
    assert_raise ArgumentError,
                 ":requests_per_window must be a positive integer, got: 1.5",
                 fn -> FixedWindow.init(requests_per_window: 1.5, window_duration_ms: 1_000) end
  end

  test "init rejects a zero window duration" do
    assert_raise ArgumentError,
                 ":window_duration_ms must be a positive integer, got: 0",
                 fn -> FixedWindow.init(requests_per_window: 1, window_duration_ms: 0) end
  end

  test "init rejects a non-integer window duration" do
    assert_raise ArgumentError,
                 ":window_duration_ms must be a positive integer, got: 333.4",
                 fn -> FixedWindow.init(requests_per_window: 1, window_duration_ms: 333.4) end
  end
end
