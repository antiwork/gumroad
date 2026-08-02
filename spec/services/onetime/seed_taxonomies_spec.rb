# frozen_string_literal: true

require "spec_helper"

describe Onetime::SeedTaxonomies do
  let(:cybersecurity_paths) do
    [
      "software-development/cybersecurity",
      "software-development/cybersecurity/network-security",
      "software-development/cybersecurity/penetration-testing",
      "software-development/cybersecurity/security-compliance",
      "software-development/cybersecurity/privacy-and-encryption",
    ]
  end

  # The spec database is already seeded, so exercising the create path means removing rows first.
  # Cybersecurity is the newest subtree and nothing else references it.
  def delete_cybersecurity_subtree
    cybersecurity = Taxonomy.find_by_path(["software-development", "cybersecurity"])
    Taxonomy.where(parent: cybersecurity).destroy_all
    cybersecurity.destroy!
  end

  describe "#process" do
    it "reports the missing rows without creating anything when dry_run" do
      delete_cybersecurity_subtree

      expect do
        expect(described_class.new.process).to match_array(cybersecurity_paths)
      end.not_to change(Taxonomy, :count)
    end

    it "creates the missing rows under the right parent when dry_run is off" do
      delete_cybersecurity_subtree

      expect(described_class.new(dry_run: false).process).to match_array(cybersecurity_paths)

      cybersecurity = Taxonomy.find_by_path(["software-development", "cybersecurity"])
      expect(cybersecurity).to be_present
      expect(Taxonomy.where(parent: cybersecurity).pluck(:slug)).to match_array(
        %w[network-security penetration-testing security-compliance privacy-and-encryption]
      )
    end

    it "reports a created row whose slug already exists under a different parent" do
      # illustrator is seeded twice, under print-and-packaging and under mockups. Deleting only the
      # mockups one leaves the slug present elsewhere, which is what a slug-keyed diff cannot see.
      mockups_illustrator = Taxonomy.find_by_path(%w[design graphics mockups illustrator])
      expect(Taxonomy.find_by_path(%w[design print-and-packaging illustrator])).to be_present
      mockups_illustrator.destroy!

      created = nil
      expect do
        created = described_class.new(dry_run: false).process
      end.to change(Taxonomy, :count).by(1)

      expect(created).to eq(["design/graphics/mockups/illustrator"])
      expect(Taxonomy.find_by_path(%w[design graphics mockups illustrator])).to be_present
    end

    it "is idempotent — a second run against a fully seeded database creates nothing" do
      expect do
        expect(described_class.new(dry_run: false).process).to be_empty
      end.not_to change(Taxonomy, :count)
    end
  end
end
