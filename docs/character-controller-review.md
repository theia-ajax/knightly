# The Knight's Grimoire: character controller design

The C# design that replaces the knight's GDScript state machine. It's a **design sketch**: complete enough to show the shape and the tricky parts, but not yet compiled.

**Ground rules**
- C#, using Godot types directly.
- A Celeste-style state machine with coroutines.
- Reusable for any kind of character later, with no assumptions about what kind.
- Composition over inheritance. Polymorphism only where strictly necessary. What's left:
  - `IEnumerator`, because `yield` needs it.
  - Delegates.
  - Godot's own base classes (`CharacterBody2D`, `Resource`, `Node`).
- No nullable types unless strictly necessary. The only ones left are `null!` on fields Godot fills in at `_Ready`.
- No fluent chaining. States are dictionaries.

---

## 1. Layout

```
knightly/
├─ knightly.csproj
├─ scripts/
│  ├─ GlobalUsings.cs
│  ├─ States/        State.cs, StateMachine.cs
│  ├─ Coroutines/    Coroutine.cs, CoroutineGroup.cs, Wait.cs, RoutineBuckets.cs
│  ├─ Components/    GroundMover.cs, Animator.cs, Health.cs, HitboxArea.cs, TickWindow.cs, WalkIntent.cs
│  ├─ Motion/        GroundMotion.cs, MovementProfile.cs
│  ├─ Shared/        SharedStates.cs
│  └─ Characters/
│     ├─ Knight/     Knight.cs (node), KnightBrain.cs (every knight state), KnightIntent.cs, AttackStep.cs, PlayerInput.cs
│     └─ Bat/        …later
└─ scenes/
   └─ knight.tscn
```

```csharp
// GlobalUsings.cs
global using KnightMachine = Knightly.States.StateMachine<Knightly.Characters.KnightState, Knightly.Characters.Knight>;
```

## 2. State and state machine

A state is a set of callbacks. `Update` is required and returns the state to be in. Returning the state's own id means stay.

```csharp
namespace Knightly.States;

public sealed class State<StateId, Context> where StateId : struct, Enum
{
    public required Func<Context, float, StateId> Update { get; init; }
    public Action<Context> Begin { get; init; } = static _ => { };
    public Action<Context> End { get; init; } = static _ => { };
    public Action<Context, StateMachine<StateId, Context>> Routines { get; init; } = static (_, _) => { };   // start routines; all stopped on exit
}

public readonly record struct Interrupt<StateId, Context>(StateId Target, Func<Context, bool> When) where StateId : struct, Enum;
```

States hold no per-instance data, so one static dictionary serves every knight. Per-instance data lives on the character node, in its components, or in routine locals.

```csharp
public sealed class StateMachine<StateId, Context> where StateId : struct, Enum
{
    readonly Context m_Context;
    readonly IReadOnlyDictionary<StateId, State<StateId, Context>> m_States;
    readonly IReadOnlyList<Interrupt<StateId, Context>> m_Interrupts;   // checked before Update, in order
    bool m_HasPending;
    StateId m_Pending;

    public StateId Current { get; private set; }
    public StateId Previous { get; private set; }
    public int TicksInState { get; private set; }
    public event Action<StateId, StateId> Changed = static (_, _) => { };

    public RoutineBuckets Routines { get; } = new();            // the current state's; stopped on exit
    public RoutineBuckets Global { get; } = new();              // survive transitions: damage flash, hitstop, footsteps

    public StateMachine(Context context,
                        IReadOnlyDictionary<StateId, State<StateId, Context>> states,
                        IReadOnlyList<Interrupt<StateId, Context>> interrupts)
    {
        foreach (var id in Enum.GetValues<StateId>())                // a missing state fails at startup
            if (!states.ContainsKey(id))
                throw new ArgumentException($"{typeof(StateId).Name}.{id} has no state");

        m_Context = context;
        m_States = states;
        m_Interrupts = interrupts;
    }

    public void Start(StateId initial)
    {
        Current = initial;
        Enter();
    }

    public void Request(StateId next)                               // first request in a tick wins; requesting Current is a no-op
    {
        if (m_HasPending || Is(next)) return;
        m_HasPending = true;
        m_Pending = next;
    }

    public void Tick(float dt)
    {
        TicksInState++;

        foreach (var (target, when) in m_Interrupts)
            if (!Is(target) && when(m_Context)) { Request(target); break; }

        Global.TickBefore(dt);
        if (!m_HasPending) Routines.TickBefore(dt);
        if (!m_HasPending) Request(m_States[Current].Update(m_Context, dt));
        if (!m_HasPending) Routines.TickAfter(dt);
        Global.TickAfter(dt);

        if (m_HasPending)
        {
            m_HasPending = false;
            Switch(m_Pending);
        }
    }

    bool Is(StateId id) => EqualityComparer<StateId>.Default.Equals(id, Current);

    void Switch(StateId to)
    {
        Routines.StopAll();                                     // disposes → routines' finally blocks run
        m_States[Current].End(m_Context);
        (Previous, Current, TicksInState) = (Current, to, 0);
        Enter();
        Changed(Previous, Current);
    }

    void Enter()
    {
        var state = m_States[Current];
        state.Begin(m_Context);
        state.Routines(m_Context, this);
    }
}
```

