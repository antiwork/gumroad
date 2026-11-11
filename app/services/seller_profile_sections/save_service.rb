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
    attributes = decrypt_ids(attributes.except(:id, :displayed_posts))
    attributes = derive_hide_header(attributes)
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
    excepted.push(:shown_posts, :displayed_posts) unless allow_shown_posts
    attributes = decrypt_ids(attributes.except(*excepted))
    attributes = derive_hide_header(attributes)
    attributes = keep_posts_not_displayed(section, attributes) if allow_shown_posts
    if attributes[:text].present? && section.is_a?(SellerProfileRichTextSection)
      attributes[:text][:content] = process_text(attributes[:text][:content], section.json_data["text"]["content"] || [])
    end
    section.update!(attributes)
    section
  end

  private
    attr_reader :seller

    # The section header is the single source of truth for whether the name shows:
    # a blank header hides it, a present header shows it. Keep the persisted hide_header
    # flag derived from the header so the public renderer and API stay consistent even
    # though the editor no longer exposes a separate toggle.
    def derive_hide_header(attributes)
      return attributes unless attributes.key?(:header)
      attributes.merge(hide_header: attributes[:header].blank?)
    end

    # shown_posts only covers the posts the editor displayed, so keep the section's other alive ids.
    # Editors loaded before displayed_posts existed displayed published posts only.
    def keep_posts_not_displayed(section, attributes)
      displayed = attributes[:displayed_posts]
      attributes = attributes.except(:displayed_posts)
      return attributes unless section.is_a?(SellerProfilePostsSection) && attributes.key?(:shown_posts)
      submitted = Array(attributes[:shown_posts]).map(&:to_i)
      not_displayed = Array(section.shown_posts).map(&:to_i) - submitted - Array(displayed).map(&:to_i)
      keepable = displayed.nil? ? seller.installments.alive.not_published : seller.installments.alive
      kept_ids = not_displayed & keepable.where(id: not_displayed).pluck(:id)
      kept_ids.empty? ? attributes : attributes.merge(shown_posts: Array(attributes[:shown_posts]) + kept_ids)
    end

    def decrypt_ids(attributes)
      attributes[:shown_products]&.map! { ObfuscateIds.decrypt(_1) }
      attributes[:shown_posts]&.map! { ObfuscateIds.decrypt(_1) }
      attributes[:displayed_posts]&.map! { ObfuscateIds.decrypt(_1) }
      attributes[:shown_wishlists]&.map! { ObfuscateIds.decrypt(_1) }
      attributes[:product_id] = ObfuscateIds.decrypt(attributes[:product_id]) if attributes[:product_id].present?
      attributes[:featured_product_id] = ObfuscateIds.decrypt(attributes[:featured_product_id]) if attributes[:featured_product_id].present?
      attributes
    end

    def process_text(content, old_content = [])
      SaveContentUpsellsService.new(seller:, content:, old_content:).from_rich_content
    end
end
