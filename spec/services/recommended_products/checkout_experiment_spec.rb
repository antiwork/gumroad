# frozen_string_literal: true

require "spec_helper"

describe RecommendedProducts::CheckoutExperiment do
  let(:guids) { (1..400).map { "guid-#{_1}" } }

  describe "arm assignment" do
    it "is control for everyone while the flag is off" do
      expect(guids.map { described_class.phone_placement_treatment?(_1) }).to all(be(false))
      expect(guids.map { described_class.co_purchase_ordering_treatment?(_1) }).to all(be(false))
    end

    it "is control without a browser guid" do
      Feature.activate(described_class::PHONE_PLACEMENT)

      expect(described_class.phone_placement_treatment?(nil)).to be(false)
      expect(described_class.phone_placement_treatment?("")).to be(false)
    end

    it "splits buyers roughly by TREATMENT_PERCENTAGE and is stable per buyer" do
      Feature.activate(described_class::ORDERING)

      arms = guids.map { described_class.co_purchase_ordering_treatment?(_1) }

      expect(arms.count(true)).to be_within(60).of(guids.size * described_class::TREATMENT_PERCENTAGE / 100)
      expect(guids.map { described_class.co_purchase_ordering_treatment?(_1) }).to eq(arms)
    end

    it "matches the SQL bucket used to read results" do
      Feature.activate(described_class::ORDERING)

      guids.first(20).each do |guid|
        bucket = ActiveRecord::Base.connection.select_value(
          ActiveRecord::Base.sanitize_sql_array(["SELECT CRC32(CONCAT(?, ':', ?)) % 100", described_class::ORDERING, guid])
        )
        expect(described_class.co_purchase_ordering_treatment?(guid)).to eq(bucket < described_class::TREATMENT_PERCENTAGE)
      end
    end

    it "assigns the two experiments independently" do
      Feature.activate(described_class::PHONE_PLACEMENT)
      Feature.activate(described_class::ORDERING)

      pairs = guids.map { [described_class.phone_placement_treatment?(_1), described_class.co_purchase_ordering_treatment?(_1)] }

      expect(pairs.uniq.size).to eq(4)
    end
  end
end
