import * as React from "react";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { ProfileSection } from "$app/components/ProductEdit/state";

export const ProfileSectionsEditor = ({
  sectionIds,
  onChange,
  profileSections,
}: {
  sectionIds: string[];
  onChange: (sectionIds: string[]) => void;
  profileSections: ProfileSection[];
}) => {
  const currentSeller = useCurrentSeller();
  if (!currentSeller) return null;

  const sectionName = (section: ProfileSection) => {
    const name = section.header || "Unnamed section";
    return section.default ? `${name} (Default)` : name;
  };

  return (
    <section className="!p-8">
      <header>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <h2>Profile</h2>
          <a href="/help/article/124-your-gumroad-profile-page" target="_blank" rel="noreferrer">
            Learn more
          </a>
        </div>
        Choose the sections where you want this product to be displayed on your profile.
      </header>
      {profileSections.length ? (
        <fieldset>
          {profileSections.map((section) => {
            const items = section.product_names.slice(0, 2).join(", ");
            return (
              <label key={section.id}>
                <input
                  type="checkbox"
                  role="switch"
                  checked={sectionIds.includes(section.id)}
                  onChange={(evt) =>
                    onChange(
                      evt.target.checked ? [...sectionIds, section.id] : sectionIds.filter((id) => id !== section.id),
                    )
                  }
                />
                <div>
                  {sectionName(section)}
                  <br />
                  <small>
                    {section.product_names.length > 2
                      ? `${items}, and ${section.product_names.length - 2} ${section.product_names.length - 2 === 1 ? " other" : " others"}`
                      : items}
                  </small>
                </div>
              </label>
            );
          })}
        </fieldset>
      ) : (
        <div role="status" className="info">
          <div>
            You currently have no sections in your profile to display this,{" "}
            <a href={Routes.root_url({ host: currentSeller.subdomain })}>create one here</a>
          </div>
        </div>
      )}
    </section>
  );
};