Order within a tick:

```
1. interrupts                 may request a transition
2. Global.Before              always runs
3. state Before bucket  ┐
4. Update               ├─    skipped once a transition is pending
5. state After bucket   ┘
6. Global.After               always runs
7. apply at most one transition (stops the state's buckets, End, Begin, start new routines)
```

## 3. Coroutines

```csharp
namespace Knightly.Coroutines;

public sealed class Coroutine
{
    readonly Stack<IEnumerator> m_Stack = new();
    Wait m_Wait = Wait.Done;

    public bool Running => m_Stack.Count > 0;

    public void Start(IEnumerator routine)
    {
        Stop();
        m_Stack.Push(routine);
    }

    public void Stop()
    {
        while (m_Stack.Count > 0)                                // innermost first, like unwinding a call stack
            if (m_Stack.Pop() is IDisposable d) d.Dispose();
        m_Wait = Wait.Done;
    }

    public void Tick(float dt)
    {
        if (!m_Wait.Tick(dt)) return;
        m_Wait = Wait.Done;

        while (m_Stack.Count > 0)
        {
            var top = m_Stack.Peek();
            if (!top.MoveNext()) { m_Stack.Pop(); continue; }    // child finished → parent resumes this tick

            switch (top.Current)
            {
                case IEnumerator child: m_Stack.Push(child); continue;   // yield return Swing()  → nested, runs now
                case Wait next:         m_Wait = next; return;           // yield return Wait.X(…)
                default:                return;                         // yield return null     → next tick
            }
        }
    }
}
```

```csharp
public sealed class Wait
{
    enum Kind { Ticks, Seconds, Until }

    static readonly Func<bool> s_Always = static () => true;
    public static readonly Wait Done = new(Kind.Until, 0, 0, s_Always);

    public static Wait Ticks(int n)           => new(Kind.Ticks, n, 0, s_Always);     // deterministic: prefer this
    public static Wait Seconds(float s)       => new(Kind.Seconds, 0, s, s_Always);
    public static Wait Until(Func<bool> done) => new(Kind.Until, 0, 0, done);

    readonly Kind m_Kind;
    readonly Func<bool> m_Until;
    int m_Ticks;
    float m_Seconds;

    Wait(Kind kind, int ticks, float seconds, Func<bool> until)
    {
        m_Kind = kind;
        m_Ticks = ticks;
        m_Seconds = seconds;
        m_Until = until;
    }

    public bool Tick(float dt) => m_Kind switch                  // true = done
    {
        Kind.Ticks   => --m_Ticks <= 0,
        Kind.Seconds => (m_Seconds -= dt) <= 0,
        _            => m_Until(),
    };
}
```

