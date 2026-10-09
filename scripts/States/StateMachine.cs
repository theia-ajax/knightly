using System;
using System.Collections.Generic;

namespace Knightly.States;

public sealed class StateMachine<StateId, Context> where StateId : struct, Enum
{
    readonly Context m_Context;
    readonly IReadOnlyDictionary<StateId, State<StateId, Context>> m_States;
    StateId m_Pending;

    bool HasPending => !IsStay(m_Pending);
    
    public StateId Current { get; private set; }
    public StateId Previous { get; private set; }
    public int PhysicsFramesInState { get; private set; }
    public State<StateId, Context> CurrentState => m_States[Current];
    

    public StateMachine(Context context, IReadOnlyDictionary<StateId, State<StateId, Context>> states)
    {
        foreach (var id in Enum.GetValues<StateId>())
        {
            if (!IsStay(id) && !states.ContainsKey(id))
                throw new ArgumentException($"{typeof(StateId).Name}.{id} has no state");
        }

        m_Context = context;
        m_States = states;
    }

    public void Start(StateId initial)
    {
        Current = initial;
        m_States[Current].OnBegin(m_Context);
    }

    public bool TryRequestState(StateId state)
    {
        if (HasPending || IsStay(state) || EqualityComparer<StateId>.Default.Equals(Current, state))
            return false;
        m_Pending = state;
        return true;
    }

    public void PhysicsProcess(float deltaTime)
    {
        PhysicsFramesInState++;

        if (!HasPending)
            TryRequestState(m_States[Current].OnPhysicsProcess(m_Context, deltaTime));
        
        if (HasPending)
            SwitchToPendingState();
    }
    
    static bool IsStay(StateId id) => EqualityComparer<StateId>.Default.Equals(id, default);

    void SwitchToPendingState()
    {
        if (!HasPending)
            return;

        CurrentState.OnFinish(m_Context);
        
        Previous = Current;
        Current = m_Pending;
        PhysicsFramesInState = 0;
        m_Pending = default;
        
        CurrentState.OnBegin(m_Context);
    }
}
