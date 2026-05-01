import { Link, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { ProductReadiness, ProductWorkspaceProps, ProductWorkspaceSections } from "$app/data/products";

import { Button } from "$app/components/Button";
import { PageHeader } from "$app/components/ui/PageHeader";
import { Pill } from "$app/components/ui/Pill";
import { ProductCard, ProductCardFigure, ProductCardFooter, ProductCardHeader } from "$app/components/ui/ProductCard";
import { ProductCardGrid } from "$app/components/ui/ProductCardGrid";

const READINESS_LABELS: Record<ProductReadiness["state"], string> = {
  draft: "Drafted",
  ready: "Ready to sell",
  live: "On the road",
};

const READINESS_COLORS: Record<ProductReadiness["state"], "warning" | "primary" | "success"> = {
  draft: "warning",
  ready: "primary",
  live: "success",
};

const READINESS_HELPER: Record<ProductReadiness["state"], string> = {
  draft: "Your product has been drafted. Finish the offer and payments before it can go on the road.",
  ready: "Your setup is complete. This can now go on the road.",
  live: "Your product is live. Share it with the people most likely to care.",
};

const SECTIONS_HELPER = "Basics creates the product. Offer makes it sellable. Payments lets Gumroad process the sale.";

const SECTION_LABELS: Record<keyof ProductWorkspaceSections, string> = {
  basics: "Basics",
  offer: "Offer",
  payments: "Payments",
};

const TEMPLATE_CARDS: { name: string; price_label: string }[] = [
  { name: "Example slot", price_label: "$9" },
  { name: "Example slot", price_label: "Free" },
];

const SectionChip = ({ complete, label, href }: { complete: boolean; label: string; href: string }) => (
  <Pill asChild size="small" color={complete ? "success" : undefined}>
    <Link href={href}>
      <span aria-hidden className="mr-1">
        {complete ? "✓" : "○"}
      </span>
      <span>{label}</span>
    </Link>
  </Pill>
);

const ProductWorkspacePage = () => {
  const { product, readiness, sections, settings_payments_url } = cast<ProductWorkspaceProps>(usePage().props);

  const sectionLinks: Record<keyof ProductWorkspaceSections, string> = {
    basics: product.edit_url,
    offer: product.edit_url,
    payments: settings_payments_url,
  };

  return (
    <>
      <PageHeader
        className="sticky-top"
        title={product.name || "Workspace"}
        actions={
          <Button asChild>
            <Link href={product.edit_url}>
              <span>Open editor</span>
            </Link>
          </Button>
        }
      />
      <div className="flex flex-col gap-6 p-6">
        <section aria-label="Readiness">
          {readiness ? (
            <div className="flex flex-col gap-3">
              <div className="flex flex-wrap items-center gap-3">
                <Pill color={READINESS_COLORS[readiness.state]}>{READINESS_LABELS[readiness.state]}</Pill>
                <p className="text-muted">{READINESS_HELPER[readiness.state]}</p>
              </div>
              <div className="flex flex-wrap gap-2">
                {(["basics", "offer", "payments"] as const).map((key) => (
                  <SectionChip
                    key={key}
                    complete={sections[key]}
                    label={SECTION_LABELS[key]}
                    href={sectionLinks[key]}
                  />
                ))}
              </div>
              <small className="text-muted">{SECTIONS_HELPER}</small>
            </div>
          ) : (
            <p className="text-muted">Manage this product from the editor.</p>
          )}
        </section>

        <section aria-label="Preview">
          <h3 className="mb-3 font-bold">How your product looks on a shelf</h3>
          <ProductCardGrid>
            <ProductCard>
              <ProductCardFigure>
                {product.thumbnail_url ? <img src={product.thumbnail_url} alt="" /> : null}
              </ProductCardFigure>
              <ProductCardHeader>
                <h4 className="font-bold">{product.name || "Untitled"}</h4>
                {product.custom_summary ? <p>{product.custom_summary}</p> : null}
              </ProductCardHeader>
              <ProductCardFooter>
                <span className="p-3">{product.price_formatted}</span>
              </ProductCardFooter>
            </ProductCard>

            {TEMPLATE_CARDS.map((card, idx) => (
              <ProductCard key={`example-${idx}`} aria-hidden="true" className="opacity-60">
                <ProductCardFigure>{null}</ProductCardFigure>
                <ProductCardHeader>
                  <h4 className="font-bold">{card.name}</h4>
                  <small className="text-muted">Layout placeholder</small>
                </ProductCardHeader>
                <ProductCardFooter>
                  <span className="p-3">{card.price_label}</span>
                </ProductCardFooter>
              </ProductCard>
            ))}
          </ProductCardGrid>
        </section>
      </div>
    </>
  );
};

export default ProductWorkspacePage;
