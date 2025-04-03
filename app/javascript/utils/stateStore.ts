export type Store<State, Action> = { getState: () => State; dispatch: (action: Action) => void };

export type ActionCallback<State, Action> = (params: { oldState: State; newState: State; action: Action }) => void;

export const createStoreWithActionCallback = <State, Action>(
  initialState: State,
  reducer: (state: State, action: Action) => State,
  actionCallback: ActionCallback<State, Action>,
): Store<State, Action> => {
  let state: State = initialState;
  const actionsToSchedule: Action[] = [];
  let isMidDispatch = false;

  const store: Store<State, Action> = {
    getState: () => state,
    dispatch: (action) => {
      if (isMidDispatch) {
        actionsToSchedule.push(action);
      } else {
        isMidDispatch = true;

        const oldState = state;
        state = reducer(oldState, action);

        actionCallback({ oldState, newState: state, action });

        isMidDispatch = false;
        for (;;) {
          const deferredAction = actionsToSchedule.shift();
          if (deferredAction == null) break;
          setTimeout(() => store.dispatch(deferredAction), 0);
        }
      }
    },
  };

  return store;
};
