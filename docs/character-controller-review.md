# The Knight's Grimoire: character controller design

A Celeste-style controller for the knight, kept small: one character node, one brain file, and a tiny state machine with coroutines. This is a design sketch, not compiled code.

**Ground rules**
- C# with Godot types, composition over inheritance.
- Interfaces are fine. No polymorphism over data.
- No fluent chaining. States are a dictionary.
- No nullables unless strictly necessary.
- Naming: `m_` private fields, `s_` private statics, `k_` constants, no `T` prefix on type parameters.
- Build only what the knight needs now. Generalise when a second character exists.

---

## 1. Shape

```
_Process (every render frame)            _PhysicsProcess (fixed rate)
-----------------------------            ---------------------------
Driver.Process()  accumulate input       Intent.PhysicsProcess()        age buffered presses
Anim.Play(pick)   presentation table     Driver.PhysicsProcess(Intent)
flip Visuals                             Machine.PhysicsProcess(dt)     Before routines, OnPhysicsProcess, After routines, at most one transition
                                         MoveAndSlide()
```

## 2. Files

```
scripts/
├─ States/   State.cs, StateMachine.cs, Coroutine.cs
├─ Common/   Animator.cs, FrameWindow.cs, IIntentSource.cs
└─ Knight/   Knight.cs, KnightBrain.cs, KnightAnimations.cs, KnightInput.cs, MovementProfile.cs, AttackStep.cs
```

## 3. State machine

```csharp
public sealed class State<StateId, Context> where StateId : struct, Enum
{
	public required Func<Context, float, StateId> OnPhysicsProcess { get; init; }   // return the Stay value (the enum's first member) for no transition
	public Action<Context> OnBegin { get; init; } = static _ => { };        // start routines here
	public Action<Context> OnFinish { get; init; } = static _ => { };
}
```

The context (the knight) holds its machine, so callbacks only take the context.

```csharp
public enum Phase { Before, After }

public sealed class StateMachine<StateId, Context> where StateId : struct, Enum
{
	readonly Context m_Context;
	readonly IReadOnlyDictionary<StateId, State<StateId, Context>> m_States;
	readonly List<Coroutine> m_Before = new();
	readonly List<Coroutine> m_After = new();
	StateId m_Pending;

	bool HasPending => !IsStay(m_Pending);

	public StateId Current { get; private set; }
	public StateId Previous { get; private set; }
	public int PhysicsFramesInState { get; private set; }

	public StateMachine(Context context, IReadOnlyDictionary<StateId, State<StateId, Context>> states)
	{
		foreach (var id in Enum.GetValues<StateId>())
			if (!IsStay(id) && !states.ContainsKey(id))
				throw new ArgumentException($"{typeof(StateId).Name}.{id} has no state");

		m_Context = context;
		m_States = states;
	}

	public void Start(StateId initial)
	{
		Current = initial;
		m_States[Current].OnBegin(m_Context);
	}

	/// Runs before or after OnPhysicsProcess each physics frame. Stopped when the state exits.
	public void StartRoutine(Phase phase, IEnumerator routine)
		=> (phase == Phase.Before ? m_Before : m_After).Add(new Coroutine(routine));

	/// First request in a physics frame wins. Requesting Stay or Current does nothing.
	public void Request(StateId next)
	{
		if (HasPending || IsStay(next) || Is(next)) return;
		m_Pending = next;
	}

	public void PhysicsProcess(float dt)
	{
		PhysicsFramesInState++;
		if (!HasPending) PhysicsProcessAll(m_Before);
		if (!HasPending) Request(m_States[Current].OnPhysicsProcess(m_Context, dt));
		if (!HasPending) PhysicsProcessAll(m_After);
		if (HasPending) Switch();
	}

	bool Is(StateId id) => EqualityComparer<StateId>.Default.Equals(id, Current);

	/// The enum's default value means no transition, so Stay must be the first member of every state enum.
	static bool IsStay(StateId id) => EqualityComparer<StateId>.Default.Equals(id, default);

	void Switch()
	{
		StopAll(m_Before);
		StopAll(m_After);
		m_States[Current].OnFinish(m_Context);
		(Previous, Current, PhysicsFramesInState, m_Pending) = (Current, m_Pending, 0, default(StateId));
		m_States[Current].OnBegin(m_Context);
	}

	static void PhysicsProcessAll(List<Coroutine> routines)
	{
		for (int i = 0, n = routines.Count; i < n; i++) routines[i].PhysicsProcess();   // ones added mid-pass start next physics frame
		routines.RemoveAll(static r => r.Done);
	}

	static void StopAll(List<Coroutine> routines)
	{
		foreach (var r in routines) r.Stop();
		routines.Clear();
	}
}
```

