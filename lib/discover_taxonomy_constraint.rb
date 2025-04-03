# frozen_string_literal: true

class DiscoverTaxonomyConstraint
  def self.matches?(request)
    valid_taxonomy_paths.include?(request.path)
  end

  def self.valid_taxonomy_paths
    @valid_taxonomy_paths ||= Taxonomy.eager_load(:self_and_ancestors)
                                      .order("taxonomy_hierarchies.generations" => :asc)
                                      .map { |t| t.ancestry_path.unshift("").join("/") }
                                      .freeze
  end
end
