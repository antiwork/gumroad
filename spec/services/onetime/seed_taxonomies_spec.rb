# frozen_string_literal: true

require "spec_helper"

describe Onetime::SeedTaxonomies do
  # The spec database is already seeded, so exercising the create path means removing rows first.
  # Cybersecurity is the newest subtree and nothing else references it.
  def delete_cybersecurity_subtree
    cybersecurity = Taxonomy.find_by_path(["software-development", "cybersecurity"])
    Taxonomy.where(parent: cybersecurity).destroy_all
    cybersecurity.destroy!
  end

  describe "#process" do
    it "reports the missing slugs without creating anything when dry_run" do
      delete_cybersecurity_subtree

      expect do
        missing = described_class.new.process

        expect(missing).to match_array(
          %w[cybersecurity network-security penetration-testing security-compliance privacy-and-encryption]
        )
      end.not_to change(Taxonomy, :count)
    end

    it "creates the missing rows under the right parent when dry_run is off" do
      delete_cybersecurity_subtree

      created = described_class.new(dry_run: false).process

      expect(created).to match_array(
        %w[cybersecurity network-security penetration-testing security-compliance privacy-and-encryption]
      )

      cybersecurity = Taxonomy.find_by_path(["software-development", "cybersecurity"])
      expect(cybersecurity).to be_present
      expect(Taxonomy.where(parent: cybersecurity).pluck(:slug)).to match_array(
        %w[network-security penetration-testing security-compliance privacy-and-encryption]
      )
    end

    it "is idempotent — a second run against a fully seeded database creates nothing" do
      expect do
        expect(described_class.new(dry_run: false).process).to be_empty
      end.not_to change(Taxonomy, :count)
    end
  end
end
