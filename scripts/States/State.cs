using System;

namespace Knightly.States;

public sealed class State<StateId, Context> where StateId : struct, Enum
{
    public required Func<Context, float, StateId> OnPhysicsProcess { get; init; }
    public Action<Context> OnBegin { get; init; } = static _ => { };
    public Action<Context> OnFinish { get; init; } = static _ => { };
}
