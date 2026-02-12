import * as React from "react";

import { Tab } from "$app/parsers/profile";
import GuidGenerator from "$app/utils/guid_generator";

import { PageProps as SectionsProps } from "$app/components/Profile/Sections";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRefToLatest } from "$app/components/useRefToLatest";

export type ProfileProps = {
  tabs: Tab[];
  bio: string | null;
};

export type Props = SectionsProps & ProfileProps;

export type TabWithId = Tab & { id: string };
export function useTabs(initial: Tab[]) {
  const [tabs, setTabs] = React.useState(() => initial.map((tab) => ({ ...tab, id: GuidGenerator.generate() })));

  const location = new URL(useOriginalLocation());
  const urlSection = React.useRef(location.searchParams.get("section"));
  const [selectedTabId, setSelectedTabId] = React.useState(
    (tabs.find((tab) => tab.sections.includes(urlSection.current ?? "")) ?? tabs[0])?.id,
  );
  const setSelectedTab = (tab: TabWithId) => {
    setSelectedTabId(tab.id);
    const section = tab.sections[0];
    const location = new URL(window.location.href);
    if (!section || section === location.searchParams.get("section")) return;
    location.searchParams.set("section", section);
    window.history.pushState(null, "", location.toString());
  };

  const tabsRef = useRefToLatest(tabs);
  React.useEffect(() => {
    const listener = () => {
      const tabs = tabsRef.current;
      const section = new URL(window.location.href).searchParams.get("section");
      if (section === urlSection.current) return;
      urlSection.current = section;
      const tab = section ? tabs.find((tab) => tab.sections.includes(urlSection.current ?? "")) : tabs[0];
      if (tab) setSelectedTabId(tab.id);
    };
    window.addEventListener("popstate", listener);
    return () => window.removeEventListener("popstate", listener);
  }, []);

  return { tabs, setTabs, selectedTab: tabs.find((tab) => tab.id === selectedTabId) ?? tabs[0], setSelectedTab };
}
