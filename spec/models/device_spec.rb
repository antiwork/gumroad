# frozen_string_literal: true

require "spec_helper"

describe Device do
  describe "creating" do
    it "deletes existing token if already linked with other account" do
      device = create(:device, token: "x" * 64, device_type: "ios")
      create(:device, token: "x" * 64, device_type: "ios")
      expect(Device.where(id: device.id)).to be_empty
    end
  end
  describe "validation" do
    describe "token" do
      it "is present" do
        expect(build(:device, token: "x" * 64)).to be_valid
      end

      it "is not present" do
        expect(build(:device, token: nil)).to be_invalid
      end
    end

    describe "device_type" do
      it "is present" do
        expect(build(:device, device_type: Device::DEVICE_TYPES.values.first)).to be_valid
      end

      it "is not present" do
        expect(build(:device, device_type: nil)).to be_invalid
      end

      it "is invalid type" do
        expect(build(:device, device_type: "windows")).to be_invalid
      end
    end

    describe "device_type" do
      it "is present" do
        expect(build(:device, app_type: Device::APP_TYPES.values.first)).to be_valid
      end

      it "is not present" do
        expect(build(:device, app_type: nil)).to be_invalid
      end

      it "is invalid type" do
        expect(build(:device, app_type: "windows")).to be_invalid
      end
    end
  end
end
