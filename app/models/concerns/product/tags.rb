# frozen_string_literal: true

module Product::Tags
  extend ActiveSupport::Concern

  included do
    has_many :product_taggings, foreign_key: :product_id, dependent: :destroy
    has_many :tags, through: :product_taggings

    scope :with_tags, lambda { |tag_names|
      if tag_names.present? && tag_names.any?
        joins(:tags)
          .where("tags.name IN (?)", tag_names)
          .group("links.id")
          .having("COUNT(tags.id) >= ?", tag_names.count)
      else
        all
      end
    }
  end

  def tag!(name)
    name = name.downcase
    product_tagging = product_taggings.new
    tag = Tag.find_by(name:) || Tag.new
    if tag.new_record?
      tag.name = name
      tag.save!
    end
    product_tagging.tag = tag
    product_tagging.save!
  end

  def has_tag?(name)
    tags.pluck(:name).include?(name.downcase)
  end

  def untag!(name)
    product_taggings.where(tag: Tag.find_by(name:)).destroy_all if has_tag?(name)
  end

  def save_tags!(tag_list)
    tag_list = {} if tag_list.blank?
    # TODO: Remove support for non-array argument when product edit page is migrated to React
    tags_to_save = tag_list.is_a?(Array) ? tag_list : tag_list.values.map(&:downcase)
    (tags.pluck(:name) - tags_to_save).each { |tag_to_remove| untag!(tag_to_remove) }
    (tags_to_save - tags.pluck(:name)).each { |tag_to_add| tag!(tag_to_add) }
  end
end
