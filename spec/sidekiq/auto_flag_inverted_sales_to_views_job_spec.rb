# frozen_string_literal: true

require "spec_helper"

describe AutoFlagInvertedSalesToViewsJob do
  it "runs the detector" do
    detector = instance_double(AutoFlagInvertedSalesToViews, process: [])
    expect(AutoFlagInvertedSalesToViews).to receive(:new).and_return(detector)

    described_class.new.perform
  end

  it "logs the products it took down, so a quiet run is distinguishable from a busy one" do
    detector = instance_double(AutoFlagInvertedSalesToViews, process: [11, 22])
    allow(AutoFlagInvertedSalesToViews).to receive(:new).and_return(detector)

    expect(Rails.logger).to receive(:info).with(/product ids: 11, 22/)

    described_class.new.perform
  end

  it "runs on the default queue, because it exists to stop an in-flight blast" do
    expect(described_class.sidekiq_options["queue"].to_s).to eq("default")
  end
end
