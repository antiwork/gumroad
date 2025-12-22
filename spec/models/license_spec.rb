# frozen_string_literal: true

require "spec_helper"
require "digest"

describe License do
  describe "validations" do
    it "does not allow users to unset token" do
      license = create(:license)
      license.serial = nil
      expect(license).to_not be_valid
    end

    it "populates serial correctly on new licenses" do
      link = create(:product)
      license = create(:license, link:)
      expect(license.serial).to match(/\A.{8}-.{8}-.{8}-.{8}\z/)
    end
  end

  describe "#disabled?" do
    let(:license) { create(:license) }

    context "when disabled" do
      it "returns true" do
        license.disabled_at = Date.current

        expect(license.disabled?).to eq true
      end
    end

    context "when enabled" do
      it "returns false" do
        expect(license.disabled?).to eq false
      end
    end
  end

  describe "#disable!" do
    let(:license) { create(:license) }

    it "disables the license" do
      current_time = Time.current.change(usec: 0)
      travel_to(current_time) do
        expect(license.disable!).to be(true)
        expect(license.reload.disabled_at).to eq current_time
      end
    end

    it "raises an exception on error" do
      license.serial = nil

      expect { license.disable! }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "#enable!" do
    let(:license) { create(:license, disabled_at: Time.current) }

    it "enables the license" do
      expect(license.enable!).to be(true)
      expect(license.reload.disabled_at).to eq nil
    end

    it "raises an exception on error" do
      license.serial = nil

      expect { license.enable! }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "#rotate!" do
    let(:license) { create(:license) }

    it "generates a new serial key" do
      old_serial = license.serial
      expect(license.rotate!).to be(true)
      expect(license.reload.serial).not_to eq old_serial
      expect(license.serial).to match(/\A.{8}-.{8}-.{8}-.{8}\z/)
    end
  end

  describe "paper_trail versioning" do
    with_versioning do
      let(:license) { create(:license) }

      it "tracks changes to disabled_at when disabling" do
        expect { license.disable! }.to change { license.versions.count }.by(1)
        expect(license.versions.last.changeset).to have_key("disabled_at")
      end

      it "tracks changes to disabled_at when enabling" do
        license.disable!
        expect { license.enable! }.to change { license.versions.count }.by(1)
        expect(license.versions.last.changeset).to have_key("disabled_at")
      end

      it "tracks changes to serial when rotating" do
        expect { license.rotate! }.to change { license.versions.count }.by(1)
        expect(license.versions.last.changeset).to have_key("serial")
      end

      it "does not track changes to uses" do
        expect { license.increment!(:uses) }.not_to change { license.versions.count }
      end
    end
  end
end
