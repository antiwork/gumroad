# frozen_string_literal: true

# SEO metadata for Discover category/subcategory pages (taxonomy-only, no query/tags):
# server-rendered title/description, BreadcrumbList + ItemList JSON-LD, and the
# subcategory/pagination links crawlers need in the initial HTML.
class Discover::CategoryPagePresenter
  include ActionView::Helpers::NumberHelper
  include CurrencyHelper

  SCHEMA_ORG_CONTEXT = "https://schema.org"

  attr_reader :taxonomy_path, :taxonomy, :search_results

  def initialize(taxonomy_path:, taxonomy:, search_results:)
    @taxonomy_path = taxonomy_path
    @taxonomy = taxonomy
    @search_results = search_results
  end

  def title
    "#{labels.join(" » ")} — digital products by independent creators | Gumroad"
  end

  def meta_description
    count = number_with_delimiter(search_results[:total])
    "Browse #{count} #{labels.last} products from independent creators on Gumroad. " \
    "Discover the best free and premium #{labels.last} digital downloads."
  end

  def breadcrumb_list_json_ld
    items = [{ name: "Discover", url: UrlService.discover_full_path(Discover::CanonicalUrlPresenter::INDEX_PATH) }]
    slugs.each_with_index do |slug, index|
      items << {
        name: labels[index],
        url: UrlService.discover_full_path("/#{slugs[0..index].join("/")}")
      }
    end

    {
      "@context" => SCHEMA_ORG_CONTEXT,
      "@type" => "BreadcrumbList",
      "itemListElement" => items.each_with_index.map do |item, index|
        {
          "@type" => "ListItem",
          "position" => index + 1,
          "name" => item[:name],
          "item" => item[:url]
        }
      end
    }
  end

  def item_list_json_ld
    products = search_results[:products]
    return nil if products.blank?

    {
      "@context" => SCHEMA_ORG_CONTEXT,
      "@type" => "ItemList",
      "name" => labels.last,
      "numberOfItems" => search_results[:total],
      "itemListElement" => products.each_with_index.map do |product, index|
        item = {
          "@type" => "Product",
          "name" => product[:name],
          "url" => product[:url]
        }
        if product[:price_cents].present?
          item["offers"] = {
            "@type" => "Offer",
            # price_cents is in the currency's minor unit except for single-unit
            # currencies (JPY), where it already holds whole units.
            "price" => product[:price_cents] / unit_scaling_factor(product[:currency_code]).to_f,
            "priceCurrency" => product[:currency_code].to_s.upcase
          }
        end
        { "@type" => "ListItem", "position" => index + 1, "item" => item }
      end
    }
  end

  def subcategory_links
    taxonomy.children.order(:slug).map do |child|
      {
        label: Discover::TaxonomyPresenter::TAXONOMY_LABELS[child.slug] || child.slug,
        href: UrlService.discover_full_path("/#{taxonomy_path}/#{child.slug}")
      }
    end
  end

  def self.root_category_links
    Taxonomy.roots.order(:slug).map do |root|
      {
        label: Discover::TaxonomyPresenter::TAXONOMY_LABELS[root.slug] || root.slug,
        href: UrlService.discover_full_path("/#{root.slug}")
      }
    end
  end

  private
    def slugs
      @slugs ||= taxonomy_path.split("/")
    end

    def labels
      @labels ||= slugs.map { |slug| Discover::TaxonomyPresenter::TAXONOMY_LABELS[slug] || slug }
    end
end
