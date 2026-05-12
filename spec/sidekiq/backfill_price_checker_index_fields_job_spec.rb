# frozen_string_literal: true

require "spec_helper"

describe BackfillPriceCheckerIndexFieldsJob do
  it "delegates to Onetime::BackfillPriceCheckerIndexFields.process" do
    expect(Onetime::BackfillPriceCheckerIndexFields).to receive(:process)
    described_class.new.perform
  end
end
