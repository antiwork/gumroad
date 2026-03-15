import { uniqBy } from "lodash-es";
import * as React from "react";

import { CustomFieldDescriptor } from "$app/parsers/product";

import { Creator } from "$app/components/Checkout/cartState";
import { Product, getCustomFieldKey, getErrors, isProcessing, useState } from "$app/components/Checkout/payment";
import { Avatar } from "$app/components/ui/Avatar";
import { Card, CardContent } from "$app/components/ui/Card";
import { Checkbox } from "$app/components/ui/Checkbox";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";

const CustomField = ({ field, fieldKey }: { field: CustomFieldDescriptor; fieldKey: string }) => {
  const [state, dispatch] = useState();
  const uid = React.useId();
  const hasError = getErrors(state).has(`customFields.${fieldKey}`);
  const value = state.customFieldValues[fieldKey];

  switch (field.type) {
    case "text": {
      return (
        <Fieldset state={hasError ? "danger" : undefined}>
          <FieldsetTitle>
            <Label htmlFor={uid}>{field.name}</Label>
          </FieldsetTitle>
          <Input
            id={uid}
            type="text"
            aria-invalid={hasError}
            placeholder={`${field.name}${field.required ? "" : " (optional)"}`}
            value={value ?? ""}
            onChange={(e) => dispatch({ type: "set-custom-field", key: fieldKey, value: e.target.value })}
            disabled={isProcessing(state)}
          />
        </Fieldset>
      );
    }
    case "checkbox": {
      return (
        <Fieldset state={hasError ? "danger" : undefined}>
          <Label>
            <Checkbox
              checked={value === "true"}
              aria-invalid={hasError}
              onChange={(e) =>
                dispatch({ type: "set-custom-field", key: fieldKey, value: e.target.checked ? "true" : "" })
              }
              style={{ margin: 0 }}
              disabled={isProcessing(state)}
            />
            {field.required ? field.name : `${field.name} (optional)`}
          </Label>
        </Fieldset>
      );
    }
    case "terms": {
      return (
        <Fieldset state={hasError ? "danger" : undefined}>
          <Label>
            <Checkbox
              checked={value === "true"}
              aria-invalid={hasError}
              onChange={(e) =>
                dispatch({ type: "set-custom-field", key: fieldKey, value: e.target.checked ? "true" : "" })
              }
              style={{ margin: 0 }}
              disabled={isProcessing(state)}
            />
            I accept
            <a href={field.name} target="_blank" rel="noreferrer">
              Terms and Conditions
            </a>
          </Label>
        </Fieldset>
      );
    }
  }
};

type CustomFieldProduct = { permalink: string; name: string; bundleProductId: string | null };

const getCustomFields = (products: Product[]) => {
  const distinctCustomFields = new Map<string, { field: CustomFieldDescriptor; products: CustomFieldProduct[] }>();
  for (const product of products) {
    for (const { bundleProduct, ...field } of [
      ...product.customFields.map((field) => ({ ...field, bundleProduct: null })),
      ...product.bundleProductCustomFields.flatMap(({ product, customFields }) =>
        customFields.map((field) => ({ ...field, bundleProduct: product })),
      ),
    ]) {
      distinctCustomFields.set(field.id, {
        field,
        products: [
          ...(distinctCustomFields.get(field.id)?.products || []),
          {
            permalink: product.permalink,
            name: bundleProduct?.name || product.name,
            bundleProductId: bundleProduct?.id || null,
          },
        ],
      });
    }
  }

  const sharedCustomFields: CustomFieldDescriptor[] = [];
  const customFieldGroups: { product: CustomFieldProduct; customFields: CustomFieldDescriptor[] }[] = [];

  for (const { field, products } of distinctCustomFields.values()) {
    if (!field.collect_per_product && products.length > 1) {
      sharedCustomFields.push(field);
    } else {
      for (const product of products) {
        const group = customFieldGroups.find(
          ({ product: p }) => p.permalink === product.permalink && p.bundleProductId === product.bundleProductId,
        );
        if (group) {
          group.customFields.push(field);
        } else {
          customFieldGroups.push({
            product,
            customFields: [field],
          });
        }
      }
    }
  }

  return { sharedCustomFields, customFieldGroups };
};

const SellerCustomFields = ({ seller, className }: { seller: Creator; className?: string | undefined }) => {
  const [state] = useState();
  const { sharedCustomFields, customFieldGroups } = getCustomFields(
    state.products.filter(({ creator }) => creator.id === seller.id),
  );

  if (sharedCustomFields.length === 0 && customFieldGroups.length === 0) return null;

  return sharedCustomFields.length > 0 ? (
    <div className={className}>
      <section className="flex grow flex-col gap-4">
        <h4 className="text-base sm:text-lg">
          <Avatar className="h-8 !w-8" src={seller.avatar_url} />
          &ensp;
          {seller.name}
        </h4>
        {sharedCustomFields.map((field) => (
          <CustomField key={field.id} field={field} fieldKey={field.id} />
        ))}
        {customFieldGroups.map(({ product, customFields }) => (
          <Fieldset key={`${product.permalink}-${product.bundleProductId}`}>
            <FieldsetTitle>
              <Label>{product.name}</Label>
            </FieldsetTitle>
            <Card>
              <CardContent>
                <section className="flex grow flex-col gap-4">
                  {customFields.map((field) => (
                    <CustomField key={field.id} field={field} fieldKey={getCustomFieldKey(field, product)} />
                  ))}
                </section>
              </CardContent>
            </Card>
          </Fieldset>
        ))}
      </section>
    </div>
  ) : (
    customFieldGroups.map(({ product, customFields }) => (
      <div key={`${product.permalink}-${product.bundleProductId}`} className={className}>
        <section className="flex grow flex-col gap-4">
          <h4 className="text-base sm:text-lg">{product.name}</h4>
          {customFields.map((field) => (
            <CustomField key={field.id} field={field} fieldKey={getCustomFieldKey(field, product)} />
          ))}
        </section>
      </div>
    ))
  );
};

export const CustomFields = ({ className }: { className?: string | undefined }) => {
  const [state] = useState();

  const sellers = uniqBy(
    state.products.map(({ creator }) => creator),
    "id",
  );

  const hasAnyCustomFields = sellers.some((seller) => {
    const { sharedCustomFields, customFieldGroups } = getCustomFields(
      state.products.filter(({ creator }) => creator.id === seller.id),
    );
    return sharedCustomFields.length > 0 || customFieldGroups.length > 0;
  });

  if (!hasAnyCustomFields) return null;

  return (
    <Card>
      {sellers.map((seller) => (
        <SellerCustomFields key={seller.id} seller={seller} className={className} />
      ))}
    </Card>
  );
};