```csharp
public sealed class CoroutineGroup
{
    readonly List<Coroutine> m_Active = new();
    readonly Stack<Coroutine> m_Pool = new();                    // reuse runners across states

    public void Start(IEnumerator routine)
    {
        var c = m_Pool.Count > 0 ? m_Pool.Pop() : new Coroutine();
        c.Start(routine);
        m_Active.Add(c);
    }

    public void Tick(float dt)
    {
        var n = m_Active.Count;                                  // ones started mid-tick wait until next tick
        for (var i = 0; i < n; i++) m_Active[i].Tick(dt);

        for (var i = m_Active.Count - 1; i >= 0; i--)
            if (!m_Active[i].Running) { m_Pool.Push(m_Active[i]); m_Active.RemoveAt(i); }
    }

    public void StopAll()
    {
        foreach (var c in m_Active) { c.Stop(); m_Pool.Push(c); }
        m_Active.Clear();
    }
}

public enum Phase { Before, After }                              // stepped before or after Update

public sealed class RoutineBuckets
{
    readonly CoroutineGroup m_Before = new(), m_After = new();

    public void Start(Phase phase, IEnumerator routine) => (phase == Phase.Before ? m_Before : m_After).Start(routine);

    internal void TickBefore(float dt) => m_Before.Tick(dt);
    internal void TickAfter(float dt)  => m_After.Tick(dt);
    internal void StopAll() { m_Before.StopAll(); m_After.StopAll(); }
}
```

Stopping a state disposes its routines, which runs their `finally` blocks:

```csharp
try     { yield return Wait.Until(() => k.Anim.Finished); }
finally { k.Hitbox.Disable(); }   // runs even if Hurt interrupts mid-swing
```

| Bucket | Use it for | Example |
|---|---|---|
| `Before` | Setting things up that `Update` will read this tick | Dash burst, stun invulnerability, input lock |
| `After` | Reacting to what `Update` decided | Crouch animation, attack combo, afterimages |
| `Global` | Things that should outlive a state change | Damage flash, hitstop, footsteps |

```csharp
// KnightBrain.States:  [KnightState.Dash] = new() { Update = DashUpdate, Routines = DashRoutines },

static void DashRoutines(Knight k, KnightMachine sm)
{
    sm.Routines.Start(Phase.Before, DashBurst(k, sm));          // sets velocity before Update applies gravity
    sm.Routines.Start(Phase.After,  DashTrail(k));              // afterimages wherever Update left the knight
}

static KnightState DashUpdate(Knight k, float dt)
{
    k.Velocity = k.Velocity with { Y = GroundMotion.Fall(k.Velocity.Y, k.GetGravity().Y, k.Air, dt) };
    return KnightState.Dash;
}

static IEnumerator DashBurst(Knight k, KnightMachine sm)
{
    for (var t = 0; t < 10; t++)
    {
        k.Velocity = k.Velocity with { X = k.Mover.Facing * 320 };
        yield return null;
    }
    sm.Request(k.IsOnFloor() ? KnightState.Idle : KnightState.Air);
}

static IEnumerator DashTrail(Knight k)
{
    while (true) { k.Afterimages.Spawn(); yield return Wait.Ticks(3); }
}

// From anywhere: a damage flash that keeps blinking after Hurt → Idle
sm.Global.Start(Phase.After, Flash(k, ticks: 45));
```

## 4. Components

A character is a Godot node **composed of** components. Shared behaviour lives in the components, and characters get it by having one.

```csharp
namespace Knightly.Components;

/// A press (or grace period) that stays live for N ticks.
public sealed class TickWindow
{
    int m_Left;
    public bool IsOpen => m_Left > 0;
    public void Open(int ticks) => m_Left = ticks;
    public void Tick() { if (m_Left > 0) m_Left--; }
    public bool Consume() { if (m_Left <= 0) return false; m_Left = 0; return true; }
}

/// What a walking character wants this tick, from a player, AI, or anything else.
public sealed class WalkIntent
{
    public Vector2 Stick { get; set; }                          // +Y is down
    public TickWindow Jump { get; } = new();
}
```

