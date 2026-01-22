import * as React from "react";

import { useCurrentSeller } from "$app/components/CurrentSeller";
import { ProfileSection } from "$app/components/ProductEdit/state";
import { Alert } from "$app/components/ui/Alert";

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
    const name = section.header || "Phần không tên";
    return section.default ? `${name} (Mặc định)` : name;
  };

  return (
    <section className="p-8!">
      <header>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <h2>Hồ sơ</h2>
          <a href="/help/article/124-your-gumroad-profile-page" target="_blank" rel="noreferrer">
            Tìm hiểu thêm
          </a>
        </div>
        Chọn các phần bạn muốn sản phẩm này hiển thị trên hồ sơ của mình.
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
                      ? `${items}, và ${section.product_names.length - 2} ${section.product_names.length - 2 === 1 ? " mục khác" : " mục khác"}`
                      : items}
                  </small>
                </div>
              </label>
            );
          })}
        </fieldset>
      ) : (
        <Alert role="status" variant="info">
          Bạn hiện không có phần nào trong hồ sơ để hiển thị sản phẩm này,{" "}
          <a href={Routes.root_url({ host: currentSeller.subdomain })}>tạo một phần tại đây</a>
        </Alert>
      )}
    </section>
  );
};
