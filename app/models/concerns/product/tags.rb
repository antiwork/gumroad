# frozen_string_literal: true

module Product::Tags
  extend ActiveSupport::Concern

  included do
    # Ordered by tag_id: creating or destroying a tagging writes the shared `tags` counter
    # cache, so every traversal of a product's taggings must take those rows in the same order
    # (see #save_tags!). The default order is the tagging row id, which is unrelated to them.
    has_many :product_taggings, -> { order(:tag_id) }, foreign_key: :product_id, dependent: :destroy
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

    current_names = tags.pluck(:name)
    names_to_remove = current_names - tags_to_save
    names_to_add = tags_to_save - current_names

    work = names_to_remove.map { |name| [name, :remove] } + names_to_add.map { |name| [name, :add] }
    # `tag!`/`untag!` each take an X-lock on a `tags` row (the counter cache), so both halves run in
    # one pass ordered by that row's id rather than two passes that can deadlock. The row is resolved
    # the way those methods resolve it — equivalent spellings share a slot — with removals first.
    ids_by_name = work.map(&:first).uniq.index_with { |name| Tag.find_by(name: name.downcase)&.id }
    work.sort_by! do |name, action|
      [ids_by_name[name.downcase] || Float::INFINITY, action == :remove ? 0 : 1, name.downcase]
    end
    work.each { |name, action| action == :remove ? untag!(name) : tag!(name) }
  end
end
