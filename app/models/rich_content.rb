# frozen_string_literal: true

class RichContent < ApplicationRecord
  include Deletable, ExternalId, Versionable

  has_paper_trail

  FILE_EMBED_NODE_TYPE = "fileEmbed"
  FILE_EMBED_GROUP_NODE_TYPE = "fileEmbedGroup"
  ORDERED_LIST_NODE_TYPE = "orderedList"
  BULLET_LIST_NODE_TYPE = "bulletList"
  LIST_ITEM_NODE_TYPE = "listItem"
  BLOCKQUOTE_NODE_TYPE = "blockquote"
  LICENSE_KEY_NODE_TYPE = "licenseKey"
  POSTS_NODE_TYPE = "posts"
  SHORT_ANSWER_NODE_TYPE = "shortAnswer"
  LONG_ANSWER_NODE_TYPE = "longAnswer"
  FILE_UPLOAD_NODE_TYPE = "fileUpload"
  MORE_LIKE_THIS_NODE_TYPE = "moreLikeThis"
  REVIEW_CARD_NODE_TYPE = "reviewCard"
  UPSELL_CARD_NODE_TYPE = "upsellCard"
  CUSTOM_FIELD_NODE_TYPES = [SHORT_ANSWER_NODE_TYPE, LONG_ANSWER_NODE_TYPE, FILE_UPLOAD_NODE_TYPE].freeze
  COMMON_CONTAINER_NODE_TYPES = [ORDERED_LIST_NODE_TYPE, BULLET_LIST_NODE_TYPE, LIST_ITEM_NODE_TYPE, BLOCKQUOTE_NODE_TYPE].freeze
  FILE_EMBED_CONTAINER_NODE_TYPES = [FILE_EMBED_GROUP_NODE_TYPE, *COMMON_CONTAINER_NODE_TYPES].freeze

  # Nodes that occupy space in the editor but do not, by themselves, mean the
  # buyer receives anything. Each one is a single click to insert and costs the
  # seller no work, so their presence proves nothing about what was written or
  # attached. Two reasons a node lands here:
  #
  # It renders content fetched from elsewhere, and that elsewhere can be empty —
  # in which case the buyer opens the page and sees nothing at all:
  #
  #   - `posts` renders the product's published posts, and renders nothing when
  #     the seller has published none,
  #   - `fileEmbed` / `fileEmbedGroup` render an uploaded file, and render
  #     nothing once that file is deleted or was never finished uploading,
  #   - `reviewCard` renders one of the product's reviews, and renders nothing
  #     when that review can't be fetched.
  #
  # Or it points at something other than this listing's deliverable, so it can't
  # stand in for one no matter how well it renders:
  #
  #   - `moreLikeThis` renders other listings Gumroad recommends,
  #   - `upsellCard` advertises another product the buyer could also buy,
  #   - the custom-field nodes (`shortAnswer`, `longAnswer`, `fileUpload`) are
  #     form inputs that ask the BUYER for something rather than giving them
  #     anything.
  #
  # Callers that need "did the seller put something here themselves" (rather than
  # "does the editor show a block here") pass this to `has_body_content?`.
  NODE_TYPES_WITHOUT_OWN_CONTENT = [
    POSTS_NODE_TYPE,
    FILE_EMBED_NODE_TYPE,
    FILE_EMBED_GROUP_NODE_TYPE,
    REVIEW_CARD_NODE_TYPE,
    MORE_LIKE_THIS_NODE_TYPE,
    UPSELL_CARD_NODE_TYPE,
    *CUSTOM_FIELD_NODE_TYPES
  ].freeze

  DESCRIPTION_JSON_SCHEMA = {
    type: "array",
    items: { "$ref": "#/$defs/content" },

    "$defs": {
      content: {
        type: "object",
        properties: {
          type: { type: "string" },
          attrs: { type: "object", additionalProperties: true },
          content: { type: "array", items: { "$ref": "#/$defs/content" } },
          marks: {
            type: "array",
            items: {
              type: "object",
              properties: {
                type: { type: "string" },
                attrs: { type: "object", additionalProperties: true }
              },
              required: ["type"],
              additionalProperties: true
            }
          },
          text: { type: "string" }
        },
        additionalProperties: true
      }
    }
  }

  belongs_to :entity, polymorphic: true, optional: true

  validates :entity, presence: true
  validates :description, json: { schema: DESCRIPTION_JSON_SCHEMA, message: :invalid }
  validate :embedded_files_belong_to_product, if: :will_save_change_to_description?

  def embedded_product_file_ids_in_order
    description.flat_map { select_file_embed_ids(_1) }.compact.uniq
  end

  # True when the page carries anything a buyer could actually see. A page whose
  # description is only empty structural nodes (e.g. a single bare paragraph —
  # the shape the editor creates as a blank placeholder) has no content, unless
  # the seller gave the page a title: a titled page renders its title in the
  # page list, so it is seller-authored work even with an empty body. This
  # matters for content resolution: an empty product-level placeholder page must
  # not make the product look like it has product-level content, which would
  # hide the real variant-level content from buyers.
  def has_editor_content?
    return true if title.present?

    has_body_content?
  end

  # Whether the page body itself renders something for the buyer. Unlike
  # `has_editor_content?` this ignores the page title: a titled but otherwise
  # empty page shows up in the buyer's page list, which is enough to say the
  # seller did some work, but it is not something the buyer can read.
  #
  # `excluding_node_types:` drops node types from the walk entirely, for callers
  # that need a stricter answer than "the editor shows something here". See
  # NODE_TYPES_WITHOUT_OWN_CONTENT for the set the moderation code passes and
  # why.
  def has_body_content?(excluding_node_types: [])
    description.present? && description.any? { node_has_content?(_1, excluding_node_types:) }
  end

  def owning_product
    entity.is_a?(Link) ? entity : entity.try(:link)
  end

  def cross_product_file_embed_ids
    embedded_ids = embedded_product_file_ids_in_order
    return [] if embedded_ids.empty?

    product = owning_product
    return [] if product.nil?

    ProductFile.where(id: embedded_ids).where.not(link_id: product.id).pluck(:id)
  end

  def self.reject_file_embeds(nodes, product_file_ids)
    Array(nodes).filter_map do |node|
      if node["type"] == FILE_EMBED_NODE_TYPE
        raw_id = node.dig("attrs", "id")
        decrypted_id = raw_id.present? ? ObfuscateIds.decrypt(raw_id) : nil
        next if decrypted_id.present? && product_file_ids.include?(decrypted_id)
        node
      elsif node["content"].is_a?(Array) && node["type"].in?(FILE_EMBED_CONTAINER_NODE_TYPES)
        remaining = reject_file_embeds(node["content"], product_file_ids)
        next if node["type"] == FILE_EMBED_GROUP_NODE_TYPE && remaining.empty?
        node.merge("content" => remaining)
      else
        node
      end
    end
  end

  def custom_field_nodes
    select_custom_field_nodes(description).uniq
  end

  def has_license_key?
    contains_license_key_node = ->(node) do
      node["type"] == LICENSE_KEY_NODE_TYPE || (node["type"].in?(COMMON_CONTAINER_NODE_TYPES) && node["content"].to_s.include?(LICENSE_KEY_NODE_TYPE) && node["content"].any? { |child_node| contains_license_key_node.(child_node) })
    end
    description.any? { |node| contains_license_key_node.(node) }
  end

  def has_posts?
    contains_posts_node = ->(node) do
      node["type"] == POSTS_NODE_TYPE || (node["type"].in?(COMMON_CONTAINER_NODE_TYPES) && node["content"].to_s.include?(POSTS_NODE_TYPE) && node["content"].any? { |child_node| contains_posts_node.(child_node) })
    end
    description.any? { |node| contains_posts_node.(node) }
  end

  def self.human_attribute_name(attr, _)
    attr == "description" ? "Content" : super
  end

  private
    def embedded_files_belong_to_product
      return unless description.is_a?(Array)

      foreign_ids = cross_product_file_embed_ids
      return if foreign_ids.empty?

      external_ids = foreign_ids.map { ObfuscateIds.encrypt(_1) }
      errors.add(:base, "File embeds reference files not belonging to this product: #{external_ids.join(", ")}")
    end

    def select_file_embed_ids(node)
      if node["type"] == FILE_EMBED_NODE_TYPE
        id = node.dig("attrs", "id")
        return id.present? ? ObfuscateIds.decrypt(id) : nil
      end

      if node["type"].in?(FILE_EMBED_CONTAINER_NODE_TYPES) && node["content"].to_s.include?(FILE_EMBED_NODE_TYPE)
        node["content"].flat_map { select_file_embed_ids(_1) }
      end
    end

    def select_custom_field_nodes(nodes)
      nodes.flat_map do |node|
        if CUSTOM_FIELD_NODE_TYPES.include?(node["type"])
          next [node]
        end

        if COMMON_CONTAINER_NODE_TYPES.include?(node["type"])
          next select_custom_field_nodes(node["content"])
        end

        []
      end
    end

    # A node counts as content when it's anything other than an empty container:
    # text, media/embed nodes (which have no "content" array), or a container
    # with at least one contentful child. A bare `{"type" => "paragraph"}` — the
    # editor's blank placeholder — is not content.
    def node_has_content?(node, excluding_node_types: [])
      return false unless node.is_a?(Hash)
      return false if node["type"].in?(excluding_node_types)
      return true if node["text"].present?

      children = node["content"]
      if children.is_a?(Array)
        children.any? { node_has_content?(_1, excluding_node_types:) }
      else
        # Leaf nodes without a content array (fileEmbed, image, licenseKey,
        # posts, horizontal rule, etc.) render something by themselves —
        # except structural placeholders like an empty paragraph/heading.
        !node["type"].in?(%w[paragraph heading])
      end
    end
end