## 4. Coroutines

Coroutines understand only two yields, as in Celeste: `yield return null` (resume next physics frame) and `yield return SomeRoutine()` (run it nested). Waits are small routines built on those.

```csharp
public sealed class Coroutine
{
	readonly Stack<IEnumerator> m_Stack = new();

	public Coroutine(IEnumerator routine) => m_Stack.Push(routine);

	public bool Done => m_Stack.Count == 0;

	public void PhysicsProcess()
	{
		while (m_Stack.Count > 0)
		{
			var top = m_Stack.Peek();
			if (!top.MoveNext()) { m_Stack.Pop(); continue; }                 // finished, parent resumes now
			if (top.Current is IEnumerator nested) { m_Stack.Push(nested); continue; }
			return;                                                         // yield return null
		}
	}

	public void Stop()   // disposing runs pending finally blocks
	{
		while (m_Stack.Count > 0)
			if (m_Stack.Pop() is IDisposable d) d.Dispose();
	}
}

public static class Wait
{
	public static IEnumerator PhysicsFrames(int n) { for (var i = 0; i < n; i++) yield return null; }
	public static IEnumerator Until(Func<bool> done) { while (!done()) yield return null; }
}
```

## 5. The knight

### Knight.cs

```csharp
[GlobalClass]
public partial class Knight : CharacterBody2D
{
	[Export] public MovementProfile Ground { get; set; } = null!;
	[Export] public MovementProfile Crouch { get; set; } = null!;
	[Export] public MovementProfile Air { get; set; } = null!;
	[Export] public Godot.Collections.Array<AttackStep> Combo { get; set; } = [];
	[Export] Node2D m_Visuals = null!;
	[Export] AnimatedSprite2D m_Sprite = null!;

	public StateMachine<KnightState, Knight> Machine { get; }
	public Animator<KnightAnim> Anim { get; private set; } = null!;   // built in _Ready because it needs m_Sprite
	public KnightIntent Intent { get; } = new();
	public IIntentSource<KnightIntent> Driver { get; set; } = new PlayerKnightInput();

	public int Facing { get; set; } = 1;
	public FrameWindow JumpForgiveness { get; } = new();   // jump still allowed briefly after leaving the ground
	public int ComboIndex { get; set; }

	public Knight() => Machine = new(this, KnightBrain.States);

	public override void _Ready()
	{
		Anim = new(m_Sprite);
		Machine.Start(KnightState.Idle);
	}

	public override void _Process(double delta)
	{
		Driver.Process();
		Anim.Play(KnightAnimations.Pick[Machine.Current](this));
		m_Visuals.Scale = new Vector2(Facing, 1);
	}

	public override void _PhysicsProcess(double delta)
	{
		Intent.PhysicsProcess();
		Driver.PhysicsProcess(Intent);
		Machine.PhysicsProcess((float)delta);
		MoveAndSlide();
	}
}
```

### KnightBrain.cs: every state and the movement helpers

