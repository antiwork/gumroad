# frozen_string_literal: true

require "spec_helper"

describe CleanupRpushDeviceService do
  before do
    @device_a = create(:device)
    @device_b = create(:device)
    @device_c = create(:device)
  end

  it "removes device records for the undeliverable token" do
    apn_feedback = double(device_token: @device_b.token)

    expect(apn_feedback).to receive(:destroy)

    expect do
      CleanupRpushDeviceService.new(apn_feedback).process
    end.to change { Device.all.count }.from(3).to(2)

    expect(Device.all.ids).to_not include(@device_b.id)
  end

  # Make sure there's no problem in the portion of code we stubbed in the above spec
  it "works without any errors" do
    apn_feedback = double(device_token: @device_b.token, destroy: true)

    expect do
      CleanupRpushDeviceService.new(apn_feedback).process
    end.to_not raise_error
  end
end
