defmodule RateLimiter do
  @moduledoc """
  Runs submitted work at a bounded rate.

  Each limiter is one process supervised by the host, named with a literal atom:

      {RateLimiter,
       name: MyApp.SomeApiLimiter,
       algorithm: RateLimiter.Algorithm.LeakyBucket,
       requests_per_second: 3,
       max_waiting: 500,
       max_active: 12}

  Admission is synchronous and bounded; execution is not. Both entry points
  return as soon as the work is accepted, and the work runs later in a
  supervised task, once pacing and concurrency allow:

    * `enqueue/2` sends no reply. Use it when the caller does not need the
      outcome, or when the submitted function delivers its own.
    * `submit/2` returns a reference. The result, or the reason the work failed,
      later arrives as a message tagged with it. Collect it with `await/2`, or
      match it in `handle_info/2`:

          {:ok, ref} = RateLimiter.submit(MyApp.SomeApiLimiter, fn -> work() end)
          RateLimiter.await(ref, 10_000)

  Replies go straight from the task to the submitting process, which monitors
  the limiter through the reply reference. If the limiter stops first, the
  submitter receives `:DOWN` instead. After an `await/2` timeout or `forget/1`,
  a late reply is dropped rather than left in the mailbox. Neither cancels the
  work: once accepted, it runs unless the limiter stops or `discard_waiting/1`
  drops it before it starts, even when its caller has given up or died.

  Work is released in FIFO order, whichever entry point accepted it. When the
  waiting queue is full the limiter rejects new work immediately rather than
  blocking the caller or discarding anything already accepted.

  Pacing is delegated to a `RateLimiter.Algorithm`, named per instance; there is
  no default. The limiter owns scheduling, failure isolation, and reply delivery
  for `submit/2`. Retries, error interpretation, and per-operation timeouts
  belong to the submitted function. A crash loses the queue, which is held in
  memory.

  Each limiter starts its own `Task.Supervisor` and links it instead of placing
  it under a supervisor, so the two always live and die together. That coupling
  is deliberate: a restarted limiter must not inherit tasks from its previous
  incarnation, which would leave an unknown number of requests in flight and
  exceed the configured rate.

  The links are deliberately asymmetric. Tasks are linked to that supervisor, so
  losing either the supervisor or the limiter terminates work still in flight.
  The limiter only monitors its tasks, so a crashing task frees its slot without
  taking the limiter, and the queue, down with it.

  Original implementation inspired by:
  https://akoutmos.com/post/rate-limiting-with-genservers/
  """

  use GenServer

  require Logger

  alias RateLimiter.{Algorithm, Options}

  @typedoc "A supervised limiter, by registered name or pid."
  @type limiter() :: GenServer.server()

  @typedoc "Work to run under the limiter."
  @type task() :: (-> any())

  @typedoc "Waiting work and work currently running."
  @type status() :: %{waiting: non_neg_integer(), active: non_neg_integer()}

  @typedoc "Identifies one `submit/2` and tags its reply."
  @type reply_ref() :: reference()

  @typedoc """
  How submitted work finished: its result, the reason it exited, or that it was
  discarded before starting.
  """
  @type reply() :: {:ok, any()} | {:exit, any()} | {:error, :discarded}

  # A function returning the current monotonic time in milliseconds.
  @typep clock() :: (-> integer())

  @typep state() :: %{
           name: GenServer.name(),
           algorithm: module(),
           algorithm_state: Algorithm.state(),
           task_supervisor: pid(),
           max_waiting: pos_integer(),
           max_active: pos_integer(),
           queue: :queue.queue({reply_ref() | nil, task()}),
           waiting: non_neg_integer(),
           active_tasks: %{reference() => reply_ref() | nil},
           timer: reference() | nil,
           clock: clock(),
           send_after: (pid(), any(), non_neg_integer() -> reference())
         }

  ##############
  # PUBLIC API #
  ##############

  @doc """
  Starts a limiter.

  Requires `:name`, `:algorithm`, `:max_waiting`, and `:max_active`.

  `:clock` and `:send_after` replace `System.monotonic_time/1` and
  `Process.send_after/3` so tests can control time. Production code should
  leave them unset.

  A missing `:name` raises `KeyError` in the caller. Any other missing or
  invalid option, including one the algorithm rejects, raises inside the new
  process, which exits with `{exception, stacktrace}` and never starts. Because
  the caller is linked, one that traps exits, such as a supervisor, receives
  `{:error, {exception, stacktrace}}`; one that does not is terminated by the
  same exit.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Submits `fun` for rate-limited execution without a reply.

  Returns `:ok` once accepted, `{:error, :queue_full}` when the waiting queue is
  at capacity, or `{:error, :not_running}` when no such limiter is alive.
  Acceptance is not completion; use `submit/2` when the caller needs the outcome.
  """
  @spec enqueue(limiter(), task()) :: :ok | {:error, :queue_full} | {:error, :not_running}
  def enqueue(limiter, fun) when is_function(fun, 0) do
    call(limiter, {:enqueue, nil, fun})
  end

  @doc """
  Submits `fun` for rate-limited execution and returns a reference for its reply.

  Returns `{:ok, ref}` once accepted, or the same errors as `enqueue/2`. Unless
  the caller gives up through `await/2` or `forget/1`, exactly one message then
  reaches the calling process:

    * `{ref, {:ok, result}}` when `fun` returns `result`;
    * `{ref, {:exit, reason}}` when it raises, throws, or exits;
    * `{ref, {:error, :discarded}}` when `discard_waiting/1` drops it before it
      starts;
    * `{:DOWN, ref, :process, pid, reason}` when the limiter stops first.

  Only the calling process receives it. A task that submits to its own limiter
  and awaits the reply blocks itself while every slot is busy.
  """
  @spec submit(limiter(), task()) ::
          {:ok, reply_ref()} | {:error, :queue_full} | {:error, :not_running}
  def submit(limiter, fun) when is_function(fun, 0) do
    case GenServer.whereis(limiter) do
      nil -> {:error, :not_running}
      server -> enqueue_with_reply(server, fun)
    end
  end

  @doc """
  Waits up to `timeout` milliseconds, 5000 by default, for the reply to a
  `submit/2`.

  Returns `{:ok, result}` or `{:exit, reason}` as the work finished,
  `{:error, :discarded}` when `discard_waiting/1` dropped it before it started,
  `{:error, :not_running}` when the limiter stopped first, or
  `{:error, :timeout}`. A timeout drops any later reply but does not cancel the
  work. Await each reference once, from the process that submitted it.
  """
  @spec await(reply_ref(), timeout()) :: reply() | {:error, :timeout} | {:error, :not_running}
  def await(ref, timeout \\ 5_000) when is_reference(ref) do
    receive do
      {^ref, reply} -> reply
      {:DOWN, ^ref, :process, _server, _reason} -> {:error, :not_running}
    after
      timeout -> timed_out(ref)
    end
  end

  @doc """
  Gives up on the reply to a `submit/2`.

  Drops the reply, including one already in the mailbox, and stops monitoring
  the limiter. The work still runs unless `discard_waiting/1` drops it first.
  """
  @spec forget(reply_ref()) :: :ok
  def forget(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    receive do
      {^ref, _reply} -> :ok
    after
      0 -> :ok
    end
  end

  @doc """
  Returns the current status of the limiter.

  The status includes the number of waiting and active tasks.
  """
  @spec status(limiter()) :: {:ok, status()} | {:error, :not_running}
  def status(limiter), do: call(limiter, :status)

  @doc """
  Discards all waiting work and returns how many entries were dropped.

  Work already running is unaffected. Each discarded `submit/2` caller receives
  `{ref, {:error, :discarded}}`; discarded `enqueue/2` work is dropped silently.
  Pacing state is kept, so new work is still paced against earlier starts.
  """
  @spec discard_waiting(limiter()) :: {:ok, non_neg_integer()} | {:error, :not_running}
  def discard_waiting(limiter), do: call(limiter, :discard_waiting)

  ######################
  # INTERNAL CALLBACKS #
  ######################

  @doc """
  Returns a specification to start this limiter under a supervisor.

  The child id includes `:name` rather than just the module, so one supervisor
  can run several limiters as siblings. See `Supervisor`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    algorithm = Keyword.fetch!(opts, :algorithm)

    # If any of these calls fail, we do not start the `task_supervisor`.
    max_waiting = Options.positive_integer!(opts, :max_waiting)
    max_active = Options.positive_integer!(opts, :max_active)
    algorithm_state = algorithm.init(opts)

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok,
     %{
       name: Keyword.fetch!(opts, :name),
       algorithm: algorithm,
       algorithm_state: algorithm_state,
       task_supervisor: task_supervisor,
       max_waiting: max_waiting,
       max_active: max_active,
       active_tasks: %{},
       queue: :queue.new(),
       waiting: 0,
       timer: nil,
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       send_after: Keyword.get(opts, :send_after, &Process.send_after/3)
     }}
  end

  @impl GenServer
  @spec handle_call(any(), GenServer.from(), state()) :: {:reply, any(), state()}
  def handle_call(
        {:enqueue, _reply_to, _fun},
        _from,
        %{waiting: waiting, max_waiting: max_waiting} = state
      )
      when waiting >= max_waiting do
    {:reply, {:error, :queue_full}, state}
  end

  def handle_call({:enqueue, reply_to, fun}, _from, state) do
    accepted = %{
      state
      | queue: :queue.in({reply_to, fun}, state.queue),
        waiting: state.waiting + 1
    }

    {:reply, :ok, dispatch(accepted)}
  end

  def handle_call(:status, _from, state) do
    {:reply, {:ok, %{waiting: state.waiting, active: map_size(state.active_tasks)}}, state}
  end

  def handle_call(:discard_waiting, _from, state) do
    state.queue
    |> :queue.to_list()
    |> Enum.each(fn {reply_to, _fun} ->
      notify(reply_to, {:error, :discarded})
    end)

    {:reply, {:ok, state.waiting}, %{state | queue: :queue.new(), waiting: 0}}
  end

  @impl GenServer
  @spec handle_info(any(), state()) :: {:noreply, state()}
  def handle_info(:dispatch, state), do: {:noreply, dispatch(%{state | timer: nil})}

  # A task that finishes replies :ok; one that exits without finishing sends only :DOWN.
  # Flushing discards the trailing :DOWN, so a single task cannot finish twice.
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # This will always succeed, even if the reference was not being monitored
    Process.demonitor(ref, [:flush])

    {:noreply, finish(state, ref, nil)}
  end

  def handle_info({:DOWN, ref, :process, _pid, :normal}, state),
    do: {:noreply, finish(state, ref, {:exit, :normal})}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    Logger.error("RateLimiter #{inspect(state.name)} task failed: #{inspect(reason)}")

    {:noreply, finish(state, ref, {:exit, reason})}
  end

  def handle_info(message, state) do
    Logger.warning(
      "RateLimiter #{inspect(state.name)} ignored unexpected message: #{inspect(message)}"
    )

    {:noreply, state}
  end

  ###################
  # PRIVATE HELPERS #
  ###################

  @spec call(limiter(), any()) :: any() | {:error, :not_running}
  defp call(limiter, message) do
    GenServer.call(limiter, message)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:shutdown, _} -> {:error, :not_running}
    :exit, {{:shutdown, _}, _} -> {:error, :not_running}
  end

  @spec enqueue_with_reply(pid() | {atom(), node()}, task()) ::
          {:ok, reply_ref()} | {:error, :queue_full} | {:error, :not_running}
  defp enqueue_with_reply(server, fun) do
    ref = Process.monitor(server, alias: :reply_demonitor)

    case call(server, {:enqueue, ref, fun}) do
      :ok ->
        {:ok, ref}

      error ->
        forget(ref)
        error
    end
  end

  # A reply can arrive between the timeout and the demonitor.
  @spec timed_out(reply_ref()) :: reply() | {:error, :timeout}
  defp timed_out(ref) do
    Process.demonitor(ref, [:flush])

    receive do
      {^ref, reply} -> reply
    after
      0 -> {:error, :timeout}
    end
  end

  @spec dispatch(state()) :: state()
  defp dispatch(%{waiting: 0} = state), do: state

  defp dispatch(%{timer: timer} = state) when is_reference(timer), do: state

  defp dispatch(%{active_tasks: active_tasks, max_active: max_active} = state)
       when map_size(active_tasks) >= max_active, do: state

  defp dispatch(state) do
    state.algorithm_state
    |> state.algorithm.acquire(state.clock.())
    |> case do
      {:ok, new_algorithm_state} ->
        state
        |> start_next(new_algorithm_state)
        |> dispatch()

      {:wait, wait_time, new_algorithm_state} ->
        %{
          state
          | algorithm_state: new_algorithm_state,
            timer: state.send_after.(self(), :dispatch, wait_time)
        }
    end
  end

  @spec start_next(state(), Algorithm.state()) :: state()
  defp start_next(state, algorithm_state) do
    {{:value, {reply_to, fun}}, remaining} = :queue.out(state.queue)

    %Task{ref: ref} =
      Task.Supervisor.async_nolink(state.task_supervisor, task_body(reply_to, fun))

    %{
      state
      | queue: remaining,
        waiting: state.waiting - 1,
        active_tasks: Map.put(state.active_tasks, ref, reply_to),
        algorithm_state: algorithm_state
    }
  end

  # The task returns only :ok, so a result is never copied into the limiter.
  @spec task_body(reply_ref() | nil, task()) :: (-> :ok)
  defp task_body(nil, fun) do
    fn ->
      fun.()
      :ok
    end
  end

  defp task_body(reply_to, fun) do
    fn ->
      send(reply_to, {reply_to, {:ok, fun.()}})
      :ok
    end
  end

  @spec finish(state(), reference(), {:exit, any()} | nil) :: state()
  defp finish(state, ref, outcome) do
    case Map.pop(state.active_tasks, ref, :unknown) do
      {:unknown, _active_tasks} ->
        Logger.warning(
          "RateLimiter #{inspect(state.name)} attempted to finish unknown task reference: #{inspect(ref)}"
        )

        state

      {reply_to, active_tasks} ->
        notify(reply_to, outcome)
        dispatch(%{state | active_tasks: active_tasks})
    end
  end

  @spec notify(reply_ref() | nil, {:exit, any()} | {:error, :discarded} | nil) :: :ok
  defp notify(reply_to, {_tag, _reason} = reply) when is_reference(reply_to) do
    send(reply_to, {reply_to, reply})
    :ok
  end

  defp notify(_reply_to, _outcome), do: :ok
end