```csharp
/// Walking, braking and falling for any CharacterBody2D.
public sealed class GroundMover(CharacterBody2D body, WalkIntent intent)
{
    public int Facing { get; private set; } = 1;
    public TickWindow Coyote { get; } = new();

    float Gravity => body.GetGravity().Y;                       // respects Area2D gravity overrides

    /// Gravity, horizontal motion, facing, jump, coyote. Returns false once airborne.
    public bool Walk(MovementProfile t, float moveInput, float dt)
    {
        var v = body.Velocity;
        v.X = GroundMotion.Run(v.X, moveInput, t, dt);
        v.Y = GroundMotion.Fall(v.Y, Gravity, t, dt);
        if (intent.Stick.X != 0) Facing = MathF.Sign(intent.Stick.X);

        if (intent.Jump.Consume())
        {
            v.Y = t.JumpVelocity;
            body.Velocity = v;
            Coyote.Consume();                                   // no coyote double-jump
            return false;
        }
        body.Velocity = v;

        if (!body.IsOnFloor()) return false;
        Coyote.Open(t.CoyoteTicks);
        return true;
    }

    /// Brake to a stop with gravity. Returns false if the floor disappeared.
    public bool Brake(MovementProfile t, float dt)
    {
        var v = body.Velocity;
        v.X = GroundMotion.Run(v.X, 0, t, dt);
        v.Y = GroundMotion.Fall(v.Y, Gravity, t, dt);
        body.Velocity = v;
        return body.IsOnFloor();
    }

    /// Air control, gravity, coyote jump. Returns true on landing; a buffered jump stays open for Walk.
    public bool Airborne(MovementProfile air, MovementProfile ground, float dt)
    {
        var v = body.Velocity;
        v.X = GroundMotion.Run(v.X, intent.Stick.X, air, dt);
        v.Y = GroundMotion.Fall(v.Y, Gravity, air, dt);

        Coyote.Tick();
        if (Coyote.IsOpen && intent.Jump.Consume())
        {
            Coyote.Consume();
            v.Y = ground.JumpVelocity;
        }
        body.Velocity = v;

        return body.IsOnFloor() && v.Y >= 0;
    }
}
```

```csharp
/// Enum-named animations on an AnimatedSprite2D. Enum names must match SpriteFrames animation names.
public sealed class Animator<AnimationId> where AnimationId : struct, Enum
{
    static readonly StringName[] s_Names = Enum.GetNames<AnimationId>().Select(n => new StringName(n)).ToArray();   // assumes 0..n values

    readonly AnimatedSprite2D m_Sprite;
    public bool Finished { get; private set; }

    public Animator(AnimatedSprite2D sprite)
    {
        m_Sprite = sprite;
        sprite.AnimationFinished += () => Finished = true;
        foreach (var name in s_Names)                             // typo in the enum → error at startup, not mid-combo
            if (!sprite.SpriteFrames.HasAnimation(name))
                GD.PushError($"{typeof(AnimationId).Name}.{name} has no animation in {sprite.SpriteFrames.ResourcePath}");
    }

    public void Play(AnimationId anim)                                // no-op if already playing
    {
        var name = s_Names[Unsafe.As<AnimationId, int>(ref anim)];
        if (m_Sprite.Animation == name) return;
        Finished = false;
        m_Sprite.Play(name);
    }
}
```

```csharp
[GlobalClass]
public partial class Health : Node
{
    [Export] public int Max { get; set; } = 3;
    public int Hp { get; private set; }
    public bool Invulnerable { get; set; }
    bool m_Hit;

    public override void _Ready() => Hp = Max;

    public void Hit(int damage)                                 // called by hitboxes
    {
        if (Invulnerable || Hp <= 0) return;
        Hp -= damage;
        m_Hit = true;
    }

    public bool ConsumeHit()
    {
        var tookHit = m_Hit;
        m_Hit = false;
        return tookHit;
    }
}
```

## 5. Motion and tuning

```csharp
[GlobalClass]
public partial class MovementProfile : Resource                 // ground.tres, crouch.tres, air.tres
{
    [Export] public float Accel { get; set; } = 800;            // px/s² toward target speed
    [Export] public float Decel { get; set; } = 1200;           // px/s² with no input. Air: 0
    [Export] public float MaxSpeed { get; set; } = 140;
    [Export] public float OverspeedDecay { get; set; } = 400;   // px/s² bleed-off above MaxSpeed
    [Export] public float GravityScale { get; set; } = 1;
    [Export] public float MaxFall { get; set; } = 400;
    [Export] public float JumpVelocity { get; set; } = -300;    // negative = up
    [Export] public int   CoyoteTicks { get; set; } = 6;
}

public static class GroundMotion
{
    public static float Run(float vx, float input, MovementProfile t, float dt)
    {
        float target = input * t.MaxSpeed;
        bool overspeed = MathF.Abs(vx) > t.MaxSpeed && MathF.Sign(vx) == MathF.Sign(target);
        float rate = overspeed ? t.OverspeedDecay : input == 0 ? t.Decel : t.Accel;
        return Mathf.MoveToward(vx, target, rate * dt);
    }

    public static float Fall(float vy, float gravity, MovementProfile t, float dt)
        => MathF.Min(vy + gravity * t.GravityScale * dt, t.MaxFall);
}
```

