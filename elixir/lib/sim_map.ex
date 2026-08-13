defmodule BattleBench.SimMap do
  @moduledoc """
  Battle kernel with players stored in a map keyed by player ID.
  """

  import Bitwise

  alias BattleBench.Sim

  @map_w 10_000
  @map_h 10_000
  @player_hp 1000
  @hit_radius 150
  @proj_speed 200
  @proj_ttl 20
  @skill_cooldown 10
  @dot_ticks 5
  @dot_damage 2
  @proj_damage 8
  @golden 0x9E3779B97F4A7C15
  @mask64 0xFFFFFFFFFFFFFFFF

  defdelegate hash_offset(), to: Sim
  defdelegate tick_budget_us(), to: Sim
  defdelegate warmup_ticks(), to: Sim
  defdelegate cast_mod(workload), to: Sim
  defdelegate parse_alloc(alloc), to: Sim
  defdelegate mix(h, x), to: Sim
  defdelegate mix_i32(h, v), to: Sim

  def new_room(seed, room_id, n_players, mode) do
    half = div(n_players, 2)

    players =
      Map.new(0..(n_players - 1), fn i ->
        id = i + 1

        {team, idx_in_team, x} =
          if id > half do
            {2, i - half, 6500}
          else
            {1, i, 3500}
          end

        {id,
         %{
           id: id,
           team: team,
           x: x,
           y: 500 + idx_in_team * 400,
           hp: @player_hp,
           cooldown: 0,
           alive: true
         }}
      end)

    {rng, _} = next(wrap64(bxor(seed, wrap64(room_id * @golden))))

    %{
      mode: mode,
      rng: rng,
      players: players,
      projs: [],
      buffs: [],
      next_proj_id: 1,
      damage_total: 0,
      hash: hash_offset()
    }
  end

  def alive_count(room) do
    Enum.count(room.players, fn {_id, player} -> player.alive end)
  end

  def tick(room, cmod) do
    n = map_size(room.players)

    {players, rng, projs, next_id} =
      move_and_cast(1, n, room.players, room.rng, cmod, room.projs, room.next_proj_id, room.mode)

    {projs, events} = move_projs(projs, players, n, room.mode)
    projs = compact_projs(projs, room.mode)

    room = %{room | players: players, rng: rng, projs: projs, next_proj_id: next_id}

    room =
      Enum.reduce(events, room, fn {target_id, amount}, acc ->
        acc
        |> apply_damage(target_id, amount)
        |> add_buff(target_id)
      end)

    room = tick_buffs(room)
    mix_world(room)
  end

  defp move_and_cast(id, n, players, rng, _cmod, projs, next_id, _mode) when id > n do
    {players, rng, projs, next_id}
  end

  defp move_and_cast(id, n, players, rng, cmod, projs, next_id, mode) do
    {dx_u, rng} = next(rng)
    {dy_u, rng} = next(rng)
    {want_u, rng} = next(rng)
    dx = rem(dx_u, 7) - 3
    dy = rem(dy_u, 7) - 3
    want = rem(want_u, cmod) == 0
    player = Map.fetch!(players, id)

    if not player.alive do
      move_and_cast(id + 1, n, players, rng, cmod, projs, next_id, mode)
    else
      player = %{
        player
        | x: clamp(player.x + dx, 0, @map_w),
          y: clamp(player.y + dy, 0, @map_h),
          cooldown: if(player.cooldown > 0, do: player.cooldown - 1, else: player.cooldown)
      }

      players = Map.put(players, id, player)

      {players, projs, next_id} =
        if want and player.cooldown == 0 do
          case nearest_enemy(players, id, n) do
            nil ->
              {players, projs, next_id}

            target_id ->
              source = Map.fetch!(players, id)
              target = Map.fetch!(players, target_id)
              {vx, vy} = heading(target.x - source.x, target.y - source.y)

              projectile = %{
                id: next_id,
                owner_id: source.id,
                owner_team: source.team,
                x: source.x,
                y: source.y,
                vx: vx,
                vy: vy,
                ttl: @proj_ttl,
                alive: true
              }

              {
                Map.put(players, id, %{source | cooldown: @skill_cooldown}),
                append_item(projs, projectile, mode),
                next_id + 1
              }
          end
        else
          {players, projs, next_id}
        end

      move_and_cast(id + 1, n, players, rng, cmod, projs, next_id, mode)
    end
  end

  defp nearest_enemy(players, self_id, n) do
    self = Map.fetch!(players, self_id)

    Enum.reduce(1..n, nil, fn id, best ->
      candidate = Map.fetch!(players, id)

      cond do
        not candidate.alive or candidate.team == self.team ->
          best

        true ->
          distance = manhattan(self.x, self.y, candidate.x, candidate.y)

          case best do
            nil ->
              {id, distance}

            {best_id, best_distance}
            when distance < best_distance or (distance == best_distance and id < best_id) ->
              {id, distance}

            _ ->
              best
          end
      end
    end)
    |> case do
      nil -> nil
      {id, _distance} -> id
    end
  end

  defp heading(dx, dy) do
    if abs32(dx) >= abs32(dy) do
      {sign32(dx) * @proj_speed, 0}
    else
      {0, sign32(dy) * @proj_speed}
    end
  end

  defp move_projs(projs, players, n, :naive) do
    {out, events} =
      Enum.reduce(projs, {[], []}, fn projectile, {acc, events} ->
        {projectile, hit} = step_proj(projectile, players, n)
        events = if hit, do: append_item(events, hit, :naive), else: events
        {append_item(acc, projectile, :naive), events}
      end)

    {out, events}
  end

  defp move_projs(projs, players, n, :arena) do
    {out_rev, events_rev} =
      Enum.reduce(projs, {[], []}, fn projectile, {acc, events} ->
        {projectile, hit} = step_proj(projectile, players, n)
        events = if hit, do: [hit | events], else: events
        {[projectile | acc], events}
      end)

    {:lists.reverse(out_rev), :lists.reverse(events_rev)}
  end

  defp step_proj(%{alive: false} = projectile, _players, _n), do: {projectile, nil}

  defp step_proj(projectile, players, n) do
    projectile = %{
      projectile
      | x: clamp(projectile.x + projectile.vx, 0, @map_w),
        y: clamp(projectile.y + projectile.vy, 0, @map_h),
        ttl: projectile.ttl - 1
    }

    hit = find_hit(players, projectile, 1, n)

    projectile =
      cond do
        hit != nil -> %{projectile | alive: false}
        projectile.ttl <= 0 -> %{projectile | alive: false}
        true -> projectile
      end

    {projectile, hit}
  end

  defp find_hit(_players, _projectile, id, n) when id > n, do: nil

  defp find_hit(players, projectile, id, n) do
    target = Map.fetch!(players, id)

    if target.alive and target.team != projectile.owner_team and
         manhattan(projectile.x, projectile.y, target.x, target.y) <= @hit_radius do
      {target.id, @proj_damage}
    else
      find_hit(players, projectile, id + 1, n)
    end
  end

  defp compact_projs(projs, :naive), do: Enum.filter(projs, & &1.alive)
  defp compact_projs(projs, :arena), do: :lists.filter(& &1.alive, projs)

  defp tick_buffs(room) do
    room =
      Enum.reduce(room.buffs, room, fn buff, acc ->
        apply_damage(acc, buff.target_id, @dot_damage)
      end)

    buffs =
      room.buffs
      |> Enum.map(&%{&1 | remaining: &1.remaining - 1})
      |> Enum.filter(&(&1.remaining > 0))

    %{room | buffs: buffs}
  end

  defp apply_damage(room, target_id, amount) do
    player = Map.fetch!(room.players, target_id)

    if player.alive do
      hp = player.hp - amount
      {hp, alive} = if hp <= 0, do: {0, false}, else: {hp, true}
      player = %{player | hp: hp, alive: alive}

      %{
        room
        | players: Map.put(room.players, target_id, player),
          damage_total: wrap64(room.damage_total + amount)
      }
    else
      room
    end
  end

  defp add_buff(room, target_id) do
    buff = %{target_id: target_id, remaining: @dot_ticks}
    %{room | buffs: append_item(room.buffs, buff, room.mode)}
  end

  defp mix_world(room) do
    n = map_size(room.players)

    h =
      Enum.reduce(1..n, room.hash, fn id, h ->
        player = Map.fetch!(room.players, id)
        alive = if player.alive, do: 1, else: 0

        h
        |> mix(player.id)
        |> mix_i32(player.x)
        |> mix_i32(player.y)
        |> mix_i32(player.hp)
        |> mix(alive)
      end)

    h =
      Enum.reduce(1..n, h, fn id, h ->
        player = Map.fetch!(room.players, id)
        h |> mix_i32(player.cooldown) |> mix(player.team)
      end)

    h =
      Enum.reduce(room.projs, h, fn projectile, h ->
        h
        |> mix(projectile.id)
        |> mix_i32(projectile.x)
        |> mix_i32(projectile.y)
        |> mix_i32(projectile.vx)
        |> mix_i32(projectile.vy)
        |> mix_i32(projectile.ttl)
        |> mix(projectile.owner_id)
      end)

    h =
      Enum.reduce(room.buffs, h, fn buff, h ->
        h |> mix(buff.target_id) |> mix_i32(buff.remaining)
      end)

    %{room | hash: mix(h, room.damage_total)}
  end

  defp next(state) do
    s = wrap64(state + @golden)
    z = wrap64(bxor(s, s >>> 30) * 0xBF58476D1CE4E5B9)
    z = wrap64(bxor(z, z >>> 27) * 0x94D049BB133366EB)
    {bxor(z, z >>> 31), s}
  end

  defp append_item(list, item, :naive), do: list ++ [item]
  defp append_item(list, item, :arena), do: list ++ [item]

  defp wrap64(n), do: n &&& @mask64
  defp abs32(v) when v < 0, do: -v
  defp abs32(v), do: v
  defp sign32(v) when v > 0, do: 1
  defp sign32(v) when v < 0, do: -1
  defp sign32(_), do: 0
  defp clamp(v, lo, _hi) when v < lo, do: lo
  defp clamp(v, _lo, hi) when v > hi, do: hi
  defp clamp(v, _, _), do: v
  defp manhattan(x1, y1, x2, y2), do: abs32(x1 - x2) + abs32(y1 - y2)
end
