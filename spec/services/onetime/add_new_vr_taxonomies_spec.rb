# frozen_string_literal: true

require "spec_helper"

describe Onetime::AddNewVrTaxonomies do
  before do
    Taxonomy.delete_all
    three_d = Taxonomy.create!(slug: "3d")
    three_d_assets = Taxonomy.create!(slug: "3d-assets", parent: three_d)
    Taxonomy.create!(slug: "unity", parent: three_d_assets)
    gaming = Taxonomy.create!(slug: "gaming")
    Taxonomy.create!(slug: "vrchat", parent: gaming)
  end

  it "moves the vrchat taxonomy to 3d" do
    described_class.process
    expect(Taxonomy.find_by(slug: "vrchat").parent.slug).to eq("3d")
  end

  it "creates the correct number of new taxonomies" do
    new_taxonomies_count = 81
    old_taxonomy_count = Taxonomy.count
    expect do
      described_class.process
    end.to change { Taxonomy.count }.from(old_taxonomy_count).to(old_taxonomy_count + new_taxonomies_count)
  end

  it "doesn't create taxonomies without a parent" do
    old_root_taxonomy_count = Taxonomy.where(parent: nil).count
    described_class.process
    expect(Taxonomy.where(parent: nil).count).to eq(old_root_taxonomy_count)
  end
end
