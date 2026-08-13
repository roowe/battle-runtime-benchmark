package main

// Kernel (must match rust/src/sim.rs):
//
// Integer world, no floats. One splitmix64 stream per room.
// Each tick, every player consumes exactly 3 RNG values (dx, dy, cast),
// even if dead. Tick order:
//   1. movement + skill (spawn projectile; new proj does not move this tick)
//   2. existing projectiles move, first manhattan hit in player-id order
//   3. apply DamageEvent list in append order (hp damage + DoT buff)
//   4. tick buffs in list order, then compact
//   5. allocate a fresh snapshot and mix into room hash
//
// Teams: ids 1..=n/2 team 1 (x=3500), rest team 2 (x=6500).
// Projectile heading is axis-aligned; |dx| >= |dy| prefers x.

const (
	mapW          int32  = 10000
	mapH          int32  = 10000
	playerHP      int32  = 1000
	hitRadius     int32  = 150
	projSpeed     int32  = 200
	projTTL       int32  = 20
	skillCooldown int32  = 10
	dotTicks      int32  = 5
	dotDamage     int32  = 2
	projDamage    int32  = 8
	hashOffset    uint64 = 0xcbf29ce484222325
	golden        uint64 = 0x9e3779b97f4a7c15
	mixMul        uint64 = 0xbf58476d1ce4e5b9
	tickBudgetUs  int64  = 50_000
	warmupTicks   int    = 20
)

type rng struct {
	state uint64
}

func newRNG(seed uint64) rng {
	return rng{state: seed}
}

func (r *rng) next() uint64 {
	r.state += golden
	z := r.state
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133366eb
	return z ^ (z >> 31)
}

func mix(h, x uint64) uint64 {
	x ^= golden
	x *= mixMul
	x ^= x >> 27
	h ^= x
	h *= golden
	return h
}

func mixI32(h uint64, v int32) uint64 {
	return mix(h, uint64(uint32(v)))
}

func roomSeed(seed uint64, roomID uint32) uint64 {
	r := newRNG(seed ^ (uint64(roomID) * golden))
	return r.next()
}

func abs32(v int32) int32 {
	if v < 0 {
		return -v
	}
	return v
}

func sign32(v int32) int32 {
	switch {
	case v > 0:
		return 1
	case v < 0:
		return -1
	default:
		return 0
	}
}

func clamp32(v, lo, hi int32) int32 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func manhattan(x1, y1, x2, y2 int32) int32 {
	return abs32(x1-x2) + abs32(y1-y2)
}

func castMod(workload string) (uint64, bool) {
	switch workload {
	case "low":
		return 50, true
	case "medium":
		return 10, true
	case "high":
		return 3, true
	case "insane":
		return 1, true
	default:
		return 0, false
	}
}

func parseAlloc(s string) (arena bool, ok bool) {
	switch s {
	case "naive":
		return false, true
	case "arena":
		return true, true
	default:
		return false, false
	}
}

type player struct {
	id       uint32
	team     uint8
	x, y     int32
	hp       int32
	cooldown int32
	alive    bool
}

type projectile struct {
	id        uint32
	ownerID   uint32
	ownerTeam uint8
	x, y      int32
	vx, vy    int32
	ttl       int32
	alive     bool
}

type buff struct {
	targetID  uint32
	remaining int32
}

type damageEvent struct {
	sourceID uint32
	targetID uint32
	amount   int32
}

type snap struct {
	id    uint32
	x, y  int32
	hp    int32
	alive uint8
}

type room struct {
	arena       bool
	rng         rng
	players     []player
	projs       []projectile
	projPtrs    []*projectile
	buffs       []buff
	buffPtrs    []*buff
	events      []damageEvent
	snap        []snap
	nextProjID  uint32
	damageTotal uint64
	hash        uint64
}

