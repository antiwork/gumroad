# frozen_string_literal: true

require "test_helper"

class DeviceTest < ActiveSupport::TestCase
  self.described_class = Device



  context_ Device do
  context_ "creating" do
  test "deletes existing token if already linked with other account" do
        device = create(:device, token: "x" * 64, device_type: "ios")
        create(:device, token: "x" * 64, device_type: "ios")
        expect(Device.where(id: device.id)).to be_empty
      end
    end
  context_ "validation" do
  context_ "token" do
  test "is present" do
          expect(build(:device, token: "x" * 64)).to be_valid
        end

  test "is not present" do
          expect(build(:device, token: nil)).to be_invalid
        end
      end

  context_ "device_type" do
  test "is present" do
          expect(build(:device, device_type: Device::DEVICE_TYPES.values.first)).to be_valid
        end

  test "is not present" do
          expect(build(:device, device_type: nil)).to be_invalid
        end

  test "is invalid type" do
          expect(build(:device, device_type: "windows")).to be_invalid
        end
      end

  context_ "device_type" do
  test "is present" do
          expect(build(:device, app_type: Device::APP_TYPES.values.first)).to be_valid
        end

  test "is not present" do
          expect(build(:device, app_type: nil)).to be_invalid
        end

  test "is invalid type" do
          expect(build(:device, app_type: "windows")).to be_invalid
        end
      end
    end
  end
end