> `Decel` (linear) feels different from the current exponential `velocity * friction`. To keep the old feel, use `vx * MathF.Exp(-k * dt)`. It's still delta-correct.

## 6. Shared states

A shared state is a factory function. It reaches the components it needs through accessor delegates, so it works on any character that *has* those components.

```csharp
namespace Knightly.Shared;

public static class SharedStates
{
    public static State<StateId, Context> Hurt<StateId, Context, AnimationId>(
        StateId self, StateId after, int stunTicks, AnimationId clip,
        Func<Context, Health> health, Func<Context, Animator<AnimationId>> anim)
        where StateId : struct, Enum
        where AnimationId : struct, Enum
        => new()
        {
            Update   = (_, _) => self,
            Begin    = c => anim(c).Play(clip),
            Routines = (c, sm) => sm.Routines.Start(Phase.Before, Stun(health(c), sm, after, stunTicks)),
        };

    static IEnumerator Stun<StateId, Context>(Health health, StateMachine<StateId, Context> sm, StateId after, int ticks)
        where StateId : struct, Enum
    {
        health.Invulnerable = true;
        try     { yield return Wait.Ticks(ticks); }
        finally { health.Invulnerable = false; }
        sm.Request(after);
    }
}
```

## 7. The knight's brain: one file

Two tables at the top, then one small group of methods per state.

