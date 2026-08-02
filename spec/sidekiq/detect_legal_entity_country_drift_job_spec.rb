# frozen_string_literal: true

require "spec_helper"

describe DetectLegalEntityCountryDriftJob do
  let(:seller) { create(:user) }

  def stripe_account_for(country)
    create(:merchant_account, user: seller, country:)
  end

  describe "#perform" do
    it "notes the mismatch when the derived legal-entity country differs from the Stripe account country" do
      stripe_account_for("US")
      compliance_info = create(:user_compliance_info_singapore, user: seller)

      expect do
        described_class.new.perform(compliance_info.id)
      end.to change { seller.comments.with_type_note.count }.by(1)

      comment = seller.comments.with_type_note.last
      expect(comment.author_name).to eq(described_class::AUTHOR_NAME)
      expect(comment.content).to include("Legal-entity country SG")
      expect(comment.content).to include("Stripe account country US")
    end

    it "does nothing when the two countries agree" do
      stripe_account_for("US")
      compliance_info = create(:user_compliance_info, user: seller)

      expect do
        described_class.new.perform(compliance_info.id)
      end.not_to change { seller.comments.count }
    end

    it "uses the business country when the record is a business" do
      stripe_account_for("US")
      compliance_info = create(:user_compliance_info_mex_business, user: seller)

      expect do
        described_class.new.perform(compliance_info.id)
      end.to change { seller.comments.with_type_note.count }.by(1)
      expect(seller.comments.with_type_note.last.content).to include("Legal-entity country MX")
    end

    it "does not re-note the same mismatch inside the dedup window" do
      stripe_account_for("US")
      compliance_info = create(:user_compliance_info_singapore, user: seller)
      described_class.new.perform(compliance_info.id)

      expect do
        described_class.new.perform(compliance_info.id)
      end.not_to change { seller.comments.count }
    end

    it "notes again once the dedup window has passed" do
      stripe_account_for("US")
      compliance_info = create(:user_compliance_info_singapore, user: seller)
      described_class.new.perform(compliance_info.id)

      travel_to(described_class::DEDUP_WINDOW.from_now + 1.day) do
        expect do
          described_class.new.perform(compliance_info.id)
        end.to change { seller.comments.with_type_note.count }.by(1)
      end
    end

    it "ignores sellers on their own Stripe Connect account" do
      create(:merchant_account_stripe_connect, user: seller, country: "US")
      compliance_info = create(:user_compliance_info_singapore, user: seller)

      expect do
        described_class.new.perform(compliance_info.id)
      end.not_to change { seller.comments.count }
    end

    it "does nothing when the seller has no Stripe account" do
      compliance_info = create(:user_compliance_info_singapore, user: seller)

      expect do
        described_class.new.perform(compliance_info.id)
      end.not_to change { seller.comments.count }
    end

    it "does nothing when the compliance record no longer exists" do
      expect { described_class.new.perform(0) }.not_to raise_error
    end
  end

  describe "enqueueing from UserComplianceInfo" do
    it "is enqueued when a compliance record is created" do
      expect do
        create(:user_compliance_info, user: seller, skip_stripe_job_on_create: true)
      end.to change { described_class.jobs.size }.by(1)
    end
  end
end