```csharp
public enum KnightState { Stay, Idle, Run, Crouch, Air, Attack }

public static class KnightBrain
{
	public static readonly Dictionary<KnightState, State<KnightState, Knight>> States = new()
	{
		[KnightState.Idle]   = new() { OnPhysicsProcess = Idle },
		[KnightState.Run]    = new() { OnPhysicsProcess = Run },
		[KnightState.Crouch] = new() { OnPhysicsProcess = Crouch },
		[KnightState.Air]    = new() { OnPhysicsProcess = Air },
		[KnightState.Attack] = new() { OnBegin = AttackBegin, OnPhysicsProcess = Attack },
	};

	static KnightState Idle(Knight k, float dt)
	{
		if (!Walk(k, k.Ground, 0, dt))   return KnightState.Air;
		if (k.Intent.Attack.Consume())   return KnightState.Attack;
		if (k.Intent.Stick.Y > 0.5f)     return KnightState.Crouch;
		if (k.Intent.Stick.X != 0)       return KnightState.Run;
		return KnightState.Stay;
	}

	static KnightState Run(Knight k, float dt)
	{
		if (!Walk(k, k.Ground, k.Intent.Stick.X, dt)) return KnightState.Air;
		if (k.Intent.Attack.Consume())   return KnightState.Attack;
		if (k.Intent.Stick.Y > 0.5f)     return KnightState.Crouch;
		if (k.Intent.Stick.X == 0)       return KnightState.Idle;
		return KnightState.Stay;
	}

	static KnightState Crouch(Knight k, float dt)
	{
		if (!Walk(k, k.Crouch, k.Intent.Stick.X, dt)) return KnightState.Air;
		if (k.Intent.Stick.Y <= 0.5f)    return KnightState.Idle;
		return KnightState.Stay;
	}

	static KnightState Air(Knight k, float dt)
	{
		if (!Fall(k, dt)) return KnightState.Stay;
		return k.Intent.Stick.X == 0 ? KnightState.Idle : KnightState.Run;
	}

	// attack: the animation drives the timing

	static void AttackBegin(Knight k)
	{
		k.ComboIndex = 0;
		k.Machine.StartRoutine(Phase.After, Combo(k));
	}

	static KnightState Attack(Knight k, float dt)
		=> Brake(k, k.Ground, dt) ? KnightState.Stay : KnightState.Air;

	static IEnumerator Combo(Knight k)
	{
		while (true)
		{
			var step = k.Combo[k.ComboIndex];
			yield return Wait.Until(() => k.Anim.HasFinished(step.Anim));

			var chained = false;
			for (var t = 0; t < step.ChainWindowPhysicsFrames && !chained; t++)
			{
				chained = k.Intent.Attack.Consume();       // a press during the swing is still buffered
				if (!chained) yield return null;
			}
			if (!chained || k.ComboIndex + 1 >= k.Combo.Count) break;
			k.ComboIndex++;
		}
		k.Machine.Request(KnightState.Idle);
	}

	// movement

	/// Ground movement, facing, jump, jump forgiveness. False once airborne.
	static bool Walk(Knight k, MovementProfile t, float input, float dt)
	{
		var v = k.Velocity;
		v.X = Approach(v.X, input, t, dt);
		v.Y = Gravity(v.Y, k, t, dt);
		if (k.Intent.Stick.X != 0) k.Facing = MathF.Sign(k.Intent.Stick.X);

		if (k.Intent.Jump.Consume())
		{
			v.Y = t.JumpVelocity;
			k.Velocity = v;
			k.JumpForgiveness.Consume();
			return false;
		}
		k.Velocity = v;

		if (!k.IsOnFloor()) return false;
		k.JumpForgiveness.Open(t.JumpForgivenessPhysicsFrames);
		return true;
	}

	/// Brake to a stop with gravity. False if the floor disappeared.
	static bool Brake(Knight k, MovementProfile t, float dt)
	{
		k.Velocity = new Vector2(Approach(k.Velocity.X, 0, t, dt), Gravity(k.Velocity.Y, k, t, dt));
		return k.IsOnFloor();
	}

	/// Air control, gravity, late jump during jump forgiveness. True on landing. A buffered jump stays open for Walk.
	static bool Fall(Knight k, float dt)
	{
		var v = k.Velocity;
		v.X = Approach(v.X, k.Intent.Stick.X, k.Air, dt);
		v.Y = Gravity(v.Y, k, k.Air, dt);

		k.JumpForgiveness.PhysicsProcess();
		if (k.JumpForgiveness.IsOpen && k.Intent.Jump.Consume())
		{
			k.JumpForgiveness.Consume();
			v.Y = k.Ground.JumpVelocity;
		}
		k.Velocity = v;

		return k.IsOnFloor() && v.Y >= 0;
	}

	static float Approach(float vx, float input, MovementProfile t, float dt)
	{
		var target = input * t.MaxSpeed;
		var overspeed = MathF.Abs(vx) > t.MaxSpeed && MathF.Sign(vx) == MathF.Sign(target);
		var rate = overspeed ? t.OverspeedDecay : input == 0 ? t.Decel : t.Accel;
		return Mathf.MoveToward(vx, target, rate * dt);
	}

	static float Gravity(float vy, Knight k, MovementProfile t, float dt)
		=> MathF.Min(vy + k.GetGravity().Y * t.GravityScale * dt, t.MaxFall);
}
```

