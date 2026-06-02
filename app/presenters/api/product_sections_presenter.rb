# frozen_string_literal: true

class Api::ProductSectionsPresenter
  SECTION_TYPES = {
    "SellerProfileProductsSection" => "products",
    "SellerProfileFeaturedProductSection" => "featured_product",
    "SellerProfileRichTextSection" => "rich_text",
    "SellerProfilePostsSection" => "posts",
    "SellerProfileWishlistsSection" => "wishlists",
    "SellerProfileSubscribeSection" => "subscribe",
  }.freeze

  def initialize(product)
    @product = product
    @sections = ordered_sections
    @product_external_ids_by_id = build_product_external_ids_by_id
  end

  def props
    sections.map { serialize(_1) }
  end

  private
    attr_reader :product, :sections, :product_external_ids_by_id

    def ordered_sections
      sections_by_id = product.seller_profile_sections.index_by(&:id)

      Array(product.sections).filter_map do |section_id|
        sections_by_id[section_id] || sections_by_id[section_id.to_i]
      end
    end

    def build_product_external_ids_by_id
      product_ids = sections.flat_map do |section|
        case section
        when SellerProfileProductsSection
          section.shown_products
        when SellerProfileFeaturedProductSection
          section.featured_product_id
        end
      end.compact.uniq

      return {} if product_ids.empty?

      Link.where(user_id: product.user_id, id: product_ids).index_by(&:id).transform_values(&:external_id)
    end

    def serialize(section)
      payload = {
        "id" => section.external_id,
        "type" => type_for(section),
        "header" => section.header || "",
        "hide_header" => section.hide_header?,
      }

      case section
      when SellerProfileProductsSection
        payload.merge!(
          "shown_products" => section.shown_products.filter_map { product_external_ids_by_id[_1] },
          "default_product_sort" => section.default_product_sort,
          "show_filters" => section.show_filters,
          "add_new_products" => section.add_new_products,
        )
      when SellerProfileFeaturedProductSection
        featured_product_external_id = product_external_ids_by_id[section.featured_product_id]
        payload.merge!("featured_product" => featured_product_external_id) if featured_product_external_id.present?
      end

      payload
    end

    def type_for(section)
      SECTION_TYPES.fetch(section.type) do
        section.type.to_s.delete_prefix("SellerProfile").delete_suffix("Section").underscore
      end
    end
end
