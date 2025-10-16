import * as React from "react";

import { Button } from "$app/components/Button";
import { Icon } from "$app/components/Icons";
import { TagInput } from "$app/components/TagInput";
import Placeholder from "$app/components/ui/Placeholder";

type ProductLevelSupportEmail = {
  email: string;
  product_ids: string[];
};

type Product = {
  id: string;
  name: string;
};

const AddProductLevelSupportEmailButton = React.memo(({ onClick }: { onClick: () => void }) => (
  <Button color="primary" onClick={onClick}>
    <Icon name="plus" />
    Add a product specific email
  </Button>
));

AddProductLevelSupportEmailButton.displayName = "AddProductLevelSupportEmailButton";

const ProductLevelSupportEmailRow = React.memo(
  ({
    index,
    supportEmail,
    availableProducts,
    isDisabled,
    onUpdate,
    onRemove,
  }: {
    index: number;
    supportEmail: ProductLevelSupportEmail;
    availableProducts: { id: string; label: string }[];
    isDisabled?: boolean;
    onUpdate: (index: number, email: ProductLevelSupportEmail) => void;
    onRemove: (index: number) => void;
  }) => {
    const uid = React.useId();
    const [expanded, setExpanded] = React.useState(!supportEmail.email);

    const handleEmailChange = (evt: React.ChangeEvent<HTMLInputElement>) => {
      onUpdate(index, { ...supportEmail, email: evt.target.value });
    };

    const handleProductIdsChange = (product_ids: string[]) => {
      onUpdate(index, { ...supportEmail, product_ids });
    };

    const handleToggleExpandedState = () => setExpanded((prev) => !prev);
    const handleRemove = () => onRemove(index);

    return (
      <div role="listitem">
        <div className="content">
          <Icon name="envelope-fill" className="type-icon" />
          <div className="ml-1">
            <h4>{supportEmail.email || "No email set"}</h4>
            <span>
              {supportEmail.product_ids.length} {supportEmail.product_ids.length === 1 ? "product" : "products"}
            </span>
          </div>
        </div>
        <div className="actions">
          <Button onClick={handleToggleExpandedState} aria-label="Edit email">
            {expanded ? <Icon name="outline-cheveron-up" /> : <Icon name="outline-cheveron-down" />}
          </Button>
          <Button onClick={handleRemove} aria-label="Delete email">
            <Icon name="trash2" />
          </Button>
        </div>
        {expanded ? (
          <div className="paragraphs">
            <fieldset>
              <label htmlFor={`${uid}email`}>Email</label>
              <input
                id={`${uid}email`}
                type="email"
                value={supportEmail.email}
                disabled={isDisabled}
                required={supportEmail.product_ids.length > 0}
                onChange={handleEmailChange}
              />
              <small>This reply-to email will appear on receipts for selected products.</small>
            </fieldset>
            <fieldset>
              <legend>
                <label htmlFor={`${uid}-products`}>Products</label>
              </legend>
              <TagInput
                inputId={`${uid}-products`}
                tagIds={supportEmail.product_ids}
                tagList={availableProducts}
                isDisabled={isDisabled}
                onChangeTagIds={handleProductIdsChange}
              />
            </fieldset>
          </div>
        ) : null}
      </div>
    );
  },
);

ProductLevelSupportEmailRow.displayName = "ProductLevelSupportEmailRow";

export const ProductLevelSupportEmailsForm = React.memo(
  ({
    productLevelSupportEmails,
    products,
    isDisabled = false,
    onChange,
  }: {
    productLevelSupportEmails: ProductLevelSupportEmail[];
    products: Product[];
    isDisabled?: boolean;
    onChange: (emails: ProductLevelSupportEmail[]) => void;
  }) => {
    const productIdToEmail = React.useMemo(
      () =>
        productLevelSupportEmails.reduce((acc, supportEmail, index) => {
          supportEmail.product_ids.forEach((id) => {
            acc.set(id, index);
          });
          return acc;
        }, new Map<string, number>()),
      [productLevelSupportEmails],
    );
    const getAvailableProductsForIndex = (index: number) =>
      products
        .filter(({ id }) => productIdToEmail.get(id) === index || productIdToEmail.get(id) === undefined)
        .map(({ id, name }) => ({ id, label: name }));

    const handleAddEmail = () => onChange([...productLevelSupportEmails, { email: "", product_ids: [] }]);

    const handleUpdateEmail = (index: number, updatedEmail: ProductLevelSupportEmail) => {
      const newEmails = [...productLevelSupportEmails];
      newEmails[index] = updatedEmail;
      onChange(newEmails);
    };

    const handleRemoveEmail = (index: number) => {
      onChange(productLevelSupportEmails.filter((_, i) => i !== index));
    };

    if (productLevelSupportEmails.length === 0) {
      return (
        <Placeholder>
          <AddProductLevelSupportEmailButton onClick={handleAddEmail} />
          <div>Use a different reply-to email for specific products.</div>
        </Placeholder>
      );
    }

    return (
      <>
        <div className="rows" role="list">
          {productLevelSupportEmails.map((supportEmail, index) => (
            <ProductLevelSupportEmailRow
              key={index}
              index={index}
              supportEmail={supportEmail}
              availableProducts={getAvailableProductsForIndex(index)}
              isDisabled={isDisabled}
              onUpdate={handleUpdateEmail}
              onRemove={handleRemoveEmail}
            />
          ))}
        </div>
        <AddProductLevelSupportEmailButton onClick={handleAddEmail} />
      </>
    );
  },
);

ProductLevelSupportEmailsForm.displayName = "ProductLevelSupportEmailsForm";
