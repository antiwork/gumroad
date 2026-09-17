# frozen_string_literal: true

class Taxonomy < ApplicationRecord
  # The Discover subtree that collects at the SaaS product tax code — see
  # Link#taxjar_product_tax_code. Its children (wordpress, vscode) are covered too.
  SOFTWARE_AND_PLUGINS_SLUG = "software-and-plugins"

  has_closure_tree name_column: :slug

  has_many :products, class_name: "Link"
  has_many :taxonomy_attributes, -> { active_ordered }, dependent: :destroy
  has_one :taxonomy_stat, dependent: :destroy

  validates :slug, presence: true, uniqueness: { scope: :parent_id }

  # Ids of every software-and-plugins node and the taxonomies under it. Callers that classify many
  # links in one run resolve this once and pass it in: the ancestry walk is one query per link, and
  # the sales-tax reports walk every purchase of a month. Empty when the taxonomy is absent.
  def self.software_and_plugins_subtree_ids
    root_ids = where(slug: SOFTWARE_AND_PLUGINS_SLUG).pluck(:id)
    TaxonomyHierarchy.where(ancestor_id: root_ids).pluck(:descendant_id).to_set
  end
end
