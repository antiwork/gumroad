# frozen_string_literal: true

require "test_helper"
require "digest"

class LicenseTest < ActiveSupport::TestCase
  self.described_class = License



  context_ License do
  context_ "validations" do
  test "does not allow users to unset token" do
        license = create(:license)
        license.serial = nil
        expect(license).not_to be_valid
      end

  test "populates serial correctly on new licenses" do
        link = create(:product)
        license = create(:license, link:)
        expect(license.serial).to match(/\A.{8}-.{8}-.{8}-.{8}\z/)
      end
    end

  context_ "#disabled?" do
      let(:license) { create(:license) }

  context_ "when disabled" do
  test "returns true" do
          license.disabled_at = Date.current

          expect(license.disabled?).to eq true
        end
      end

  context_ "when enabled" do
  test "returns false" do
          expect(license.disabled?).to eq false
        end
      end
    end

  context_ "#disable!" do
      let(:license) { create(:license) }

  test "disables the license" do
        current_time = Time.current.change(usec: 0)
        travel_to(current_time) do
          expect(license.disable!).to be(true)
          expect(license.reload.disabled_at).to eq current_time
        end
      end

  test "raises an exception on error" do
        license.serial = nil

        expect { license.disable! }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

  context_ "#enable!" do
      let(:license) { create(:license, disabled_at: Time.current) }

  test "enables the license" do
        expect(license.enable!).to be(true)
        expect(license.reload.disabled_at).to eq nil
      end

  test "raises an exception on error" do
        license.serial = nil

        expect { license.enable! }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

  context_ "#rotate!" do
      let(:license) { create(:license) }

  test "generates a new serial key" do
        old_serial = license.serial
        expect(license.rotate!).to be(true)
        expect(license.reload.serial).not_to eq old_serial
        expect(license.serial).to match(/\A.{8}-.{8}-.{8}-.{8}\z/)
      end
    end

  context_ "search index callbacks" do
      let!(:purchase) { create(:purchase, :with_license) }
      let!(:license) { purchase.license }

  test "enqueues a purchase re-index when uses changes via increment!" do
        expect(ElasticsearchIndexerWorker).to receive(:perform_in).with(
          2.seconds,
          "update",
          hash_including(
            "record_id" => purchase.id,
            "class_name" => "Purchase",
            "fields" => ["license_uses"]
          )
        )
        license.increment!(:uses)
      end

  test "enqueues a purchase re-index when serial changes" do
        expect(ElasticsearchIndexerWorker).to receive(:perform_in).with(
          2.seconds,
          "update",
          hash_including(
            "record_id" => purchase.id,
            "class_name" => "Purchase",
            "fields" => ["license_serial"]
          )
        )
        license.rotate!
      end

  test "does not enqueue a purchase re-index when neither uses nor serial changes" do
        expect(ElasticsearchIndexerWorker).not_to receive(:perform_in)
        license.update!(disabled_at: Time.current)
      end

  test "does not enqueue a purchase re-index when there is no associated purchase" do
        license_without_purchase = create(:license, link: create(:product), purchase: nil)
        expect(ElasticsearchIndexerWorker).not_to receive(:perform_in)
        license_without_purchase.increment!(:uses)
      end
    end

  context_ "paper_trail versioning" do
      with_versioning do
        let(:license) { create(:license) }

  test "tracks changes to disabled_at when disabling" do
          expect { license.disable! }.to change { license.versions.count }.by(1)
          expect(license.versions.last.changeset).to have_key("disabled_at")
        end

  test "tracks changes to disabled_at when enabling" do
          license.disable!
          expect { license.enable! }.to change { license.versions.count }.by(1)
          expect(license.versions.last.changeset).to have_key("disabled_at")
        end

  test "tracks changes to serial when rotating" do
          expect { license.rotate! }.to change { license.versions.count }.by(1)
          expect(license.versions.last.changeset).to have_key("serial")
        end

  test "does not track changes to uses" do
          expect { license.increment!(:uses) }.not_to change { license.versions.count }
        end
      end
    end
  end
end
