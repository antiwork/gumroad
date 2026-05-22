import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { Button } from "$app/components/Button";
import Errors from "$app/components/Form/Errors";
import { TypeSafeOptionSelect } from "$app/components/TypeSafeOptionSelect";
import { Fieldset, FieldsetTitle } from "$app/components/ui/Fieldset";
import { FormSection } from "$app/components/ui/FormSection";
import { Input } from "$app/components/ui/Input";
import { Label } from "$app/components/ui/Label";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Tab, Tabs } from "$app/components/ui/Tabs";

const rawIcons = import.meta.glob("$assets/images/native_types/*", {
  eager: true,
  query: "?url",
  import: "default",
}) as Record<string, string>;
const stickerIcons = Object.fromEntries(
  Object.entries(rawIcons).map(([key, value]) => [`./${key.split("/").pop()}`, value]),
);

type ProductOption = {
  id: string;
  name: string;
  permalink: string;
  price: string;
  thumbnail_url: string | null;
  short_url: string;
};

type Template = {
  id: string;
  name: string;
  description: string;
  icon: string;
};

type PageProps = {
  product: ProductOption | null;
  products: ProductOption[];
  templates: Template[];
};

type FormData = {
  page: {
    title: string;
    product_permalink: string;
    template_id: string;
  };
};

type FormErrors = {
  "page.title"?: string | undefined;
};

export default function PagesNew() {
  const { product, products, templates } = usePage().props as PageProps;
  const formUID = React.useId();
  const nameInputRef = React.useRef<HTMLInputElement>(null);

  // Honor ?template=<id> when the user arrived from the product Share-tab splash.
  const initialTemplateId = React.useMemo(() => {
    if (typeof window === "undefined") return templates[0]?.id || "";
    const requested = new URLSearchParams(window.location.search).get("template");
    if (requested && templates.some((t) => t.id === requested)) return requested;
    return templates[0]?.id || "";
  }, [templates]);

  const form = useForm<FormData>("CreatePage", {
    page: {
      title: "",
      product_permalink: product?.permalink || "",
      template_id: initialTemplateId,
    },
  });

  const errors = form.errors as FormErrors;

  const savePage = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (form.data.page.title.trim() === "") {
      form.setError("page.title", "is required");
      nameInputRef.current?.focus();
      return;
    }
    form.clearErrors("page.title");
    form.post(Routes.pages_path());
  };

  return (
    <>
      <PageHeader
        className="sticky-top"
        title="What kind of page are you creating?"
        actions={
          <>
            <Button asChild>
              <Link href={Routes.pages_path()}>
                <span>Cancel</span>
              </Link>
            </Button>
            <Button color="accent" type="submit" form={`new-page-form-${formUID}`} disabled={form.processing}>
              {form.processing ? "Creating..." : "Start designing"}
            </Button>
          </>
        }
      />
      <div>
        <div>
          <form id={`new-page-form-${formUID}`} className="row" onSubmit={savePage}>
            <FormSection
              header={
                <p>
                  Pick a theme and we'll draft a custom landing page for you using AI. You can iterate with chat and
                  publish whenever you're ready.
                </p>
              }
            >
              <Fieldset state={errors["page.title"] ? "danger" : undefined}>
                <FieldsetTitle>
                  <Label htmlFor={`title-${formUID}`}>Title</Label>
                </FieldsetTitle>
                <Input
                  id={`title-${formUID}`}
                  type="text"
                  value={form.data.page.title}
                  onChange={(e) => form.setData("page.title", e.target.value)}
                  aria-invalid={!!errors["page.title"]}
                  ref={nameInputRef}
                />
                <Errors errors={errors["page.title"]} label="Title" />
              </Fieldset>

              <Fieldset>
                <FieldsetTitle>Theme</FieldsetTitle>
                <Tabs
                  variant="buttons"
                  className="gap-4 sm:grid-cols-2 md:grid-flow-row md:grid-cols-3 2xl:grid-cols-4"
                  role="radiogroup"
                >
                  {templates.map((template) => {
                    const isSelected = template.id === form.data.page.template_id;
                    const iconSrc = stickerIcons[`./${template.icon}.png`];
                    return (
                      <Tab key={template.id} isSelected={isSelected} asChild>
                        <Button
                          className="flex-col"
                          role="radio"
                          aria-checked={isSelected}
                          data-template={template.id}
                          onClick={() => form.setData("page.template_id", template.id)}
                        >
                          {iconSrc ? (
                            <img src={iconSrc} alt={template.name} className="shrink-0" width="40" height="40" />
                          ) : null}
                          <div>
                            <h4 className="font-bold">{template.name}</h4>
                            {template.description}
                          </div>
                        </Button>
                      </Tab>
                    );
                  })}
                </Tabs>
              </Fieldset>

              {products.length > 0 ? (
                <Fieldset>
                  <FieldsetTitle>
                    <Label htmlFor={`product-${formUID}`}>Featured product (optional)</Label>
                  </FieldsetTitle>
                  <TypeSafeOptionSelect
                    id={`product-${formUID}`}
                    value={form.data.page.product_permalink}
                    onChange={(val) => form.setData("page.product_permalink", val)}
                    options={[
                      { id: "", label: "None" },
                      ...products.map((p) => ({ id: p.permalink, label: `${p.name} (${p.price})` })),
                    ]}
                  />
                  <small className="text-muted">
                    Pick the product this page features. We'll use it for the buy button.
                  </small>
                </Fieldset>
              ) : null}
            </FormSection>
          </form>
        </div>
      </div>
    </>
  );
}
