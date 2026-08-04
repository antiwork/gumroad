# frozen_string_literal: true

require "spec_helper"

describe Onetime::SeedTaxonomyAttributes do
  let!(:design) { Taxonomy.find_or_create_by!(slug: "design") }
  let!(:fonts) { Taxonomy.find_or_create_by!(slug: "fonts", parent: design) }

  before { TaxonomyAttribute.where(taxonomy: fonts).delete_all }

  it "does not write anything on a dry run" do
    expect { described_class.process(dry_run: true) }.not_to change { TaxonomyAttribute.count }
  end

  it "creates the registry's definitions for the matched taxonomy" do
    result = described_class.process(dry_run: false)

    expect(result[:created]).to eq(6)
    expect(TaxonomyAttribute.where(taxonomy: fonts).pluck(:name)).to match_array(%w[classification format license variable_font has_multiple_weights styles])

    format = TaxonomyAttribute.find_by(taxonomy: fonts, name: "format")
    expect(format.label).to eq("Format")
    expect(format.value_type).to eq("enum")
    expect(format.values).to eq(["OTF", "TTF", "WOFF2"])
    expect(format.active).to eq(true)
  end

  it "is idempotent" do
    described_class.process(dry_run: false)

    expect { described_class.process(dry_run: false) }.not_to change { TaxonomyAttribute.count }
  end

  it "updates a drifted row in place so its id and indexed filter tokens survive" do
    described_class.process(dry_run: false)
    format = TaxonomyAttribute.find_by(taxonomy: fonts, name: "format")
    format.update!(label: "Old label", values: ["OTF"], active: false)

    described_class.process(dry_run: false)

    format.reload
    expect(format.label).to eq("Format")
    expect(format.values).to eq(["OTF", "TTF", "WOFF2"])
    expect(format.active).to eq(true)
  end

  it "leaves a row the registry no longer defines active by default" do
    described_class.process(dry_run: false)
    orphan = TaxonomyAttribute.create!(taxonomy: fonts, name: "retired_facet", label: "Retired", value_type: "enum", values: ["A"], position: 9, active: true)

    result = described_class.process(dry_run: false)

    expect(orphan.reload.active).to eq(true)
    expect(result[:deactivated]).to eq(0)
    expect(result[:stale_candidates]).to include("fonts/retired_facet")
  end

  it "deactivates a row the registry no longer defines instead of deleting it, when deactivate: true is passed explicitly" do
    described_class.process(dry_run: false)
    orphan = TaxonomyAttribute.create!(taxonomy: fonts, name: "retired_facet", label: "Retired", value_type: "enum", values: ["A"], position: 9, active: true)

    described_class.process(dry_run: false, deactivate: true)

    expect(orphan.reload.active).to eq(false)
    expect(TaxonomyAttribute.exists?(orphan.id)).to eq(true)
  end
end
