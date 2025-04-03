# frozen_string_literal: true

require "spec_helper"

shared_examples_for "stripe chargeable common" do
  describe "#charge_processor_id" do
    it "returns 'stripe'" do
      expect(chargeable.charge_processor_id).to eq "stripe"
    end
  end
end
