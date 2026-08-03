# frozen_string_literal: true

require "spec_helper"

describe Onetime::SeedTaxonomies do
  # The seed file's own leaves, not invented slugs: the point of this service is that it applies
  # that file, so a fixture tree of its own would pass while the real seed never loaded.
  let(:seeded_slug_path) { ["software-development", "cybersecurity", "network-security"] }

  it "creates the taxonomy tree" do
    Taxonomy.delete_all
    TaxonomyHierarchy.delete_all

    expect { described_class.process }.to change { Taxonomy.count }.from(0)
    expect(Taxonomy.find_by_path(seeded_slug_path)).to be_present
  end

  it "returns the number of rows it created" do
    Taxonomy.delete_all
    TaxonomyHierarchy.delete_all

    created = described_class.process

    expect(created).to eq(Taxonomy.count)
    expect(created).to be > 0
  end

  it "is idempotent" do
    described_class.process
    count_after_first_run = Taxonomy.count

    expect(described_class.process).to eq(0)
    expect(Taxonomy.count).to eq(count_after_first_run)
  end

  # A bare insert would leave self_and_ancestors empty, which taxonomies_for_nav calls to group a
  # recommended product under its root. find_by_path walks parent_id, so it survives that bug.
  it "registers the closure_tree hierarchy" do
    Taxonomy.delete_all
    TaxonomyHierarchy.delete_all

    described_class.process

    leaf = Taxonomy.find_by_path(seeded_slug_path)
    expect(leaf.self_and_ancestors.map(&:slug)).to eq(seeded_slug_path.reverse)
  end

  it "busts the nav cache" do
    Rails.cache.write("taxonomies_for_nav", "stale")

    described_class.process

    expect(Rails.cache.read("taxonomies_for_nav")).to be_nil
  end

  # The seed file's last line applies TaxonomyAttributeDefinitions, so this task owns attribute rows
  # too. Pinned because the deactivation is destructive-ish and invisible from the service's name.
  it "applies the taxonomy attribute registry, deactivating rows absent from it" do
    described_class.process

    fonts = Taxonomy.find_by_path(%w[design fonts])
    expect(TaxonomyAttribute.where(taxonomy: fonts, active: true).pluck(:name))
      .to match_array(TaxonomyAttributeDefinitions::DEFINITIONS["design/fonts"].map { _1[:name] })

    stale = TaxonomyAttribute.create!(taxonomy: fonts, name: "not_in_registry", label: "Stale",
                                      value_type: "enum", values: [], position: 9, active: true)

    described_class.process

    expect(stale.reload.active).to be(false)
  end

  it "refuses to run when the seed file's skip flag is set" do
    # Set the real variable rather than stub_const("ENV", hash): ENV is not a Hash, so replacing it
    # with one passes here while diverging from what the seed file's own top-level guard reads.
    original = ENV["SKIP_TAXONOMY_CREATION"]
    ENV["SKIP_TAXONOMY_CREATION"] = "1"

    expect { described_class.process }.to raise_error(/refusing to report success/)
  ensure
    ENV["SKIP_TAXONOMY_CREATION"] = original
  end
end
