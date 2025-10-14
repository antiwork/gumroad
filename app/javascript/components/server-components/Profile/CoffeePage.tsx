import * as React from "react";
import { createCast } from "ts-safe-cast";

import { CreatorProfile } from "$app/parsers/profile";
import { register } from "$app/utils/serverComponentUtil";

import { Product, Props as ProductProps, Purchase } from "$app/components/Product";
import { ConfigurationSelector, PriceSelection } from "$app/components/Product/ConfigurationSelector";
import { CtaButton, getCtaName } from "$app/components/Product/CtaButton";
import { Layout as ProfileLayout } from "$app/components/Profile/Layout";
import { showAlert } from "$app/components/server-components/Alert";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { useRunOnce } from "$app/components/useRunOnce";

type Props = ProductProps & {
  creator_profile: CreatorProfile;
  selection?: Partial<PriceSelection>;
};

export const CoffeePage = ({ creator_profile, selection: selectionOverride, ...props }: Props) => {
  const url = new URL(useOriginalLocation());
  useRunOnce(() => {
    const email = url.searchParams.get("purchase_email");
    if (email) {
      showAlert(`Your purchase was successful! We sent a receipt to ${email}.`, "success");
      url.searchParams.delete("purchase_email");
      window.history.replaceState(window.history.state, "", url.toString());
    }
  });

  return (
    <ProfileLayout creatorProfile={creator_profile} hideFollowForm>
      <CoffeeProduct product={props.product} purchase={props.purchase} selection={selectionOverride ?? null} />
    </ProfileLayout>
  );
};

export const CoffeeProduct = ({
  product,
  purchase,
  selection: selectionOverride,
}: {
  product: Product;
  purchase: Purchase | null;
  selection?: Partial<PriceSelection> | null;
}) => {
  const [selectionState, setSelection] = React.useState<PriceSelection>({
    optionId: product.options.length > 1 ? (product.options[0]?.id ?? null) : null,
    rent: false,
    recurrence: null,
    price: {
      value: product.options.length === 1 ? (product.options[0]?.price_difference_cents ?? null) : null,
      error: false,
    },
    quantity: 1,
    callStartTime: null,
    payInInstallments: false,
  });
  const selection = { ...selectionState, ...selectionOverride };

  const configurationSelector = (
    <>
      <ConfigurationSelector selection={selection} setSelection={setSelection} product={product} discount={null} />
      <CtaButton
        product={product}
        purchase={purchase}
        discountCode={null}
        selection={selection}
        label={getCtaName(product.custom_button_text_option || "donate_prompt")}
        onClick={(evt) => {
          if (selection.optionId === null && !selection.price.value) {
            evt.preventDefault();
            setSelection({ ...selection, price: { ...selection.price, error: true } });
          }
        }}
      />
    </>
  );
  return (
    <section className="px-4" style={{ display: "grid", gap: "var(--spacer-7)", alignContent: "center", flexGrow: 1 }}>
      <section className="grid gap-8">
        <h1>{product.name}</h1>
        {product.description_html ? <h3 dangerouslySetInnerHTML={{ __html: product.description_html }} /> : null}
      </section>
      <section
        style={{
          minWidth: "66%",
          maxWidth: "32rem",
        }}
      >
        {product.options.length === 1 ? (
          <fieldset
            style={{
              display: "grid",
              gridTemplateColumns: "1fr auto",
            }}
          >
            {configurationSelector}
          </fieldset>
        ) : (
          <section className="paragraphs">{configurationSelector}</section>
        )}
      </section>
    </section>
  );
};
export default register({ component: CoffeePage, propParser: createCast() });