```csharp
namespace Knightly.Characters;

public enum KnightState { Idle, Run, Crouch, Air, Attack, CrouchAttack, Hurt, Dead }

public static class KnightBrain
{
    public static readonly Interrupt<KnightState, Knight>[] Interrupts =
    [
        new(KnightState.Dead, k => k.Health.Hp <= 0),
        new(KnightState.Hurt, k => k.Health.ConsumeHit()),
    ];

    public static readonly Dictionary<KnightState, State<KnightState, Knight>> States = new()
    {
        [KnightState.Idle]         = new() { Begin = k => k.Anim.Play(KnightAnim.Idle), Update = IdleUpdate },
        [KnightState.Run]          = new() { Begin = k => k.Anim.Play(KnightAnim.Run),  Update = RunUpdate },
        [KnightState.Crouch]       = new() { Update = CrouchUpdate, Routines = CrouchRoutines },
        [KnightState.Air]          = new() { Update = AirUpdate },
        [KnightState.Attack]       = new() { Update = AttackUpdate, Routines = AttackRoutines },
        [KnightState.CrouchAttack] = new() { Begin = k => k.Anim.Play(KnightAnim.CrouchAttack), Update = CrouchAttackUpdate },
        [KnightState.Hurt]         = SharedStates.Hurt(KnightState.Hurt, after: KnightState.Idle, stunTicks: 18, KnightAnim.Hit,
                                                       (Knight k) => k.Health, (Knight k) => k.Anim),
        [KnightState.Dead]         = new() { Begin = k => k.Anim.Play(KnightAnim.Death), Update = (_, _) => KnightState.Dead },
    };

    // ── Idle / Run ─────────────────────────────────────────────

    static KnightState IdleUpdate(Knight k, float dt)
    {
        var stick = k.Intent.Walk.Stick;
        if (!k.Mover.Walk(k.Ground, moveInput: 0, dt)) return KnightState.Air;
        if (k.Intent.Attack.Consume()) return KnightState.Attack;
        if (stick.Y > 0.5f)            return KnightState.Crouch;
        if (stick.X != 0)              return KnightState.Run;
        return KnightState.Idle;
    }

    static KnightState RunUpdate(Knight k, float dt)
    {
        var stick = k.Intent.Walk.Stick;
        if (!k.Mover.Walk(k.Ground, stick.X, dt)) return KnightState.Air;
        if (k.Intent.Attack.Consume()) return KnightState.Attack;
        if (stick.Y > 0.5f)            return KnightState.Crouch;
        if (stick.X == 0)              return KnightState.Idle;
        return KnightState.Run;
    }

    // ── Crouch ─────────────────────────────────────────────────
    // one state instead of CrouchTransition + CrouchIdle + CrouchWalk: the routine handles presentation, Update decides

    static KnightState CrouchUpdate(Knight k, float dt)
    {
        var stick = k.Intent.Walk.Stick;
        if (!k.Mover.Walk(k.Crouch, stick.X, dt)) return KnightState.Air;
        if (k.Intent.Attack.Consume()) return KnightState.CrouchAttack;
        if (stick.Y <= 0.5f)           return KnightState.Idle;
        return KnightState.Crouch;
    }

    static void CrouchRoutines(Knight k, KnightMachine sm)
        => sm.Routines.Start(Phase.After, CrouchPresent(k));

    static IEnumerator CrouchPresent(Knight k)
    {
        k.Anim.Play(KnightAnim.CrouchTransition);
        yield return Wait.Until(() => k.Anim.Finished);
        while (true)
        {
            k.Anim.Play(k.Intent.Walk.Stick.X == 0 ? KnightAnim.Crouch : KnightAnim.CrouchWalk);
            yield return null;
        }
    }

    static KnightState CrouchAttackUpdate(Knight k, float dt)
    {
        if (!k.Mover.Brake(k.Crouch, dt)) return KnightState.Air;
        return k.Anim.Finished ? KnightState.Crouch : KnightState.CrouchAttack;
    }

    // ── Air ────────────────────────────────────────────────────

    const float k_FallBlend = 50f;

    static KnightState AirUpdate(Knight k, float dt)
    {
        var landed = k.Mover.Airborne(k.Air, k.Ground, dt);

        k.Anim.Play(k.Velocity.Y switch
        {
            < -k_FallBlend => KnightAnim.Jump,
            <  k_FallBlend => KnightAnim.JumpFallInbetween,
            _            => KnightAnim.Fall,
        });

        if (!landed) return KnightState.Air;
        return k.Intent.Walk.Stick.X == 0 ? KnightState.Idle : KnightState.Run;
    }

    // ── Attack ─────────────────────────────────────────────────
    // Update handles physics; the routine handles the combo, driven by AttackStep data

    static KnightState AttackUpdate(Knight k, float dt)
        => k.Mover.Brake(k.Ground, dt) ? KnightState.Attack : KnightState.Air;

    static void AttackRoutines(Knight k, KnightMachine sm)
        => sm.Routines.Start(Phase.After, Combo(k, sm));

    static IEnumerator Combo(Knight k, KnightMachine sm)
    {
        foreach (var step in k.Combo)
        {
            yield return Swing(k, step);

            var chained = false;
            for (var t = 0; t < step.ChainWindowTicks && !chained; t++)
            {
                chained = k.Intent.Attack.Consume();            // a press during the swing is still buffered
                if (!chained) yield return null;
            }
            if (!chained) break;
        }
        sm.Request(KnightState.Idle);
    }

    static IEnumerator Swing(Knight k, AttackStep step)
    {
        k.Anim.Play(step.Anim);
        k.Velocity += new Vector2(k.Mover.Facing * step.Lunge, 0);
        k.Hitbox.Enable(step.Damage);
        try     { yield return Wait.Until(() => k.Anim.Finished); }
        finally { k.Hitbox.Disable(); }
    }
}
```

> Keep `Interrupts` and `States` at the top. Static fields initialize in declaration order, and these two only reference methods.

## 8. The knight node

