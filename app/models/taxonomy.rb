# frozen_string_literal: true

class Taxonomy < ApplicationRecord
  has_closure_tree name_column: :slug

  has_many :products, class_name: "Link"
  has_one :taxonomy_stat, dependent: :destroy

  validates :slug, presence: true, uniqueness: { scope: :parent_id }

  def self.find_or_create_by!(attributes, &block)
    super
  rescue ActiveRecord::RecordNotUnique
    ActiveRecord::Base.connection.stick_to_primary!
    find_by!(attributes)
  end

  def self.find_or_create_by(attributes, &block)
    super
  rescue ActiveRecord::RecordNotUnique
    ActiveRecord::Base.connection.stick_to_primary!
    find_by(attributes)
  end
end
