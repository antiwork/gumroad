import { Book, Box, Moon, TrendingUp, User, UserCheck, type BoxIconProps } from "@boxicons/react";
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
    is_profile: boolean;
  };
};

const ICONS: Record<string, React.ComponentType<BoxIconProps>> = {
  moon: Moon,
  box: Box,
  "trending-up": TrendingUp,
  user: User,
  "book-open": Book,
  users: UserCheck,
};

export default function PagesNew() {
  const { product, products, templates } = typia.assert<PageProps>(usePage().props);
  const formUID = React.useId();

  const form = useForm<FormData>("CreatePage", {
    page: {
      title: "",
      product_permalink: product?.permalink || "",
      template_id: templates[0]?.id || "",
      is_profile: false,
    },
  });

  const savePage = (e: React.FormEvent) => {
    e.preventDefault();
    if (form.data.page.title.trim() === "") {
      form.setError("page.title", "is required");
      return;
    }
    form.post(Routes.pages_path());
  };

  const updatePage = <K extends keyof FormData["page"]>(key: K, value: FormData["page"][K]) =>
    form.setData("page", { ...form.data.page, [key]: value });

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
            title="Start with a template"
            description="Pick a starting point. You can iterate with chat once the page is created."
          >
            <Fieldset>
              <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
                {templates.map((template) => {
                  const Icon = ICONS[template.icon] ?? Box;
                  const selected = form.data.page.template_id === template.id;
                  return (
                    <button
                      key={template.id}
                      type="button"
                      aria-pressed={selected}
                      onClick={() => updatePage("template_id", template.id)}
                      className={`flex flex-col items-start gap-2 rounded-lg border p-4 text-left transition-colors ${
                        selected ? "border-accent bg-accent/5" : "border-border hover:border-accent/50"
                      }`}
                    >
                      <span className="flex size-10 items-center justify-center rounded-md bg-active-bg">
                        <Icon className="size-5" />
                      </span>
                      <h4 className="font-bold">{template.name}</h4>
                      <p className="text-sm text-muted">{template.description}</p>
                    </button>
                  );
                })}
              </div>
            </Fieldset>
          </FormSection>

          <FormSection title="Details">
            <Fieldset>
              <FieldsetTitle>
                <Label htmlFor={`title-${formUID}`}>Page title</Label>
              </FieldsetTitle>
              <Input
                id={`title-${formUID}`}
                type="text"
                value={form.data.page.title}
                onChange={(e) => updatePage("title", e.target.value)}
                placeholder="My awesome landing page"
              />
              {form.errors["page.title"] ? <small className="text-danger">{form.errors["page.title"]}</small> : null}
            </Fieldset>

            {products.length > 0 ? (
              <Fieldset>
                <FieldsetTitle>
                  <Label>Featured product (optional)</Label>
                </FieldsetTitle>
                <p className="text-sm text-muted">
                  Link this page to a specific product for AI context and the buy button.
                </p>
                <TypeSafeOptionSelect
                  value={form.data.page.product_permalink}
                  onChange={(val) => updatePage("product_permalink", val)}
                  options={[
                    { id: "", label: "None" },
                    ...products.map((p) => ({ id: p.permalink, label: `${p.name} (${p.price})` })),
                  ]}
                />
              </Fieldset>
            ) : null}

            <Fieldset>
              <label className="flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={form.data.page.is_profile}
                  onChange={(e) => updatePage("is_profile", e.target.checked)}
                />
                <span>Use as my profile page (only one per account)</span>
              </label>
            </Fieldset>
          </FormSection>
        </form>
      </div>
    </>
  );
}
