# frozen_string_literal: true

class SellerProfileSections::SaveService
  def initialize(seller:)
    @seller = seller
  end

  def upsert!(attributes)
    section = attributes[:id].present? ? seller.seller_profile_sections.find_by_external_id(attributes[:id]) : nil
    section ? update!(section, attributes, allow_shown_posts: true) : create!(attributes)
  end

  def create!(attributes)
    attributes = decrypt_ids(attributes.except(:id))
    if attributes[:text].present? && attributes[:type] == "SellerProfileRichTextSection"
      attributes[:text][:content] = process_text(attributes[:text][:content])
    end
    seller.seller_profile_sections.create!(attributes)
  end

  # The legacy per-section endpoint (ProfileSectionsController) intentionally does not allow
  # mutating shown_posts on update, while the new batched profile editor does. Callers opt in
  # via allow_shown_posts so both share this persistence path.
  def update!(section, attributes, allow_shown_posts: false)
    excepted = [:id, :type, :product_id]
    excepted << :shown_posts unless allow_shown_posts
    attributes = decrypt_ids(attributes.except(*excepted))
    if attributes[:text].present? && section.is_a?(SellerProfileRichTextSection)
      attributes[:text][:content] = process_text(attributes[:text][:content], section.json_data["text"]["content"] || [])
    end
    section.update!(attributes)
    section
  end

  private
    attr_reader :seller

    def decrypt_ids(attributes)
      attributes[:shown_products]&.map! { ObfuscateIds.decrypt(_1) }
      attributes[:shown_posts]&.map! { ObfuscateIds.decrypt(_1) }
      attributes[:shown_wishlists]&.map! { ObfuscateIds.decrypt(_1) }
      attributes[:product_id] = ObfuscateIds.decrypt(attributes[:product_id]) if attributes[:product_id].present?
      attributes[:featured_product_id] = ObfuscateIds.decrypt(attributes[:featured_product_id]) if attributes[:featured_product_id].present?
      attributes
    end

    def process_text(content, old_content = [])
      SaveContentUpsellsService.new(seller:, content:, old_content:).from_rich_content
    end
end
