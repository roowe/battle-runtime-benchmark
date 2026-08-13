defmodule BattleBench.SimList do
  @moduledoc """
  Battle kernel with runtime entities stored as ordered Elixir lists of Erlang records.
  """

  import Bitwise
  require Record

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

  Record.defrecordp(:player,
    id: 0,
    team: 0,
    x: 0,
    y: 0,
    hp: @player_hp,
    cooldown: 0,
    alive: true
  )

  Record.defrecordp(:projectile,
    id: 0,
    owner_id: 0,
    owner_team: 0,
    x: 0,
    y: 0,
    vx: 0,
    vy: 0,
    ttl: @proj_ttl,
    alive: true
  )

  Record.defrecordp(:buff, target_id: 0, remaining: @dot_ticks)
  Record.defrecordp(:damage_event, target_id: 0, amount: 0)

  defdelegate hash_offset(), to: Sim
  defdelegate tick_budget_us(), to: Sim
  defdelegate warmup_ticks(), to: Sim
  defdelegate cast_mod(workload), to: Sim
  defdelegate mix(h, x), to: Sim
  defdelegate mix_i32(h, v), to: Sim

  def new_room(seed, room_id, n_players, _alloc) do
    half = div(n_players, 2)

    players =
      for i <- 0..(n_players - 1) do
        id = i + 1

        {team, idx_in_team, x} =
          if id > half do
            {2, i - half, 6500}
          else
            {1, i, 3500}
          end

        player(
          id: id,
          team: team,
          x: x,
          y: 500 + idx_in_team * 400,
          hp: @player_hp,
          cooldown: 0,
          alive: true
        )
      end

    {rng, _} = next(wrap64(bxor(seed, wrap64(room_id * @golden))))

    %{
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
    Enum.count(room.players, fn p -> player(p, :alive) end)
  end

  def tick(room, cmod) do
    {players, rng, spawned, next_id} =
      move_and_cast(
        room.players,
        [],
        room.rng,
        cmod,
        [],
        room.next_proj_id
      )

    projs = append_new(room.projs, spawned)
    {projs, events} = move_projs(projs, players, [], [])

    room = %{room | players: players, rng: rng, projs: projs, next_proj_id: next_id}
    room = apply_events(events, room, [])
    room = tick_buffs(room)
    mix_world(room)
  end

  defp move_and_cast([], moved_rev, rng, _cmod, spawned_rev, next_id) do
    {Enum.reverse(moved_rev), rng, Enum.reverse(spawned_rev), next_id}
  end

  defp move_and_cast([p | rest], moved_rev, rng, cmod, spawned_rev, next_id) do
    {dx_u, rng} = next(rng)
    {dy_u, rng} = next(rng)
    {want_u, rng} = next(rng)
    dx = rem(dx_u, 7) - 3
    dy = rem(dy_u, 7) - 3
    want = rem(want_u, cmod) == 0

    if not player(p, :alive) do
      move_and_cast(rest, [p | moved_rev], rng, cmod, spawned_rev, next_id)
    else
      cooldown = player(p, :cooldown)

      p =
        player(p,
          x: clamp(player(p, :x) + dx, 0, @map_w),
          y: clamp(player(p, :y) + dy, 0, @map_h),
          cooldown: if(cooldown > 0, do: cooldown - 1, else: cooldown)
        )

      {p, spawned_rev, next_id} =
        if want and player(p, :cooldown) == 0 do
          case nearest_enemy(moved_rev, rest, p) do
            nil ->
              {p, spawned_rev, next_id}

            target ->
              {vx, vy} =
                heading(player(target, :x) - player(p, :x), player(target, :y) - player(p, :y))

              pr =
                projectile(
                  id: next_id,
                  owner_id: player(p, :id),
                  owner_team: player(p, :team),
                  x: player(p, :x),
                  y: player(p, :y),
                  vx: vx,
                  vy: vy,
                  ttl: @proj_ttl,
                  alive: true
                )

              {
                player(p, cooldown: @skill_cooldown),
                [pr | spawned_rev],
                next_id + 1
              }
          end
        else
          {p, spawned_rev, next_id}
        end

      move_and_cast(rest, [p | moved_rev], rng, cmod, spawned_rev, next_id)
    end
  end

  defp nearest_enemy(moved_rev, rest, self) do
    best = nearest_in(moved_rev, self, nil)

    case nearest_in(rest, self, best) do
      nil -> nil
      {target, _distance, _id} -> target
    end
  end

  defp nearest_in([], _self, best), do: best

  defp nearest_in([candidate | rest], self, best) do
    best =
      if player(candidate, :alive) and player(candidate, :team) != player(self, :team) do
        distance =
          manhattan(
            player(self, :x),
            player(self, :y),
            player(candidate, :x),
            player(candidate, :y)
          )

        choose_nearer(best, candidate, distance)
      else
        best
      end

    nearest_in(rest, self, best)
  end

  defp choose_nearer(nil, candidate, distance) do
    {candidate, distance, player(candidate, :id)}
  end

  defp choose_nearer({_, best_distance, best_id} = best, candidate, distance) do
    id = player(candidate, :id)

    if distance < best_distance or (distance == best_distance and id < best_id) do
      {candidate, distance, id}
    else
      best
    end
  end

  defp heading(dx, dy) do
    if abs32(dx) >= abs32(dy) do
      {sign32(dx) * @proj_speed, 0}
    else
      {0, sign32(dy) * @proj_speed}
    end
  end

  defp move_projs([], _players, projs_rev, events_rev) do
    {Enum.reverse(projs_rev), Enum.reverse(events_rev)}
  end

  defp move_projs([pr | rest], players, projs_rev, events_rev) do
    {pr, hit} = step_proj(pr, players)
    projs_rev = if projectile(pr, :alive), do: [pr | projs_rev], else: projs_rev
    events_rev = if hit, do: [hit | events_rev], else: events_rev
    move_projs(rest, players, projs_rev, events_rev)
  end

  defp step_proj(pr, players) do
    pr =
      projectile(pr,
        x: clamp(projectile(pr, :x) + projectile(pr, :vx), 0, @map_w),
        y: clamp(projectile(pr, :y) + projectile(pr, :vy), 0, @map_h),
        ttl: projectile(pr, :ttl) - 1
      )

    hit = find_hit(players, pr)

    pr =
      cond do
        hit != nil -> projectile(pr, alive: false)
        projectile(pr, :ttl) <= 0 -> projectile(pr, alive: false)
        true -> pr
      end

    {pr, hit}
  end

  defp find_hit([], _pr), do: nil

  defp find_hit([target | rest], pr) do
    if player(target, :alive) and
         player(target, :team) != projectile(pr, :owner_team) and
         manhattan(
           projectile(pr, :x),
           projectile(pr, :y),
           player(target, :x),
           player(target, :y)
         ) <= @hit_radius do
      damage_event(target_id: player(target, :id), amount: @proj_damage)
    else
      find_hit(rest, pr)
    end
  end

  defp tick_buffs(room) do
    {room, buffs_rev} = tick_buffs(room.buffs, room, [])
    %{room | buffs: Enum.reverse(buffs_rev)}
  end

  defp tick_buffs([], room, buffs_rev), do: {room, buffs_rev}

  defp tick_buffs([current | rest], room, buffs_rev) do
    room = apply_damage(room, buff(current, :target_id), @dot_damage)
    remaining = buff(current, :remaining) - 1

    buffs_rev =
      if remaining > 0 do
        [buff(current, remaining: remaining) | buffs_rev]
      else
        buffs_rev
      end

    tick_buffs(rest, room, buffs_rev)
  end

  defp apply_events([], room, buffs_rev) do
    buffs = append_new(room.buffs, Enum.reverse(buffs_rev))
    %{room | buffs: buffs}
  end

  defp apply_events([event | rest], room, buffs_rev) do
    target_id = damage_event(event, :target_id)
    room = apply_damage(room, target_id, damage_event(event, :amount))
    apply_events(rest, room, [buff(target_id: target_id, remaining: @dot_ticks) | buffs_rev])
  end

  defp apply_damage(room, target_id, amount) do
    case List.keyfind(room.players, target_id, 1) do
      nil ->
        room

      p ->
        if player(p, :alive) do
          hp = player(p, :hp) - amount
          {hp, alive} = if hp <= 0, do: {0, false}, else: {hp, true}
          p = player(p, hp: hp, alive: alive)

          %{
            room
            | players: List.keyreplace(room.players, target_id, 1, p),
              damage_total: wrap64(room.damage_total + amount)
          }
        else
          room
        end
    end
  end

  defp mix_world(room) do
    h =
      Enum.reduce(room.players, room.hash, fn p, h ->
        alive = if player(p, :alive), do: 1, else: 0

        h
        |> mix(player(p, :id))
        |> mix_i32(player(p, :x))
        |> mix_i32(player(p, :y))
        |> mix_i32(player(p, :hp))
        |> mix(alive)
      end)

    h =
      Enum.reduce(room.players, h, fn p, h ->
        h |> mix_i32(player(p, :cooldown)) |> mix(player(p, :team))
      end)

    h =
      Enum.reduce(room.projs, h, fn pr, h ->
        h
        |> mix(projectile(pr, :id))
        |> mix_i32(projectile(pr, :x))
        |> mix_i32(projectile(pr, :y))
        |> mix_i32(projectile(pr, :vx))
        |> mix_i32(projectile(pr, :vy))
        |> mix_i32(projectile(pr, :ttl))
        |> mix(projectile(pr, :owner_id))
      end)

    h =
      Enum.reduce(room.buffs, h, fn current, h ->
        h |> mix(buff(current, :target_id)) |> mix_i32(buff(current, :remaining))
      end)

    %{room | hash: mix(h, room.damage_total)}
  end

  defp next(state) do
    s = wrap64(state + @golden)
    z = wrap64(bxor(s, s >>> 30) * 0xBF58476D1CE4E5B9)
    z = wrap64(bxor(z, z >>> 27) * 0x94D049BB133366EB)
    {bxor(z, z >>> 31), s}
  end

  defp append_new(existing, []), do: existing
  defp append_new(existing, additions), do: existing ++ additions

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
