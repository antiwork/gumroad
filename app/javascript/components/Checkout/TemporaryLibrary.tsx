import * as React from "react";

import { ProductNativeType } from "$app/parsers/product";

import { Creator } from "$app/components/Checkout/cartState";
import { useState } from "$app/components/Checkout/payment";
import { CreateAccountForm } from "$app/components/Checkout/Receipt";
import { useLoggedInUser } from "$app/components/LoggedInUser";
import { AuthorByline } from "$app/components/Product/AuthorByline";
import { Thumbnail } from "$app/components/Product/Thumbnail";
import { showAlert } from "$app/components/server-components/Alert";
import { Result } from "$app/components/server-components/CheckoutPage";
import { PageHeader } from "$app/components/ui/PageHeader";
import { useRunOnce } from "$app/components/useRunOnce";

const formatName = (productName: string, optionName: string | null) =>
  optionName ? `${productName} - ${optionName}` : productName;

export const TemporaryLibrary = ({ results, canBuyerSignUp }: { results: Result[]; canBuyerSignUp: boolean }) => {
  const user = useLoggedInUser();

  const [state] = useState();

  useRunOnce(() => {
    showAlert(`Your purchase was successful! We sent a receipt to ${state.email}.`, "success");
  });

  if (state.status.type !== "finished") return null;
  return (
    <div>
      <PageHeader title="Library" />
      <section className="p-4 md:p-8">
        <div className="with-sidebar">
          {!user && canBuyerSignUp ? (
            <div className="stack">
              <div>
                <CreateAccountForm
                  createAccountData={{
                    email: state.email,
                    cardParams:
                      state.status.paymentMethod.type === "not-applicable" ||
                      state.status.paymentMethod.type === "saved"
                        ? null
                        : state.status.paymentMethod.cardParamsResult.cardParams,
                  }}
                />
              </div>
            </div>
          ) : null}
          <div className="product-card-grid">
            {results.flatMap(({ result, item }) =>
              result.success && result.content_url ? (
                result.bundle_products?.length ? (
                  result.bundle_products.map(({ id, content_url }) => {
                    const bundleProduct = item.product.bundle_products.find(({ product_id }) => product_id === id);
                    if (!bundleProduct) return null;
                    return (
                      <Card
                        key={`${result.id}-${id}`}
                        name={formatName(bundleProduct.name, bundleProduct.variant?.name ?? null)}
                        contentUrl={content_url}
                        thumbnailUrl={bundleProduct.thumbnail_url}
                        nativeType={bundleProduct.native_type}
                        creator={item.product.creator}
                      />
                    );
                  })
                ) : (
                  <Card
                    key={result.id}
                    name={formatName(
                      item.product.name,
                      item.product.options.find(({ id }) => id === item.option_id)?.name ?? null,
                    )}
                    contentUrl={result.content_url}
                    thumbnailUrl={item.product.thumbnail_url}
                    nativeType={item.product.native_type}
                    creator={item.product.creator}
                  />
                )
              ) : (
                []
              ),
            )}
          </div>
        </div>
      </section>
    </div>
  );
};

const Card = ({
  name,
  contentUrl,
  thumbnailUrl,
  nativeType,
  creator,
}: {
  name: string;
  contentUrl: string | null;
  thumbnailUrl: string | null;
  nativeType: ProductNativeType;
  creator: Creator | null;
}) => (
  <article className="product-card" style={{ position: "relative" }}>
    <figure>
      <Thumbnail url={thumbnailUrl} nativeType={nativeType} />
    </figure>
    <header>
      {contentUrl ? (
        <a href={contentUrl} className="stretched-link" aria-label={name}>
          <h3 itemProp="name">{name}</h3>
        </a>
      ) : (
        <h3 itemProp="name">{name}</h3>
      )}
    </header>
    <footer style={{ position: "relative" }}>
      {creator ? (
        <AuthorByline name={creator.name} profileUrl={creator.profile_url} avatarUrl={creator.avatar_url} />
      ) : (
        <div className="user" />
      )}
    </footer>
  </article>
);
