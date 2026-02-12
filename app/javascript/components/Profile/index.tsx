import * as React from "react";

import AutoLink from "$app/components/AutoLink";
import { EditProfile, Props as EditProps } from "$app/components/Profile/EditPage";
import { FollowFormBlock } from "$app/components/Profile/FollowForm";
import { Layout } from "$app/components/Profile/Layout";
import { Section, SectionLayout } from "$app/components/Profile/Sections";
import { Tabs as UITabs, Tab as UITab } from "$app/components/ui/Tabs";

import { useTabs } from "./useProfileTabs";
import type { Props } from "./useProfileTabs";

export type { ProfileProps, Props, TabWithId } from "./useProfileTabs";
export { useTabs } from "./useProfileTabs";

const PublicProfile = (props: Props) => {
  const { tabs, selectedTab, setSelectedTab } = useTabs(props.tabs);
  const sections = selectedTab?.sections.flatMap((id) => props.sections.find((section) => section.id === id) ?? []);

  return (
    <>
      {props.bio || props.tabs.length > 1 ? (
        <header className="border-b border-border">
          <div className="mx-auto grid w-full max-w-6xl grid-cols-1 gap-4 px-4 py-8 lg:px-0">
            {props.bio ? (
              <h1 className="whitespace-pre-line">
                <AutoLink text={props.bio} />
              </h1>
            ) : null}
            {props.tabs.length > 1 ? (
              <UITabs aria-label="Profile Tabs">
                {tabs.map((tab, i) => (
                  <UITab key={i} isSelected={tab === selectedTab} onClick={() => setSelectedTab(tab)}>
                    {tab.name}
                  </UITab>
                ))}
              </UITabs>
            ) : null}
          </div>
        </header>
      ) : null}
      {sections?.length ? (
        sections.map((section) => <Section key={section.id} section={section} {...props} />)
      ) : (
        <SectionLayout className="grid flex-1">
          <FollowFormBlock creatorProfile={props.creator_profile} />
        </SectionLayout>
      )}
    </>
  );
};

export const Profile = (props: Props | EditProps) => (
  <Layout creatorProfile={props.creator_profile} hideFollowForm={!props.sections.length}>
    {"products" in props ? <EditProfile {...props} /> : <PublicProfile {...props} />}
  </Layout>
);
