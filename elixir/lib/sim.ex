defmodule BattleBench.Sim do
  @moduledoc """
  Kernel (must match go/sim.go). Integer world, splitmix64, 3 RNG values per player per tick.
  """

  import Bitwise

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
  @hash_offset 0xCBF29CE484222325
  @golden 0x9E3779B97F4A7C15
  @mix_mul 0xBF58476D1CE4E5B9
  @mask64 0xFFFFFFFFFFFFFFFF
  @mask32 0xFFFFFFFF

  def hash_offset, do: @hash_offset
  def tick_budget_us, do: 50_000
  def warmup_ticks, do: 20

  def cast_mod("low"), do: {:ok, 50}
  def cast_mod("medium"), do: {:ok, 10}
  def cast_mod("high"), do: {:ok, 3}
  def cast_mod("insane"), do: {:ok, 1}
  def cast_mod(_), do: :error

  def parse_alloc("naive"), do: {:ok, :naive}
  def parse_alloc("arena"), do: {:ok, :arena}
  def parse_alloc(_), do: :error

  def mix(h, x) do
    xx = bxor(x, @golden)
    xx = wrap64(xx * @mix_mul)
    xx = bxor(xx, xx >>> 27)
    wrap64(bxor(h, xx) * @golden)
  end

  def mix_i32(h, v), do: mix(h, v &&& @mask32)

  def new_room(seed, room_id, n_players, mode) do
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

        %{
          id: id,
          team: team,
          x: x,
          y: 500 + idx_in_team * 400,
          hp: @player_hp,
          cooldown: 0,
          alive: true
        }
      end
      |> List.to_tuple()

    {rng, _} = next(wrap64(bxor(seed, wrap64(room_id * @golden))))

    %{
      mode: mode,
      rng: rng,
      players: players,
      projs: [],
      buffs: [],
      next_proj_id: 1,
      damage_total: 0,
      hash: @hash_offset
    }
  end

  def alive_count(room) do
    Enum.count(0..(tuple_size(room.players) - 1), fn i -> elem(room.players, i).alive end)
  end

  def tick(room, cmod) do
    n = tuple_size(room.players)

    {players, rng, projs, next_id} =
      move_and_cast(0, n, room.players, room.rng, cmod, room.projs, room.next_proj_id, room.mode)

    {projs, events} = move_projs(projs, players, room.mode)
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

  defp move_and_cast(i, n, players, rng, _cmod, projs, next_id, _mode) when i >= n do
    {players, rng, projs, next_id}
  end

  defp move_and_cast(i, n, players, rng, cmod, projs, next_id, mode) do
    {dx_u, rng} = next(rng)
    {dy_u, rng} = next(rng)
    {want_u, rng} = next(rng)
    dx = rem(dx_u, 7) - 3
    dy = rem(dy_u, 7) - 3
    want = rem(want_u, cmod) == 0
    p = elem(players, i)

    if not p.alive do
      move_and_cast(i + 1, n, players, rng, cmod, projs, next_id, mode)
    else
      p = %{p | x: clamp(p.x + dx, 0, @map_w), y: clamp(p.y + dy, 0, @map_h)}
      p = if p.cooldown > 0, do: %{p | cooldown: p.cooldown - 1}, else: p
      players = put_elem(players, i, p)

      {players, projs, next_id} =
        if want and p.cooldown == 0 do
          case nearest_enemy(players, i) do
            nil ->
              {players, projs, next_id}

            tgt ->
              src = elem(players, i)
              dst = elem(players, tgt)
              {vx, vy} = heading(dst.x - src.x, dst.y - src.y)

              pr = %{
                id: next_id,
                owner_id: src.id,
                owner_team: src.team,
                x: src.x,
                y: src.y,
                vx: vx,
                vy: vy,
                ttl: @proj_ttl,
                alive: true
              }

              players = put_elem(players, i, %{src | cooldown: @skill_cooldown})
              {players, append_item(projs, pr, mode), next_id + 1}
          end
        else
          {players, projs, next_id}
        end

      move_and_cast(i + 1, n, players, rng, cmod, projs, next_id, mode)
    end
  end

  defp heading(dx, dy) do
    if abs32(dx) >= abs32(dy) do
      {sign32(dx) * @proj_speed, 0}
    else
      {0, sign32(dy) * @proj_speed}
    end
  end

  defp move_projs(projs, players, :naive) do
    {out, events} =
      Enum.reduce(projs, {[], []}, fn pr, {acc, events} ->
        {pr, hit} = step_proj(pr, players)
        events = if hit, do: append_item(events, hit, :naive), else: events
        {append_item(acc, pr, :naive), events}
      end)

    {out, events}
  end

  defp move_projs(projs, players, :arena) do
    {out_rev, events_rev} =
      Enum.reduce(projs, {[], []}, fn pr, {acc, events} ->
        {pr, hit} = step_proj(pr, players)
        events = if hit, do: [hit | events], else: events
        {[pr | acc], events}
      end)

    {:lists.reverse(out_rev), :lists.reverse(events_rev)}
  end

  defp step_proj(%{alive: false} = pr, _players), do: {pr, nil}

  defp step_proj(pr, players) do
    pr = %{
      pr
      | x: clamp(pr.x + pr.vx, 0, @map_w),
        y: clamp(pr.y + pr.vy, 0, @map_h),
        ttl: pr.ttl - 1
    }

    n = tuple_size(players)

    hit =
      Enum.find_value(0..(n - 1), fn j ->
        t = elem(players, j)

        if t.alive and t.team != pr.owner_team and
             manhattan(pr.x, pr.y, t.x, t.y) <= @hit_radius do
          {t.id, @proj_damage}
        end
      end)

    pr =
      cond do
        hit != nil -> %{pr | alive: false}
        pr.ttl <= 0 -> %{pr | alive: false}
        true -> pr
      end

    {pr, hit}
  end

  defp compact_projs(projs, :naive), do: Enum.filter(projs, & &1.alive)
  defp compact_projs(projs, :arena), do: :lists.filter(& &1.alive, projs)

  defp tick_buffs(room) do
    room =
      Enum.reduce(room.buffs, room, fn b, acc ->
        apply_damage(acc, b.target_id, @dot_damage)
      end)

    buffs =
      room.buffs
      |> Enum.map(&%{&1 | remaining: &1.remaining - 1})
      |> Enum.filter(&(&1.remaining > 0))

    %{room | buffs: buffs}
  end

  defp apply_damage(room, target_id, amount) do
    i = target_id - 1
    p = elem(room.players, i)

    if not p.alive do
      room
    else
      hp = p.hp - amount
      {hp, alive} = if hp <= 0, do: {0, false}, else: {hp, true}
      p = %{p | hp: hp, alive: alive}
      %{room | players: put_elem(room.players, i, p), damage_total: wrap64(room.damage_total + amount)}
    end
  end

  defp add_buff(room, target_id) do
    b = %{target_id: target_id, remaining: @dot_ticks}
    %{room | buffs: append_item(room.buffs, b, room.mode)}
  end

  defp mix_world(room) do
    n = tuple_size(room.players)

    h =
      Enum.reduce(0..(n - 1), room.hash, fn i, h ->
        p = elem(room.players, i)
        alive = if p.alive, do: 1, else: 0

        h
        |> mix(p.id)
        |> mix_i32(p.x)
        |> mix_i32(p.y)
        |> mix_i32(p.hp)
        |> mix(alive)
      end)

    h =
      Enum.reduce(0..(n - 1), h, fn i, h ->
        p = elem(room.players, i)
        h |> mix_i32(p.cooldown) |> mix(p.team)
      end)

    h =
      Enum.reduce(room.projs, h, fn pr, h ->
        h
        |> mix(pr.id)
        |> mix_i32(pr.x)
        |> mix_i32(pr.y)
        |> mix_i32(pr.vx)
        |> mix_i32(pr.vy)
        |> mix_i32(pr.ttl)
        |> mix(pr.owner_id)
      end)

    h =
      Enum.reduce(room.buffs, h, fn b, h ->
        h |> mix(b.target_id) |> mix_i32(b.remaining)
      end)

    %{room | hash: mix(h, room.damage_total)}
  end

  defp nearest_enemy(players, self_idx) do
    s = elem(players, self_idx)
    n = tuple_size(players)

    Enum.reduce(0..(n - 1), nil, fn i, best ->
      p = elem(players, i)

      cond do
        not p.alive or p.team == s.team ->
          best

        true ->
          d = manhattan(s.x, s.y, p.x, p.y)

          case best do
            nil ->
              {i, d, p.id}

            {_, bd, bid} when d < bd or (d == bd and p.id < bid) ->
              {i, d, p.id}

            _ ->
              best
          end
      end
    end)
    |> case do
      nil -> nil
      {i, _, _} -> i
    end
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