```csharp
namespace Knightly.Characters;

public enum KnightAnim
{
    Idle, Run, Jump, JumpFallInbetween, Fall, Crouch, CrouchWalk, CrouchTransition, CrouchAttack,
    AttackNoMovement, Attack2NoMovement, Roll, Dash, Hit, Death,
}

public sealed class KnightIntent
{
    public WalkIntent Walk { get; } = new();
    public TickWindow Attack { get; } = new();
    public void Tick() { Walk.Jump.Tick(); Attack.Tick(); }
}

[GlobalClass]
public partial class AttackStep : Resource                      // the combo is an array of these in the inspector
{
    [Export] public KnightAnim Anim { get; set; }
    [Export] public int   ChainWindowTicks { get; set; } = 8;
    [Export] public float Lunge { get; set; }
    [Export] public int   Damage { get; set; } = 1;
}
```

```csharp
[GlobalClass]
public partial class Knight : CharacterBody2D
{
    [Export] public MovementProfile Ground { get; set; } = null!;
    [Export] public MovementProfile Crouch { get; set; } = null!;
    [Export] public MovementProfile Air { get; set; } = null!;
    [Export] public Godot.Collections.Array<AttackStep> Combo { get; set; } = [];
    [Export] public Health Health { get; set; } = null!;
    [Export] public HitboxArea Hitbox { get; set; } = null!;
    [Export] Node2D m_Visuals = null!;                           // sprite, hitboxes, VFX live under here
    [Export] AnimatedSprite2D m_Sprite = null!;

    public KnightIntent Intent { get; } = new();
    public GroundMover Mover { get; }
    public KnightMachine Machine { get; }
    public Animator<KnightAnim> Anim { get; private set; } = null!;   // needs m_Sprite, so built in _Ready
    public Action<KnightIntent> Drive { get; set; } = PlayerInput.Fill;

    public Knight()
    {
        Mover = new GroundMover(this, Intent.Walk);
        Machine = new KnightMachine(this, KnightBrain.States, KnightBrain.Interrupts);
    }

    public override void _Ready()
    {
        Anim = new Animator<KnightAnim>(m_Sprite);
        Machine.Start(KnightState.Idle);
    }

    public override void _PhysicsProcess(double delta)
    {
        Intent.Tick();
        Drive(Intent);
        Machine.Tick((float)delta);
        MoveAndSlide();
        m_Visuals.Scale = new Vector2(Mover.Facing, 1);         // flips sprite, hitboxes and VFX together
    }
}
```

The driver is just a delegate. Player input and AI fill the same intent:

```csharp
public static class PlayerInput
{
    static readonly StringName s_Left = "MoveLeft", s_Right = "MoveRight", s_Up = "MoveUp", s_Down = "MoveDown",
                               s_JumpAction = "Jump", s_AttackAction = "Attack";
    const int k_JumpBuffer = 6, k_AttackBuffer = 8;

    public static void Fill(KnightIntent i)
    {
        i.Walk.Stick = Input.GetVector(s_Left, s_Right, s_Up, s_Down);
        if (Input.IsActionJustPressed(s_JumpAction))   i.Walk.Jump.Open(k_JumpBuffer);
        if (Input.IsActionJustPressed(s_AttackAction)) i.Attack.Open(k_AttackBuffer);
    }
}

public static class DarkKnightAi
{
    public static void Fill(KnightIntent i, Node2D self, Node2D target)
    {
        var dx = target.GlobalPosition.X - self.GlobalPosition.X;
        var inReach = MathF.Abs(dx) <= 24;
        i.Walk.Stick = new Vector2(inReach ? 0 : MathF.Sign(dx), 0);
        if (inReach) i.Attack.Open(1);
    }
}

// same knight brain, AI-driven:
boss.Drive = i => DarkKnightAi.Fill(i, boss, player);
```

## 9. A second character

