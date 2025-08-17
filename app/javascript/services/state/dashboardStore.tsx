import React, { createContext, useContext, useCallback, useReducer } from "react";

interface DashboardState {
  user: any | null;
  cache: Record<string, any>;
  loading: Record<string, boolean>;
  errors: Record<string, string | null>;
  navigationHistory: string[];
  lastFetch: Record<string, number>;
}

type DashboardAction =
  | { type: "SET_USER"; payload: any }
  | { type: "SET_CACHE"; payload: { key: string; data: any } }
  | { type: "SET_LOADING"; payload: { key: string; loading: boolean } }
  | { type: "SET_ERROR"; payload: { key: string; error: string | null } }
  | { type: "CLEAR_CACHE"; payload?: string }
  | { type: "ADD_TO_HISTORY"; payload: string }
  | { type: "UPDATE_LAST_FETCH"; payload: { key: string; timestamp: number } };

const initialState: DashboardState = {
  user: null,
  cache: {},
  loading: {},
  errors: {},
  navigationHistory: [],
  lastFetch: {},
};

const dashboardReducer = (state: DashboardState, action: DashboardAction): DashboardState => {
  switch (action.type) {
    case "SET_USER":
      return { ...state, user: action.payload };
    
    case "SET_CACHE":
      return {
        ...state,
        cache: { ...state.cache, [action.payload.key]: action.payload.data },
      };
    
    case "SET_LOADING":
      return {
        ...state,
        loading: { ...state.loading, [action.payload.key]: action.payload.loading },
      };
    
    case "SET_ERROR":
      return {
        ...state,
        errors: { ...state.errors, [action.payload.key]: action.payload.error },
      };
    
    case "CLEAR_CACHE":
      if (action.payload) {
        const newCache = { ...state.cache };
        delete newCache[action.payload];
        return { ...state, cache: newCache };
      }
      return { ...state, cache: {} };
    
    case "ADD_TO_HISTORY":
      return {
        ...state,
        navigationHistory: [...state.navigationHistory.slice(-9), action.payload],
      };
    
    case "UPDATE_LAST_FETCH":
      return {
        ...state,
        lastFetch: { ...state.lastFetch, [action.payload.key]: action.payload.timestamp },
      };
    
    default:
      return state;
  }
};

interface DashboardContextValue {
  state: DashboardState;
  actions: {
    initializeStore: (user: any) => void;
    setCache: (key: string, data: any) => void;
    getCache: (key: string) => any;
    setLoading: (key: string, loading: boolean) => void;
    setError: (key: string, error: string | null) => void;
    clearCache: (key?: string) => void;
    addToHistory: (path: string) => void;
    isStale: (key: string, maxAge?: number) => boolean;
  };
}

const DashboardContext = createContext<DashboardContextValue | null>(null);

export const DashboardProvider: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [state, dispatch] = useReducer(dashboardReducer, initialState);

  const actions = {
    initializeStore: useCallback((user: any) => {
      dispatch({ type: "SET_USER", payload: user });
    }, []),

    setCache: useCallback((key: string, data: any) => {
      dispatch({ type: "SET_CACHE", payload: { key, data } });
      dispatch({ type: "UPDATE_LAST_FETCH", payload: { key, timestamp: Date.now() } });
    }, []),

    getCache: useCallback((key: string) => {
      return state.cache[key];
    }, [state.cache]),

    setLoading: useCallback((key: string, loading: boolean) => {
      dispatch({ type: "SET_LOADING", payload: { key, loading } });
    }, []),

    setError: useCallback((key: string, error: string | null) => {
      dispatch({ type: "SET_ERROR", payload: { key, error } });
    }, []),

    clearCache: useCallback((key?: string) => {
      if (key) {
        dispatch({ type: "CLEAR_CACHE", payload: key });
      } else {
        dispatch({ type: "CLEAR_CACHE" });
      }
    }, []),

    addToHistory: useCallback((path: string) => {
      dispatch({ type: "ADD_TO_HISTORY", payload: path });
    }, []),

    isStale: useCallback((key: string, maxAge: number = 5 * 60 * 1000) => {
      const lastFetch = state.lastFetch[key];
      if (!lastFetch) return true;
      return Date.now() - lastFetch > maxAge;
    }, [state.lastFetch]),
  };

  return (
    <DashboardContext.Provider value={{ state, actions }}>
      {children}
    </DashboardContext.Provider>
  );
};

export const useDashboardStore = () => {
  const context = useContext(DashboardContext);
  if (!context) {
    throw new Error("useDashboardStore must be used within a DashboardProvider");
  }
  return context.actions;
};

export const useDashboardState = () => {
  const context = useContext(DashboardContext);
  if (!context) {
    throw new Error("useDashboardState must be used within a DashboardProvider");
  }
  return context.state;
};