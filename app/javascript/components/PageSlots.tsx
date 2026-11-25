import * as React from "react";

/**
 * Places in the dashboard's shell that a page fills from inside itself, under the header nav:
 * `footer` is a bar pinned to the bottom of the page for a form's buttons, and `navTabs` is where
 * a page's tabs go in the phone's menu.
 */
type Slots = { footer: HTMLElement | null; navTabs: HTMLElement | null };
type SlotSetters = {
  setFooter: (element: HTMLElement | null) => void;
  setNavTabs: (element: HTMLElement | null) => void;
};

const SlotsContext = React.createContext<Slots>({ footer: null, navTabs: null });
const SettersContext = React.createContext<SlotSetters | null>(null);

export const PageSlotsProvider = ({ children }: { children: React.ReactNode }) => {
  const [footer, setFooter] = React.useState<HTMLElement | null>(null);
  const [navTabs, setNavTabs] = React.useState<HTMLElement | null>(null);
  const slots = React.useMemo(() => ({ footer, navTabs }), [footer, navTabs]);
  const setters = React.useMemo(() => ({ setFooter, setNavTabs }), []);
  return (
    <SettersContext.Provider value={setters}>
      <SlotsContext.Provider value={slots}>{children}</SlotsContext.Provider>
    </SettersContext.Provider>
  );
};

export const usePageSlots = () => React.useContext(SlotsContext);
/** Ref callbacks for the shell's slot elements. Null outside the dashboard's shell. */
export const usePageSlotRefs = () => React.useContext(SettersContext);