```csharp
public enum BatState { Hang, Swoop, Flee, Hurt, Dead }
public enum BatAnim  { Hang, Fly, Hit, Death }

[GlobalClass]
public partial class Bat : CharacterBody2D
{
    [Export] public Health Health { get; set; } = null!;
    [Export] AnimatedSprite2D m_Sprite = null!;

    public SteerIntent Intent { get; } = new();
    public FlyMover Mover { get; }                               // a different component; the bat has no GroundMover
    public Animator<BatAnim> Anim { get; private set; } = null!;
    public StateMachine<BatState, Bat> Machine { get; }
    // …same shape as Knight
}

public static class BatBrain
{
    public static readonly Interrupt<BatState, Bat>[] Interrupts =
    [
        new(BatState.Dead, b => b.Health.Hp <= 0),
        new(BatState.Hurt, b => b.Health.ConsumeHit()),
    ];

    public static readonly Dictionary<BatState, State<BatState, Bat>> States = new()
    {
        [BatState.Hang]  = new() { Begin = b => b.Anim.Play(BatAnim.Hang), Update = HangUpdate },
        [BatState.Swoop] = new() { Update = SwoopUpdate, Routines = SwoopRoutines },
        [BatState.Flee]  = new() { Update = FleeUpdate },
        [BatState.Hurt]  = SharedStates.Hurt(BatState.Hurt, after: BatState.Flee, stunTicks: 12, BatAnim.Hit,
                                             (Bat b) => b.Health, (Bat b) => b.Anim),    // shared
        [BatState.Dead]  = new() { Begin = b => b.Anim.Play(BatAnim.Death), Update = (_, _) => BatState.Dead },
    };

    static BatState HangUpdate(Bat b, float dt) => b.Intent.Steer != Vector2.Zero ? BatState.Swoop : BatState.Hang;
    // SwoopUpdate, SwoopRoutines, FleeUpdate … all in this file, like KnightBrain
}
```

The bat reuses the machine, coroutines, `Health`, `Animator<T>` and the shared Hurt state. It can't call `Walk`, because it doesn't have a `GroundMover`, so there's nothing to misuse.

---

## 10. Godot + C# practicalities

- Godot scripts must be `public partial class`, and the class name must match the file name. `[GlobalClass]` makes `MovementProfile`, `AttackStep` and `Health` appear in the editor's create dialogs.
- `null!` appears only on `[Export]` members and on `Anim`, which are all filled in before `_Ready` runs or during it.
- Don't allocate per tick in hot paths: no LINQ, and no capturing lambdas inside `Update`. A `Wait.Until(() => …)` per swing is fine.
- Tune live by selecting the knight in the **Remote** scene tree while the game runs, then copy good values into the `.tres`.
- `AnimationPlayer` method tracks can take over `Hitbox.Enable`/`Disable` later, for frame-exact timing.
- Check C# export support for your target platforms in the 4.7 docs (Web has historically been unsupported).

## 11. Alternatives considered

| Option | Why not (for now) |
|---|---|
| GDScript, one script with an `enum` + `match` | Fastest for one hero, but harder to reuse |
| GDScript node states (GDQuest) | Visible in the editor, but lots of ceremony and logic spread across many files |
| `Stateless` (NuGet) | Trigger-driven and fluent-configured; awkward for per-tick movement |
| LimboAI | Worth a look later for enemy decision-making, which would just be another `Drive`; check its C# support |

## 12. Migration path

Each step leaves the game playable.

1. Create the C# project (*Project → Tools → C# → Create C# solution*) and the folder layout.
2. Write `State`, `StateMachine`, `Coroutine`, `CoroutineGroup`, `Wait`, `RoutineBuckets`.
3. Extract the knight into `scenes/knight.tscn` with a `Visuals` node. Port it to C#: Idle/Run/Air, `GroundMover`, `MovementProfile`, `Animator`.
4. Add `KnightIntent` buffers + coyote time.
5. Add Attack as a routine with `AttackStep` resources. Merge Crouch.
6. Add `Health`/`HitboxArea`, plus Hurt/Dead.
7. Delete the GDScript states and `state_common/`.
8. When the second character arrives, give it the components it needs and its own brain file.

## 13. Open decisions

| Decision | Default in the code above |
|---|---|
| Order within a tick | Interrupts → Global.Before → state Before → `Update` → state After → Global.After → one transition (state steps skipped once a transition is pending) |
| Should global routines pause during hitstop / pause menus? | Not handled yet. `RoutineBuckets` could take a time scale |
| Frames or seconds for timing | Ticks (`TickWindow`, `Wait.Ticks`), with `Wait.Seconds` available |
| Testing approach / frameworks | Deferred until the controller exists |
| Target platforms | Unknown: check C# export support before relying on it |
| Planned moveset (Roll, Dash, Slide, Wall*) | Unknown: wall moves would add methods (or a `WallMover` component) next to `GroundMover` |