func newRoom(seed uint64, roomID, nPlayers uint32, arena bool) *room {
	r := &room{
		arena:      arena,
		rng:        newRNG(roomSeed(seed, roomID)),
		players:    make([]player, nPlayers),
		nextProjID: 1,
		hash:       hashOffset,
	}
	if arena {
		r.projs = make([]projectile, 0, 64)
		r.buffs = make([]buff, 0, 64)
		r.events = make([]damageEvent, 0, 64)
		r.snap = make([]snap, nPlayers)
	}
	half := nPlayers / 2
	for i := uint32(0); i < nPlayers; i++ {
		id := i + 1
		team := uint8(1)
		idxInTeam := i
		x := int32(3500)
		if id > half {
			team = 2
			idxInTeam = i - half
			x = 6500
		}
		r.players[i] = player{
			id:    id,
			team:  team,
			x:     x,
			y:     500 + int32(idxInTeam)*400,
			hp:    playerHP,
			alive: true,
		}
	}
	return r
}

func nearestEnemy(players []player, selfIdx int) (int, bool) {
	self := players[selfIdx]
	best := -1
	bestDist := int32(1 << 30)
	var bestID uint32
	for i := range players {
		p := players[i]
		if !p.alive || p.team == self.team {
			continue
		}
		d := manhattan(self.x, self.y, p.x, p.y)
		if best < 0 || d < bestDist || (d == bestDist && p.id < bestID) {
			best = i
			bestDist = d
			bestID = p.id
		}
	}
	return best, best >= 0
}

func (r *room) spawnProj(src, tgt *player) {
	dx := tgt.x - src.x
	dy := tgt.y - src.y
	var vx, vy int32
	if abs32(dx) >= abs32(dy) {
		vx = sign32(dx) * projSpeed
	} else {
		vy = sign32(dy) * projSpeed
	}
	p := projectile{
		id:        r.nextProjID,
		ownerID:   src.id,
		ownerTeam: src.team,
		x:         src.x,
		y:         src.y,
		vx:        vx,
		vy:        vy,
		ttl:       projTTL,
		alive:     true,
	}
	if r.arena {
		r.projs = append(r.projs, p)
	} else {
		hp := new(projectile)
		*hp = p
		r.projPtrs = append(r.projPtrs, hp)
	}
	r.nextProjID++
}

func (r *room) nProj() int {
	if r.arena {
		return len(r.projs)
	}
	return len(r.projPtrs)
}

func (r *room) projAt(i int) *projectile {
	if r.arena {
		return &r.projs[i]
	}
	return r.projPtrs[i]
}

func (r *room) compactProj() {
	if r.arena {
		n := 0
		for i := range r.projs {
			if r.projs[i].alive {
				r.projs[n] = r.projs[i]
				n++
			}
		}
		r.projs = r.projs[:n]
		return
	}
	n := 0
	for _, p := range r.projPtrs {
		if p.alive {
			r.projPtrs[n] = p
			n++
		}
	}
	for i := n; i < len(r.projPtrs); i++ {
		r.projPtrs[i] = nil
	}
	r.projPtrs = r.projPtrs[:n]
}

func (r *room) nBuff() int {
	if r.arena {
		return len(r.buffs)
	}
	return len(r.buffPtrs)
}

func (r *room) buffAt(i int) *buff {
	if r.arena {
		return &r.buffs[i]
	}
	return r.buffPtrs[i]
}

func (r *room) addBuff(targetID uint32) {
	b := buff{targetID: targetID, remaining: dotTicks}
	if r.arena {
		r.buffs = append(r.buffs, b)
		return
	}
	hp := new(buff)
	*hp = b
	r.buffPtrs = append(r.buffPtrs, hp)
}

func (r *room) compactBuff() {
	if r.arena {
		n := 0
		for i := range r.buffs {
			if r.buffs[i].remaining > 0 {
				r.buffs[n] = r.buffs[i]
				n++
			}
		}
		r.buffs = r.buffs[:n]
		return
	}
	n := 0
	for _, b := range r.buffPtrs {
		if b.remaining > 0 {
			r.buffPtrs[n] = b
			n++
		}
	}
	for i := n; i < len(r.buffPtrs); i++ {
		r.buffPtrs[i] = nil
	}
	r.buffPtrs = r.buffPtrs[:n]
}

func (r *room) applyDamage(targetID uint32, amount int32) {
	p := &r.players[targetID-1]
	if !p.alive {
		return
	}
	p.hp -= amount
	r.damageTotal += uint64(amount)
	if p.hp <= 0 {
		p.hp = 0
		p.alive = false
	}
}

