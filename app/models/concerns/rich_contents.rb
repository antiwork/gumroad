# frozen_string_literal: true

module RichContents
  extend ActiveSupport::Concern

  included do
    has_many :rich_contents, as: :entity
    has_many :alive_rich_contents, -> { alive }, class_name: "RichContent", as: :entity
  end

  def rich_content_folder_name(folder_id)
    return if folder_id.blank?

    folder = alive_rich_contents
      .lazy
      .flat_map(&:description)
      .find do |node|
        node["type"] == RichContent::FILE_EMBED_GROUP_NODE_TYPE &&
          node.dig("attrs", "uid") == folder_id
      end

    folder ? folder.dig("attrs", "name").to_s : nil
  end

  def rich_content_json
    if is_a?(BaseVariant)
      # Variant pages are normally hidden while the product shares one set of
      # pages across all versions — except in the recoverable inconsistent
      # state where those hidden pages are the product's only real content
      # (see Link#recoverable_hidden_variant_rich_content?). Serving them is
      # what lets the seller (and buyers) reach the content again.
      # An orphaned variant (its category row is gone) has no product to consult, so
      # nothing hides its pages: serve them rather than raising from #link.
      product = owning_product
      return [] if product&.has_same_rich_content_for_all_variants? && !product.recoverable_hidden_variant_rich_content?
      variant_id = self.external_id
    end

    alive_rich_contents.sort_by(&:position).map do |content|
      {
        id: content.external_id,
        # TODO (product_edit_react) remove duplicate ID
        page_id: content.external_id,
        title: content.title,
        variant_id:,
        description: { type: "doc", content: content.description },
        updated_at: content.updated_at
      }
    end
  end
end
