# frozen_string_literal: true

require "test_helper"

class CleanupRpushDeviceServiceTest < ActiveSupport::TestCase
  self.described_class = CleanupRpushDeviceService



  context_ CleanupRpushDeviceService do
    before do
      @device_a = create(:device)
      @device_b = create(:device)
      @device_c = create(:device)
    end

  test "removes device records for the undeliverable token" do
      apn_feedback = double(device_token: @device_b.token)

      expect(apn_feedback).to receive(:destroy)

      expect do
        CleanupRpushDeviceService.new(apn_feedback).process
      end.to change { Device.all.count }.from(3).to(2)

      expect(Device.all.ids).not_to include(@device_b.id)
    end

    # Make sure there's no problem in the portion of code we stubbed in the above spec
  test "works without any errors" do
      apn_feedback = double(device_token: @device_b.token, destroy: true)

      expect do
        CleanupRpushDeviceService.new(apn_feedback).process
      end.not_to raise_error
    end
  end
end
