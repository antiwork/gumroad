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

  it "refuses to run when the seed file's skip flag is set" do
    stub_const("ENV", ENV.to_hash.merge("SKIP_TAXONOMY_CREATION" => "1"))

    expect { described_class.process }.to raise_error(/refusing to report success/)
  end
end