func (r *room) tick(cmod uint64) {
	for i := range r.players {
		p := &r.players[i]
		dx := int32(r.rng.next()%7) - 3
		dy := int32(r.rng.next()%7) - 3
		want := r.rng.next()%cmod == 0
		if !p.alive {
			continue
		}
		p.x = clamp32(p.x+dx, 0, mapW)
		p.y = clamp32(p.y+dy, 0, mapH)
		if p.cooldown > 0 {
			p.cooldown--
		}
		if want && p.cooldown == 0 {
			if tgt, ok := nearestEnemy(r.players, i); ok {
				r.spawnProj(p, &r.players[tgt])
				p.cooldown = skillCooldown
			}
		}
	}

	var eventPtrs []*damageEvent
	if r.arena {
		r.events = r.events[:0]
	}
	for i := 0; i < r.nProj(); i++ {
		pr := r.projAt(i)
		if !pr.alive {
			continue
		}
		pr.x = clamp32(pr.x+pr.vx, 0, mapW)
		pr.y = clamp32(pr.y+pr.vy, 0, mapH)
		pr.ttl--
		for j := range r.players {
			t := &r.players[j]
			if !t.alive || t.team == pr.ownerTeam {
				continue
			}
			if manhattan(pr.x, pr.y, t.x, t.y) <= hitRadius {
				ev := damageEvent{pr.ownerID, t.id, projDamage}
				if r.arena {
					r.events = append(r.events, ev)
				} else {
					hp := new(damageEvent)
					*hp = ev
					eventPtrs = append(eventPtrs, hp)
				}
				pr.alive = false
				break
			}
		}
		if pr.ttl <= 0 {
			pr.alive = false
		}
	}
	r.compactProj()

	if r.arena {
		for i := range r.events {
			e := r.events[i]
			r.applyDamage(e.targetID, e.amount)
			r.addBuff(e.targetID)
		}
	} else {
		for _, e := range eventPtrs {
			r.applyDamage(e.targetID, e.amount)
			r.addBuff(e.targetID)
		}
	}

	nBuff := r.nBuff()
	for i := 0; i < nBuff; i++ {
		b := r.buffAt(i)
		r.applyDamage(b.targetID, dotDamage)
		b.remaining--
	}
	r.compactBuff()

	if r.arena {
		if cap(r.snap) < len(r.players) {
			r.snap = make([]snap, len(r.players))
		} else {
			r.snap = r.snap[:len(r.players)]
		}
		for i, p := range r.players {
			alive := uint8(0)
			if p.alive {
				alive = 1
			}
			r.snap[i] = snap{p.id, p.x, p.y, p.hp, alive}
		}
		r.mixWorld(r.snap)
	} else {
		snapBuf := make([]snap, len(r.players))
		for i, p := range r.players {
			alive := uint8(0)
			if p.alive {
				alive = 1
			}
			snapBuf[i] = snap{p.id, p.x, p.y, p.hp, alive}
		}
		r.mixWorld(snapBuf)
	}
}

func (r *room) mixWorld(snapBuf []snap) {
	h := r.hash
	for _, s := range snapBuf {
		h = mix(h, uint64(s.id))
		h = mixI32(h, s.x)
		h = mixI32(h, s.y)
		h = mixI32(h, s.hp)
		h = mix(h, uint64(s.alive))
	}
	for i := range r.players {
		p := r.players[i]
		h = mixI32(h, p.cooldown)
		h = mix(h, uint64(p.team))
	}
	for i := 0; i < r.nProj(); i++ {
		pr := r.projAt(i)
		h = mix(h, uint64(pr.id))
		h = mixI32(h, pr.x)
		h = mixI32(h, pr.y)
		h = mixI32(h, pr.vx)
		h = mixI32(h, pr.vy)
		h = mixI32(h, pr.ttl)
		h = mix(h, uint64(pr.ownerID))
	}
	for i := 0; i < r.nBuff(); i++ {
		b := r.buffAt(i)
		h = mix(h, uint64(b.targetID))
		h = mixI32(h, b.remaining)
	}
	h = mix(h, r.damageTotal)
	r.hash = h
}

func (r *room) aliveCount() int {
	n := 0
	for i := range r.players {
		if r.players[i].alive {
			n++
		}
	}
	return n
}
