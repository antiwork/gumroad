import * as React from "react";

/**
 * A page's own search (its products, its sales), offered through the dashboard's search bar in
 * place of a second search control on the page. The page still owns the query and the filtering.
 */
export type PageSearch = { label: string; value: string; onSearch: (query: string) => void };

// Two contexts: a page registering its search must not re-render when the registration changes.
const RegisterContext = React.createContext<((search: PageSearch | null) => void) | null>(null);
const ValueContext = React.createContext<PageSearch | null>(null);

export const PageSearchProvider = ({ children }: { children: React.ReactNode }) => {
  const [search, setSearch] = React.useState<PageSearch | null>(null);
  return (
    <RegisterContext.Provider value={setSearch}>
      <ValueContext.Provider value={search}>{children}</ValueContext.Provider>
    </RegisterContext.Provider>
  );
};

/** The search of the page being viewed, if it has one. */
export const usePageSearch = () => React.useContext(ValueContext);

/** True where a search bar is there to take the registration. */
export const useHasPageSearchHost = () => React.useContext(RegisterContext) !== null;

export const useRegisterPageSearch = ({ label, value, onSearch }: PageSearch, enabled: boolean) => {
  const register = React.useContext(RegisterContext);
  const handler = React.useRef(onSearch);
  handler.current = onSearch;

  React.useEffect(() => {
    if (!register || !enabled) return;
    register({ label, value, onSearch: (query) => handler.current(query) });
    return () => register(null);
  }, [register, enabled, label, value]);
};
