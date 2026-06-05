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
  CUSTOM_FIELD_NODE_TYPES = [SHORT_ANSWER_NODE_TYPE, LONG_ANSWER_NODE_TYPE, FILE_UPLOAD_NODE_TYPE].freeze
  COMMON_CONTAINER_NODE_TYPES = [ORDERED_LIST_NODE_TYPE, BULLET_LIST_NODE_TYPE, LIST_ITEM_NODE_TYPE, BLOCKQUOTE_NODE_TYPE].freeze
  FILE_EMBED_CONTAINER_NODE_TYPES = [FILE_EMBED_GROUP_NODE_TYPE, *COMMON_CONTAINER_NODE_TYPES].freeze

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
end
