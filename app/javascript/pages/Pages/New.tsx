import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import typia from "typia";

import { Button } from "$app/components/Button";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { PageHeader } from "$app/components/ui/PageHeader";

type ProductOption = {
  id: string;
  name: string;
  permalink: string;
  price: string;
  thumbnail_url: string | null;
  short_url: string;
};

type PageProps = {
  product: ProductOption | null;
  products: ProductOption[];
};

type FormData = {
  page: {
    title: string;
    product_permalink: string;
  };
};

export default function PagesNew() {
  const { product, products } = typia.assert<PageProps>(usePage().props);
  const formUID = React.useId();

  const form = useForm<FormData>("CreatePage", {
    page: {
      title: "",
      product_permalink: product?.permalink || "",
    },
  });

  const savePage = (e: React.FormEvent) => {
    e.preventDefault();
    if (form.data.page.title.trim() === "") {
      form.setError("page.title" as any, "is required");
      return;
    }
    form.post(Routes.pages_path());
  };

  return (
    <>
      <PageHeader
        className="sticky-top"
        title="New page"
        actions={
          <>
            <Button asChild>
              <Link href={Routes.pages_path()}>Cancel</Link>
            </Button>
            <Button color="accent" type="submit" form={`new-page-form-${formUID}`} disabled={form.processing}>
              {form.processing ? "Creating..." : "Create page"}
            </Button>
          </>
        }
      />
      <div>
        <form id={`new-page-form-${formUID}`} className="row" onSubmit={savePage}>
          <FormSection
            header={
              <p>
                Create an AI-powered landing page to showcase your products. Describe what you want and our AI will
                build it for you.
              </p>
            }
          >
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`title-${formUID}`}>Page title</Label>
              </FieldsetTitle>
              <Input
                id={`title-${formUID}`}
                type="text"
                value={form.data.page.title}
                onChange={(e) => form.setData("page", { ...form.data.page, title: e.target.value })}
                placeholder="My awesome landing page"
              />
            </Fieldset>

            {products.length > 0 ? (
              <Fieldset>
                <FieldsetTitle>
                  <Label>Product (optional)</Label>
                </FieldsetTitle>
                <p className="text-sm text-muted">Link this page to a specific product for context.</p>
                <TypeSafeOptionSelect
                  value={form.data.page.product_permalink}
                  onChange={(val) => form.setData("page", { ...form.data.page, product_permalink: val })}
                  options={[
                    { id: "", label: "None" },
                    ...products.map((p) => ({ id: p.permalink, label: `${p.name} (${p.price})` })),
                  ]}
                />
              </Fieldset>
            ) : null}
          </FormSection>
        </form>
      </div>
    </>
  );
}
