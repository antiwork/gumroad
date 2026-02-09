import { Head, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import AutoLink from "$app/components/AutoLink";
import { FollowFormBlock } from "$app/components/Profile/FollowForm";
import { Layout } from "$app/components/Profile/Layout";
import { PageProps as SectionsProps, Section, SectionLayout } from "$app/components/Profile/Sections";
import { ProfileProps, useTabs } from "$app/components/server-components/Profile";
import { Tabs as UITabs, Tab as UITab } from "$app/components/ui/Tabs";

type Props = SectionsProps &
  ProfileProps & {
    custom_styles: string;
  };

export default function UserPage() {
  const props = cast<Props>(usePage().props);
  const { tabs, selectedTab, setSelectedTab } = useTabs(props.tabs);
  const sections = selectedTab?.sections.flatMap((id) => props.sections.find((section) => section.id === id) ?? []);

  return (
    <>
      <Head>
        <style>{props.custom_styles}</style>
      </Head>
      <Layout creatorProfile={props.creator_profile} hideFollowForm={!props.sections.length}>
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
      </Layout>
    </>
  );
}
UserPage.loggedInUserLayout = true;
