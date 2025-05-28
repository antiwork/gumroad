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

  after_update :reset_moderated_by_iffy_flag, if: -> { saved_change_to_description? && alive? }

  def embedded_product_file_ids_in_order
    description.flat_map { select_file_embed_ids(_1) }.compact.uniq
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

    def reset_moderated_by_iffy_flag
      return unless entity.is_a?(Link)
      entity.update_attribute(:moderated_by_iffy, false)
    end
end
