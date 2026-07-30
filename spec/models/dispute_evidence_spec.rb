# frozen_string_literal: true

require "spec_helper"

describe DisputeEvidence do
  let(:dispute_evidence) do
    DisputeEvidence.create!(
      dispute: create(:dispute),
      purchased_at: "",
      customer_purchase_ip: "",
      customer_email: " joe@example.com",
      customer_name: " Joe Doe ",
      billing_address: " 123 Sample St, San Francisco, CA, 12343, United States ",
      shipping_address: " 123 Sample St, San Francisco, CA, 12343, United States ",
      shipped_at: "",
      shipping_carrier: " USPS ",
      shipping_tracking_number: " 1234567890 ",
      uncategorized_text: " Sample evidence text ",
      product_description: " Sample product description ",
      resolved_at: "",
      reason_for_winning: " Sample reason for winning ",
      cancellation_rebuttal: " Sample cancellation rebuttal ",
      refund_refusal_explanation: " Sample refund refusal explanation ",
    )
  end

  describe "stripped_fields" do
    it "strips fields" do
      expect(dispute_evidence.purchased_at).to be(nil)
      expect(dispute_evidence.customer_purchase_ip).to be(nil)
      expect(dispute_evidence.customer_email).to eq("joe@example.com")
      expect(dispute_evidence.customer_name).to eq("Joe Doe")
      expect(dispute_evidence.billing_address).to eq("123 Sample St, San Francisco, CA, 12343, United States")
      expect(dispute_evidence.shipping_address).to eq("123 Sample St, San Francisco, CA, 12343, United States")
      expect(dispute_evidence.shipped_at).to be(nil)
      expect(dispute_evidence.shipping_carrier).to eq("USPS")
      expect(dispute_evidence.shipping_tracking_number).to eq("1234567890")
      expect(dispute_evidence.uncategorized_text).to eq("Sample evidence text")
      expect(dispute_evidence.resolved_at).to be(nil)
      expect(dispute_evidence.product_description).to eq("Sample product description")
      expect(dispute_evidence.reason_for_winning).to eq("Sample reason for winning")
      expect(dispute_evidence.cancellation_rebuttal).to eq("Sample cancellation rebuttal")
      expect(dispute_evidence.refund_refusal_explanation).to eq("Sample refund refusal explanation")
    end
  end

  describe "policy fields" do
    before do
      dispute_evidence.dispute = dispute
      dispute_evidence.policy_disclosure = "Sample policy disclosure"
      dispute_evidence.policy_image.attach(
        Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png")
      )
      dispute_evidence.save!
    end

    context "when the product is not membership" do
      let(:dispute) { create(:dispute_formalized) }

      it "it assigns data to refund_policy_* fields" do
        expect(dispute_evidence.refund_policy_disclosure).to eq("Sample policy disclosure")
        expect(dispute_evidence.cancellation_policy_disclosure).to be(nil)

        expect(dispute_evidence.refund_policy_image.attached?).to be(true)
        expect(dispute_evidence.cancellation_policy_image.attached?).to be(false)
      end
    end

    context "when the product is membership" do
      let(:dispute) { create(:dispute_formalized, purchase: create(:membership_purchase)) }

      it "it assigns data to cancellation_policy_* fields" do
        expect(dispute_evidence.cancellation_policy_disclosure).to eq("Sample policy disclosure")
        expect(dispute_evidence.refund_policy_disclosure).to be(nil)

        expect(dispute_evidence.cancellation_policy_image.attached?).to be(true)
        expect(dispute_evidence.refund_policy_image.attached?).to be(false)
      end
    end

    context "when the product is a legacy subscription" do
      let(:dispute) do
        product = create(:subscription_product)
        subscription = create(:subscription, link: product, created_at: 3.days.ago)
        purchase = create(:purchase, is_original_subscription_purchase: true, link: product, subscription:)
        create(:dispute_formalized, purchase:)
      end

      it "it assigns data to cancellation_policy_* fields" do
        expect(dispute_evidence.cancellation_policy_disclosure).to eq("Sample policy disclosure")
        expect(dispute_evidence.refund_policy_disclosure).to be(nil)

        expect(dispute_evidence.cancellation_policy_image.attached?).to be(true)
        expect(dispute_evidence.refund_policy_image.attached?).to be(false)
      end
    end
  end

  describe "validations" do
    describe "customer_communication_file_size and all_files_size_within_limit" do
      context "when the file size is too big" do
        before do
          dispute_evidence.customer_communication_file.attach(
            Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "big_file.txt"), "image/jpeg")
          )
        end

        it "returns error" do
          expect(dispute_evidence.valid?).to eq(false)
          expect(dispute_evidence.errors[:base]).to eq(
            [
              "The file exceeds the maximum size allowed.",
              "Uploaded files exceed the maximum size allowed by Stripe."
            ]
          )
        end
      end
    end

    describe "customer_communication_file_type" do
      context "when the content type is not allowed" do
        before do
          dispute_evidence.customer_communication_file.attach(
            Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "blah.txt"), "text/plain")
          )
        end

        it "returns error" do
          expect(dispute_evidence.valid?).to eq(false)
          expect(dispute_evidence.errors[:base]).to eq(["Invalid file type."])
        end
      end
    end

    it "validates length of reason_for_winning" do
      dispute_evidence.reason_for_winning = "a" * 3_001
      expect(dispute_evidence.valid?).to eq(false)
      expect(dispute_evidence.errors[:reason_for_winning]).to eq(["is too long (maximum is 3000 characters)"])
    end

    it "validates length of refund_refusal_explanation" do
      dispute_evidence.refund_refusal_explanation = "a" * 3_001
      expect(dispute_evidence.valid?).to eq(false)
      expect(dispute_evidence.errors[:refund_refusal_explanation]).to eq(["is too long (maximum is 3000 characters)"])
    end

    it "validates length of cancellation_rebuttal" do
      dispute_evidence.cancellation_rebuttal = "a" * 3_001
      expect(dispute_evidence.valid?).to eq(false)
      expect(dispute_evidence.errors[:cancellation_rebuttal]).to eq(["is too long (maximum is 3000 characters)"])
    end
  end

  describe "#hours_left_to_submit_evidence" do
    context "when seller hasn't been contacted" do
      before do
        dispute_evidence.update_as_not_seller_contacted!
      end

      it "returns 0" do
        expect(dispute_evidence.hours_left_to_submit_evidence).to eq(0)
      end
    end

    context "when seller has been contacted" do
      before do
        dispute_evidence.update!(seller_contacted_at: 3.hours.ago)
      end

      it "returns correct value" do
        expect(dispute_evidence.hours_left_to_submit_evidence).to eq(DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS - 3)
      end
    end
  end

  describe ".hours_left_in_window" do
    it "returns 0 without a stamp" do
      expect(described_class.hours_left_in_window(nil)).to eq(0)
    end

    it "agrees with the instance method for the same stamp" do
      stamp = 3.hours.ago
      dispute_evidence.update!(seller_contacted_at: stamp)

      expect(described_class.hours_left_in_window(stamp))
        .to eq(dispute_evidence.hours_left_to_submit_evidence)
    end

    # The band where the old exact `elapsed < 72.hours` test in Charge::Disputable disagreed with
    # this rounded one: it called the window open while the notice's own body would have read
    # "in the next 0 hours". One predicate now answers for both, so the band cannot reopen.
    it "reports no hours left once rounding takes the window to zero, where an exact test would not" do
      elapsed = (DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS - 0.4).hours

      expect(described_class.hours_left_in_window(elapsed.ago)).to eq(0)
      expect(Time.current - elapsed.ago).to be < DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS.hours
    end

    it "goes negative past the window rather than flooring" do
      expect(described_class.hours_left_in_window((DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS + 1).hours.ago)).to eq(-1)
    end
  end

  describe ".accepting_evidence?" do
    def accepting?(seller_contacted_at: 1.hour.ago, seller_submitted_at: nil, resolved_at: nil)
      described_class.accepting_evidence?(seller_contacted_at:, seller_submitted_at:, resolved_at:)
    end

    it "accepts an open window" do
      expect(accepting?).to be(true)
    end

    # These two are what Purchases::DisputeEvidenceController#check_if_needs_redirect bounces on. A
    # caller that asks only about the window sends an action-required email to a page that redirects.
    it "declines once the seller has submitted" do
      expect(accepting?(seller_submitted_at: Time.current)).to be(false)
    end

    it "declines once the row is resolved" do
      expect(accepting?(resolved_at: Time.current)).to be(false)
    end

    it "declines an elapsed window" do
      expect(accepting?(seller_contacted_at: (DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS - 0.4).hours.ago)).to be(false)
    end

    # A dispute with no evidence surface at all (PayPal, Stripe Connect) has never had a window, and
    # still gets the plain notice — declining here would suppress every first notice instead.
    it "accepts an unstamped row so the first notice still goes out" do
      expect(accepting?(seller_contacted_at: nil)).to be(true)
    end

    it "declines an unstamped row that is already resolved" do
      expect(accepting?(seller_contacted_at: nil, resolved_at: Time.current)).to be(false)
    end

    it "agrees with the instance method reading the same row" do
      dispute_evidence.update!(seller_contacted_at: 1.hour.ago)
      expect(dispute_evidence.accepting_evidence?).to be(true)

      dispute_evidence.update!(seller_submitted_at: Time.current)
      expect(dispute_evidence.accepting_evidence?).to be(false)
    end
  end

  describe "#claim_seller_contacted_window!" do
    before { dispute_evidence.update_as_not_seller_contacted! }

    it "opens the window and reports the claim" do
      at = 30.hours.ago

      expect(dispute_evidence.claim_seller_contacted_window!(at:)).to be(true)
      expect(dispute_evidence.reload.seller_contacted_at).to be_within(1.second).of(at)
    end

    it "leaves an already-open window alone" do
      # Both writers of this column — formalization and CreateMissingDisputeEvidenceJob — claim
      # here, and the sweep's stamp is deliberately backdated to beat the processor's cutoff. A
      # later claim overwriting it with a fresh full-length window would submit evidence too late.
      dispute_evidence.claim_seller_contacted_window!(at: 30.hours.ago)
      original = dispute_evidence.reload.seller_contacted_at

      expect(dispute_evidence.claim_seller_contacted_window!).to be(false)
      expect(dispute_evidence.reload.seller_contacted_at).to eq(original)
    end

    it "does not touch the in-memory record, whose attachments may be mid-upload" do
      # Callers claim inside the transaction that builds the record and attaches its images, so a
      # reload here would reset those associations before ActiveStorage has uploaded the blobs.
      expect(dispute_evidence.claim_seller_contacted_window!).to be(true)
      expect(dispute_evidence.seller_contacted_at).to be_nil
    end

    it "does not open a window on resolved evidence" do
      dispute_evidence.update_as_resolved!(resolution: DisputeEvidence::RESOLUTION_SUBMITTED)

      expect(dispute_evidence.claim_seller_contacted_window!).to be(false)
      expect(dispute_evidence.reload.seller_contacted_at).to be_nil
    end
  end

  describe "#customer_communication_file_max_size" do
    before do
      dispute_evidence.receipt_image.attach(
        Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png")
      )
    end

    it "returns correct value" do
      expect(dispute_evidence.customer_communication_file_max_size < DisputeEvidence::STRIPE_MAX_COMBINED_FILE_SIZE).to be(true)
      expect(dispute_evidence.customer_communication_file_max_size).to eq(
        DisputeEvidence::STRIPE_MAX_COMBINED_FILE_SIZE -
        dispute_evidence.receipt_image.byte_size.to_i
      )
    end
  end

  describe "#policy_image_max_size" do
    before do
      dispute_evidence.receipt_image.attach(
        Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png")
      )
    end

    it "returns correct value" do
      expect(dispute_evidence.policy_image_max_size < DisputeEvidence::STRIPE_MAX_COMBINED_FILE_SIZE).to be(true)
      expect(dispute_evidence.policy_image_max_size).to eq(
        DisputeEvidence::STRIPE_MAX_COMBINED_FILE_SIZE -
        dispute_evidence.receipt_image.byte_size.to_i -
        DisputeEvidence::MINIMUM_RECOMMENDED_CUSTOMER_COMMUNICATION_FILE_SIZE
      )
    end
  end

  describe "#for_subscription_purchase?" do
    let!(:charge) do
      charge = create(:charge)
      charge.purchases << create(:purchase)
      charge.purchases << create(:purchase)
      charge.purchases << create(:purchase)
      charge
    end

    let!(:dispute_evidence) do
      DisputeEvidence.create!(
        dispute: create(:dispute_formalized_on_charge, charge: charge),
        purchased_at: "",
        customer_purchase_ip: "",
        customer_email: " joe@example.com",
        customer_name: " Joe Doe ",
        billing_address: " 123 Sample St, San Francisco, CA, 12343, United States ",
        shipping_address: " 123 Sample St, San Francisco, CA, 12343, United States ",
        shipped_at: "",
        shipping_carrier: " USPS ",
        shipping_tracking_number: " 1234567890 ",
        uncategorized_text: " Sample evidence text ",
        product_description: " Sample product description ",
        resolved_at: ""
      )
    end

    it "returns false if charge does not include any subscription purchase" do
      expect(dispute_evidence.for_subscription_purchase?).to be false
    end

    it "returns true if charge includes a subscription purchase" do
      charge.purchases << create(:membership_purchase)

      expect(dispute_evidence.for_subscription_purchase?).to be true
    end
  end
end