### KnightAnimations.cs: presentation, kept apart from gameplay

```csharp
public enum KnightAnim
{
	Idle, Run, Jump, JumpFallInbetween, Fall, Crouch, CrouchWalk, CrouchTransition, CrouchAttack,
	AttackNoMovement, Attack2NoMovement, Roll, Dash, Hit, Death,
}

public static class KnightAnimations
{
	const float k_FallBlend = 50f;

	public static readonly Dictionary<KnightState, Func<Knight, KnightAnim>> Pick = new()
	{
		[KnightState.Idle]   = static _ => KnightAnim.Idle,
		[KnightState.Run]    = static _ => KnightAnim.Run,
		[KnightState.Crouch] = static k => k.Intent.Stick.X == 0 ? KnightAnim.Crouch : KnightAnim.CrouchWalk,
		[KnightState.Air]    = static k => k.Velocity.Y switch
		{
			< -k_FallBlend => KnightAnim.Jump,
			<  k_FallBlend => KnightAnim.JumpFallInbetween,
			_              => KnightAnim.Fall,
		},
		[KnightState.Attack] = static k => k.Combo[k.ComboIndex].Anim,
	};
}
```

### KnightInput.cs

```csharp
public sealed class KnightIntent
{
	public Vector2 Stick { get; set; }                  // +Y is down
	public FrameWindow Jump { get; } = new();
	public FrameWindow Attack { get; } = new();
	public void PhysicsProcess() { Jump.PhysicsProcess(); Attack.PhysicsProcess(); }
}

/// Accumulates in Process, drains once per PhysicsProcess.
public sealed class PlayerKnightInput : IIntentSource<KnightIntent>
{
	static readonly StringName s_Left = "MoveLeft", s_Right = "MoveRight", s_Up = "MoveUp", s_Down = "MoveDown",
	                           s_Jump = "Jump", s_Attack = "Attack";
	const int k_JumpBuffer = 6, k_AttackBuffer = 8;

	Vector2 m_Stick;
	bool m_JumpPressed;
	bool m_AttackPressed;

	public void Process()
	{
		m_Stick = Input.GetVector(s_Left, s_Right, s_Up, s_Down);
		m_JumpPressed   |= Input.IsActionJustPressed(s_Jump);
		m_AttackPressed |= Input.IsActionJustPressed(s_Attack);
	}

	public void PhysicsProcess(KnightIntent intent)
	{
		intent.Stick = m_Stick;
		if (m_JumpPressed)   intent.Jump.Open(k_JumpBuffer);
		if (m_AttackPressed) intent.Attack.Open(k_AttackBuffer);
		m_JumpPressed = false;
		m_AttackPressed = false;
	}
}
```

### MovementProfile.cs, AttackStep.cs

