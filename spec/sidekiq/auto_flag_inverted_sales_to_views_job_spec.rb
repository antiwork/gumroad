# frozen_string_literal: true

require "spec_helper"

describe AutoFlagInvertedSalesToViewsJob do
  it "runs the detector" do
    detector = instance_double(AutoFlagInvertedSalesToViews, process: [])
    expect(AutoFlagInvertedSalesToViews).to receive(:new).and_return(detector)

    described_class.new.perform
  end
end
