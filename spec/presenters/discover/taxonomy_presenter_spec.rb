# frozen_string_literal: true

require "spec_helper"

describe Discover::TaxonomyPresenter do
  subject(:presenter) { Discover::TaxonomyPresenter.new }

  describe "#taxonomies_for_nav" do
    it "converts the taxonomy into a list of categories, with keys as strings" do
      education_taxonomy = Taxonomy.find_by(slug: "education")
      math_taxonomy = Taxonomy.find_by(slug: "math", parent: education_taxonomy)
      history_taxonomy = Taxonomy.find_by(slug: "history", parent: education_taxonomy)
      three_d_taxonomy = Taxonomy.find_by(slug: "3d")
      assets_taxonomy = Taxonomy.find_by(slug: "3d-assets", parent: three_d_taxonomy)

      expect(presenter.taxonomies_for_nav).to include(
        { key: assets_taxonomy.id.to_s, slug: "3d-assets", label: "3D Assets", parent_key: three_d_taxonomy.id.to_s },
        { key: three_d_taxonomy.id.to_s, slug: "3d", label: "3D", parent_key: nil },
        { key: education_taxonomy.id.to_s, slug: "education", label: "Education", parent_key: nil },
        { key: history_taxonomy.id.to_s, slug: "history", label: "History", parent_key: education_taxonomy.id.to_s },
        { key: math_taxonomy.id.to_s, slug: "math", label: "Math", parent_key: education_taxonomy.id.to_s },
      )
    end

    it "returns 'other' taxonomy last" do
      expect(presenter.taxonomies_for_nav.last).to eq({
                                                        key: Taxonomy.find_by(slug: "other").id.to_s,
                                                        slug: "other",
                                                        label: "Other",
                                                        parent_key: nil
                                                      })
    end

    context "when logged_in_user is present" do
      it "sorts taxonomies based on recommended products" do
        recommended_products = [
          create(:product, taxonomy: Taxonomy.find_by_path(["education", "math"])),
          create(:product, taxonomy: Taxonomy.find_by_path(["3d", "3d-assets"])),
          create(:product, taxonomy: nil),
        ]

        expect(presenter.taxonomies_for_nav(recommended_products:).first(2)).to contain_exactly(
          { key: Taxonomy.find_by(slug: "3d").id.to_s, slug: "3d", label: "3D", parent_key: nil },
          { key: Taxonomy.find_by(slug: "education").id.to_s, slug: "education", label: "Education", parent_key: nil },
        )
      end
    end
  end

  describe "#taxonomies_for_category_picker" do
    it "sorts taxonomies alphabetically by breadcrumb so each root is followed by its descendants" do
      picker_taxonomies = presenter.taxonomies_for_category_picker

      taxonomies_by_key = picker_taxonomies.index_by { |taxonomy| taxonomy[:key] }
      breadcrumbs = picker_taxonomies.map do |taxonomy|
        breadcrumb = [taxonomy[:label]]
        current = taxonomy
        while (current = taxonomies_by_key[current[:parent_key]])
          breadcrumb.unshift(current[:label])
        end
        breadcrumb.join(" > ").downcase
      end

      expect(breadcrumbs).to eq(breadcrumbs.sort)
    end

    it "returns the same taxonomies as the nav, reordered" do
      expect(presenter.taxonomies_for_category_picker).to match_array(presenter.taxonomies_for_nav)
    end

    it "places a parent immediately before its first child" do
      picker_taxonomies = presenter.taxonomies_for_category_picker
      three_d = Taxonomy.find_by(slug: "3d")
      three_d_index = picker_taxonomies.index { |taxonomy| taxonomy[:key] == three_d.id.to_s }

      expect(three_d_index).not_to be_nil
      expect(picker_taxonomies[three_d_index + 1][:parent_key]).to eq(three_d.id.to_s)
    end
  end
end