```csharp
[GlobalClass]
public partial class MovementProfile : Resource                // ground.tres, crouch.tres, air.tres
{
	[Export] public float Accel { get; set; } = 800;           // px/s² toward target speed
	[Export] public float Decel { get; set; } = 1200;          // px/s² with no input. Air: 0
	[Export] public float MaxSpeed { get; set; } = 140;
	[Export] public float OverspeedDecay { get; set; } = 400;  // px/s² bleed-off above MaxSpeed
	[Export] public float GravityScale { get; set; } = 1;
	[Export] public float MaxFall { get; set; } = 400;
	[Export] public float JumpVelocity { get; set; } = -300;   // negative = up
	[Export] public int   JumpForgivenessPhysicsFrames { get; set; } = 6;
}

[GlobalClass]
public partial class AttackStep : Resource
{
	[Export] public KnightAnim Anim { get; set; }
	[Export] public int ChainWindowPhysicsFrames { get; set; } = 8;
}
```

## 6. Common pieces

```csharp
public interface IIntentSource<Intent>
{
	void Process();                          // called from _Process
	void PhysicsProcess(Intent intent);     // called from _PhysicsProcess
}

/// A press or grace period that stays live for N physics frames.
public sealed class FrameWindow
{
	int m_Left;
	public bool IsOpen => m_Left > 0;
	public void Open(int physicsFrames) => m_Left = physicsFrames;
	public void PhysicsProcess() { if (m_Left > 0) m_Left--; }
	public bool Consume() { if (m_Left <= 0) return false; m_Left = 0; return true; }
}
```

```csharp
/// Enum-named animations. Enum names must match the SpriteFrames animation names.
public sealed class Animator<AnimationId> where AnimationId : struct, Enum
{
	static readonly StringName[] s_Names = Enum.GetNames<AnimationId>().Select(n => new StringName(n)).ToArray();

	readonly AnimatedSprite2D m_Sprite;
	AnimationId m_Current;
	bool m_Started;
	bool m_Finished;

	public Animator(AnimatedSprite2D sprite)
	{
		m_Sprite = sprite;
		m_Sprite.AnimationFinished += () => m_Finished = true;
		foreach (var name in s_Names)
			if (!sprite.SpriteFrames.HasAnimation(name))
				GD.PushError($"{typeof(AnimationId).Name}.{name} has no animation in {sprite.SpriteFrames.ResourcePath}");
	}

	public void Play(AnimationId anim)                             // no-op if already current
	{
		if (m_Started && Same(anim, m_Current)) return;
		m_Started = true;
		m_Current = anim;
		m_Finished = false;
		m_Sprite.Play(s_Names[Unsafe.As<AnimationId, int>(ref anim)]);
	}

	/// Asking about a specific animation avoids reading a stale "finished" from the previous one.
	public bool HasFinished(AnimationId anim) => m_Started && Same(anim, m_Current) && m_Finished;
	public int FrameOf(AnimationId anim) => m_Started && Same(anim, m_Current) ? m_Sprite.Frame : -1;

	static bool Same(AnimationId a, AnimationId b) => EqualityComparer<AnimationId>.Default.Equals(a, b);
}
```

---

## 7. Later, not now

- **Hitboxes:** `AttackStep.HitStartFrame` / `HitEndFrame`, waited on with `Anim.FrameOf(step.Anim)`. Frame timing stays in SpriteFrames.
- **Hurt/Dead:** a `Health` node whose hit signal calls `Machine.Request(KnightState.Hurt)`.
- **Transition animations** (CrouchTransition): an `Animator.Play(anim, via: transition)` overload.
- **Second character:** move `Walk`/`Brake`/`Fall` into a component, add `IHas*` interfaces, and share states such as Hurt.
- **Frame-exact animation events:** `AnimationPlayer` with its callback mode set to physics.
- **Smooth rendering:** turn on *Physics Interpolation* in Project Settings.

## 8. Open decisions

| Decision | Current default |
|---|---|
| Target platforms | Unknown: check C# export support |
| Testing approach | Deferred until the controller exists |
