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

  describe "#set_uses!" do
    let(:license) { create(:license, uses: 5) }

    it "sets the uses count to the given value" do
      expect(license.set_uses!(12)).to be(true)
      expect(license.reload.uses).to eq 12
    end

    it "lowers the uses count" do
      expect(license.set_uses!(2)).to be(true)
      expect(license.reload.uses).to eq 2
    end

    it "rejects a negative value" do
      expect { license.set_uses!(-1) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(license.reload.uses).to eq 5
    end
  end

  describe "#adjust_uses!" do
    let(:license) { create(:license, uses: 5) }

    it "increments by a positive delta" do
      expect(license.adjust_uses!(3)).to be(true)
      expect(license.reload.uses).to eq 8
    end

    it "decrements by a negative delta" do
      expect(license.adjust_uses!(-2)).to be(true)
      expect(license.reload.uses).to eq 3
    end

    it "floors at zero" do
      expect(license.adjust_uses!(-99)).to be(true)
      expect(license.reload.uses).to eq 0
    end

    # The controller bounds the delta, not the count it lands on — verify calls move that without
    # a ceiling — so the clamp has to live here.
    it "clamps at the ceiling" do
      license.update!(uses: License::MAX_SELLER_SETTABLE_USES)
      expect(license.adjust_uses!(1)).to be(true)
      expect(license.reload.uses).to eq License::MAX_SELLER_SETTABLE_USES
    end

    # Reads the stored value under the lock, so a change made after this instance was loaded is
    # preserved rather than overwritten.
    it "applies the delta to the stored count rather than the loaded one" do
      License.find(license.id).update!(uses: 20)
      license.adjust_uses!(1)
      expect(license.reload.uses).to eq 21
    end
  end

  describe "#reset_uses!" do
    let(:license) { create(:license, uses: 5) }

    it "resets the uses count to zero" do
      expect(license.reset_uses!).to be(true)
      expect(license.reload.uses).to eq 0
    end

    it "is a no-op result-wise when uses is already zero" do
      license.update!(uses: 0)
      expect(license.reset_uses!).to be(true)
      expect(license.reload.uses).to eq 0
    end
  end

  describe "search index callbacks" do
    let!(:purchase) { create(:purchase, :with_license) }
    let!(:license) { purchase.license }

    it "enqueues a purchase re-index when uses changes via increment!" do
      # A uses change also syncs the buyer's AudienceMember document (its license_uses
      # detail feeds the "minimum license uses" audience filter), and that sync enqueues
      # its own indexer jobs now that audience-member indexing is unconditional
      # (index_audience_members flag removal, gp#1208 / #6232). Allow those calls and
      # assert only on the purchase re-index.
      allow(ElasticsearchIndexerWorker).to receive(:perform_in)
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

    it "enqueues a purchase re-index when uses is set directly" do
      allow(ElasticsearchIndexerWorker).to receive(:perform_in)
      expect(ElasticsearchIndexerWorker).to receive(:perform_in).with(
        2.seconds,
        "update",
        hash_including(
          "record_id" => purchase.id,
          "class_name" => "Purchase",
          "fields" => ["license_uses"]
        )
      )
      license.set_uses!(7)
    end

    it "enqueues a purchase re-index when serial changes" do
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

    it "does not enqueue a purchase re-index when neither uses nor serial changes" do
      expect(ElasticsearchIndexerWorker).not_to receive(:perform_in)
      license.update!(disabled_at: Time.current)
    end

    it "does not enqueue a purchase re-index when there is no associated purchase" do
      license_without_purchase = create(:license, link: create(:product), purchase: nil)
      expect(ElasticsearchIndexerWorker).not_to receive(:perform_in)
      license_without_purchase.increment!(:uses)
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
