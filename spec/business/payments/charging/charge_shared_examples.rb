# frozen_string_literal: true

require "spec_helper"

shared_examples "a base processor charge" do
  describe "#[]" do
    before do
      subject.id = "charge-id"
    end

    it "gives access to getting attributes" do
      expect(subject[:id]).to eq("charge-id")
    end
  end

  describe "#flow_of_funds" do
    it "has a flow of funds" do
      expect(subject.flow_of_funds).to be_present
    end

    it "has a flow of funds with a issued amount" do
      expect(subject.flow_of_funds.issued_amount).to be_present
    end

    it "has a flow of funds with a settled amount" do
      expect(subject.flow_of_funds.settled_amount).to be_present
    end

    it "has a flow of funds with a gumroad amount" do
      expect(subject.flow_of_funds.gumroad_amount).to be_present
    end
  end
end
