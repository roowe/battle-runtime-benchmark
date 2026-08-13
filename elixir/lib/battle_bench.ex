defmodule BattleBench do
  @moduledoc false

  alias BattleBench.Sim

  def main(args) do
    case parse_config(args) do
      {:ok, cfg} ->
        IO.puts(:json.encode(run(cfg)))

      {:error, msg} ->
        IO.puts(:stderr, msg)
        System.halt(2)
    end
  end

  defp parse_config(args) do
    {opts, extra, invalid} =
      OptionParser.parse(args,
        strict: [
          seed: :integer,
          rooms: :integer,
          players: :integer,
          ticks: :integer,
          workload: :string,
          alloc: :string,
          player_store: :string
        ]
      )

    cond do
      extra != [] ->
        {:error, "unexpected argument #{inspect(hd(extra))}"}

      invalid != [] ->
        {:error, "unknown or incomplete flag"}

      true ->
        seed = Keyword.get(opts, :seed, 1234)
        rooms = Keyword.get(opts, :rooms, 1)
        players = Keyword.get(opts, :players, 40)
        ticks = Keyword.get(opts, :ticks, 200)
        workload = Keyword.get(opts, :workload, "medium")
        alloc_s = Keyword.get(opts, :alloc, "naive")
        player_store_s = Keyword.get(opts, :player_store, "tuple")

        cond do
          rooms < 1 or players < 2 or ticks < 1 ->
            {:error, "rooms, players, ticks must be positive (players >= 2)"}

          true ->
            with {:ok, cmod} <- Sim.cast_mod(workload),
                 {:ok, alloc} <- Sim.parse_alloc(alloc_s),
                 {:ok, sim} <- parse_player_store(player_store_s) do
              {:ok,
               %{
                 seed: seed,
                 rooms: rooms,
                 players: players,
                 ticks: ticks,
                 workload: workload,
                 alloc: alloc,
                 alloc_s: alloc_s,
                 player_store: player_store_s,
                 sim: sim,
                 cmod: cmod
               }}
            else
              :error ->
                cond do
                  Sim.cast_mod(workload) == :error ->
                    {:error, "unknown workload #{inspect(workload)}"}

                  Sim.parse_alloc(alloc_s) == :error ->
                    {:error, "unknown alloc #{inspect(alloc_s)}"}

                  true ->
                    {:error, "unknown player store #{inspect(player_store_s)}"}
                end
            end
        end
    end
  end

  defp parse_player_store("tuple"), do: {:ok, BattleBench.Sim}
  defp parse_player_store("list"), do: {:ok, BattleBench.SimList}
  defp parse_player_store("map"), do: {:ok, BattleBench.SimMap}
  defp parse_player_store(_), do: :error

  defp run(cfg) do
    {gc0, words0, _} = :erlang.statistics(:garbage_collection)
    {runtime0, _} = :erlang.statistics(:runtime)
    start = System.monotonic_time(:microsecond)

    outs =
      1..cfg.rooms
      |> Enum.map(fn id ->
        Task.async(fn -> simulate_room(cfg, id, start) end)
      end)
      |> Enum.map(&Task.await(&1, :infinity))

    world_hash = Enum.reduce(outs, Sim.hash_offset(), fn o, h -> Sim.mix(h, o.hash) end)
    damage = Enum.reduce(outs, 0, fn o, d -> d + o.damage end)
    alive = Enum.reduce(outs, 0, fn o, a -> a + o.alive end)
    lags = Enum.flat_map(outs, & &1.lags)
    computes = Enum.flat_map(outs, & &1.computes)

    {gc1, words1, _} = :erlang.statistics(:garbage_collection)
    {runtime1, _} = :erlang.statistics(:runtime)
    word = :erlang.system_info(:wordsize)
    lag = summarize(lags)
    comp = summarize(computes)

    %{
      "lang" => "elixir",
      "alloc" => cfg.alloc_s,
      "player_store" => cfg.player_store,
      "ticks" => cfg.ticks,
      "seed" => cfg.seed,
      "rooms" => cfg.rooms,
      "players" => cfg.players,
      "workload" => cfg.workload,
      "world_hash" => hex64(world_hash),
      "damage_total" => damage,
      "alive_players" => alive,
      "tick_p50_us" => lag.p50,
      "tick_p99_us" => lag.p99,
      "tick_p999_us" => lag.p999,
      "tick_max_us" => lag.max,
      "compute_p50_us" => comp.p50,
      "compute_p99_us" => comp.p99,
      "compute_p999_us" => comp.p999,
      "compute_max_us" => comp.max,
      "missed_50ms" => lag.missed50,
      "missed_100ms" => lag.missed100,
      "missed_200ms" => lag.missed200,
      "rss_peak_bytes" => rss_bytes(),
      "cpu_seconds" => (runtime1 - runtime0) / 1000,
      "alloc_bytes" => (words1 - words0) * word,
      "alloc_objects" => gc1 - gc0,
      "os" => os_name(),
      "arch" => arch_name(),
      "rooms_parallel" => true,
      "metric" => "deadline_lag",
      "tick_interval_us" => Sim.tick_budget_us(),
      "runtime" => %{
        "elixir_version" => System.version(),
        "otp_release" => List.to_string(:erlang.system_info(:otp_release)),
        "schedulers_online" => :erlang.system_info(:schedulers_online),
        "gc_count" => gc1 - gc0,
        "gc_words_reclaimed" => words1 - words0,
        "memory_total" => :erlang.memory(:total)
      }
    }
  end

  defp simulate_room(cfg, room_id, start) do
    sim = cfg.sim
    room = sim.new_room(cfg.seed, room_id, cfg.players, cfg.alloc)
    skip_warmup = cfg.ticks > sim.warmup_ticks()
    interval = sim.tick_budget_us()

    {room, lags, computes} =
      Enum.reduce(0..(cfg.ticks - 1), {room, [], []}, fn t, {room, lags, computes} ->
        due = start + t * interval
        wait_deadline(due)
        t0 = System.monotonic_time(:microsecond)
        room = sim.tick(room, cfg.cmod)
        done = System.monotonic_time(:microsecond)
        lag = max(done - due, 0)
        compute = done - t0

        if not skip_warmup or t >= sim.warmup_ticks() do
          {room, [lag | lags], [compute | computes]}
        else
          {room, lags, computes}
        end
      end)

    %{
      hash: room.hash,
      damage: room.damage_total,
      alive: sim.alive_count(room),
      lags: :lists.reverse(lags),
      computes: :lists.reverse(computes)
    }
  end

  defp wait_deadline(due) do
    remaining = due - System.monotonic_time(:microsecond)

    if remaining > 0 do
      case div(remaining + 999, 1000) do
        0 -> :ok
        ms -> Process.sleep(ms)
      end
    else
      :erlang.yield()
    end
  end

  defp summarize(samples) do
    sorted = Enum.sort(samples)
    budget = Sim.tick_budget_us()

    %{
      p50: percentile(sorted, 500),
      p99: percentile(sorted, 990),
      p999: percentile(sorted, 999),
      max: Enum.max(sorted, fn -> 0 end),
      missed50: Enum.count(sorted, &(&1 > budget)),
      missed100: Enum.count(sorted, &(&1 > 100_000)),
      missed200: Enum.count(sorted, &(&1 > 200_000))
    }
  end

  defp percentile([], _), do: 0

  defp percentile(sorted, permille) do
    idx = div((length(sorted) - 1) * permille, 1000)
    Enum.at(sorted, idx)
  end

  defp hex64(n),
    do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")

  defp rss_bytes do
    {out, 0} = System.cmd("ps", ["-o", "rss=", "-p", System.pid()])
    String.to_integer(String.trim(out)) * 1024
  end

  defp os_name do
    case :os.type() do
      {:unix, name} -> Atom.to_string(name)
      {family, name} -> "#{family}/#{name}"
    end
  end

  defp arch_name,
    do: :erlang.system_info(:system_architecture) |> List.to_string() |> String.split("-") |> hd()
end
