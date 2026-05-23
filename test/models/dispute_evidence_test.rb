# frozen_string_literal: true

require "test_helper"

class DisputeEvidenceTest < ActiveSupport::TestCase
  self.described_class = DisputeEvidence



  context_ DisputeEvidence do
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

  context_ "stripped_fields" do
  test "strips fields" do
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

  context_ "policy fields" do
      before do
        dispute_evidence.dispute = dispute
        dispute_evidence.policy_disclosure = "Sample policy disclosure"
        dispute_evidence.policy_image.attach(
          Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png")
        )
        dispute_evidence.save!
      end

  context_ "when the product is not membership" do
        let(:dispute) { create(:dispute_formalized) }

  test "it assigns data to refund_policy_* fields" do
          expect(dispute_evidence.refund_policy_disclosure).to eq("Sample policy disclosure")
          expect(dispute_evidence.cancellation_policy_disclosure).to be(nil)

          expect(dispute_evidence.refund_policy_image.attached?).to be(true)
          expect(dispute_evidence.cancellation_policy_image.attached?).to be(false)
        end
      end

  context_ "when the product is membership" do
        let(:dispute) { create(:dispute_formalized, purchase: create(:membership_purchase)) }

  test "it assigns data to cancellation_policy_* fields" do
          expect(dispute_evidence.cancellation_policy_disclosure).to eq("Sample policy disclosure")
          expect(dispute_evidence.refund_policy_disclosure).to be(nil)

          expect(dispute_evidence.cancellation_policy_image.attached?).to be(true)
          expect(dispute_evidence.refund_policy_image.attached?).to be(false)
        end
      end

  context_ "when the product is a legacy subscription" do
        let(:dispute) do
          product = create(:subscription_product)
          subscription = create(:subscription, link: product, created_at: 3.days.ago)
          purchase = create(:purchase, is_original_subscription_purchase: true, link: product, subscription:)
          create(:dispute_formalized, purchase:)
        end

  test "it assigns data to cancellation_policy_* fields" do
          expect(dispute_evidence.cancellation_policy_disclosure).to eq("Sample policy disclosure")
          expect(dispute_evidence.refund_policy_disclosure).to be(nil)

          expect(dispute_evidence.cancellation_policy_image.attached?).to be(true)
          expect(dispute_evidence.refund_policy_image.attached?).to be(false)
        end
      end
    end

  context_ "validations" do
  context_ "customer_communication_file_size and all_files_size_within_limit" do
  context_ "when the file size is too big" do
          before do
            dispute_evidence.customer_communication_file.attach(
              Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "big_file.txt"), "image/jpeg")
            )
          end

  test "returns error" do
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

  context_ "customer_communication_file_type" do
  context_ "when the content type is not allowed" do
          before do
            dispute_evidence.customer_communication_file.attach(
              Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "blah.txt"), "text/plain")
            )
          end

  test "returns error" do
            expect(dispute_evidence.valid?).to eq(false)
            expect(dispute_evidence.errors[:base]).to eq(["Invalid file type."])
          end
        end
      end

  test "validates length of reason_for_winning" do
        dispute_evidence.reason_for_winning = "a" * 3_001
        expect(dispute_evidence.valid?).to eq(false)
        expect(dispute_evidence.errors[:reason_for_winning]).to eq(["is too long (maximum is 3000 characters)"])
      end

  test "validates length of refund_refusal_explanation" do
        dispute_evidence.refund_refusal_explanation = "a" * 3_001
        expect(dispute_evidence.valid?).to eq(false)
        expect(dispute_evidence.errors[:refund_refusal_explanation]).to eq(["is too long (maximum is 3000 characters)"])
      end

  test "validates length of cancellation_rebuttal" do
        dispute_evidence.cancellation_rebuttal = "a" * 3_001
        expect(dispute_evidence.valid?).to eq(false)
        expect(dispute_evidence.errors[:cancellation_rebuttal]).to eq(["is too long (maximum is 3000 characters)"])
      end
    end

  context_ "#hours_left_to_submit_evidence" do
  context_ "when seller hasn't been contacted" do
        before do
          dispute_evidence.update_as_not_seller_contacted!
        end

  test "returns 0" do
          expect(dispute_evidence.hours_left_to_submit_evidence).to eq(0)
        end
      end

  context_ "when seller has been contacted" do
        before do
          dispute_evidence.update!(seller_contacted_at: 3.hours.ago)
        end

  test "returns correct value" do
          expect(dispute_evidence.hours_left_to_submit_evidence).to eq(DisputeEvidence::SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS - 3)
        end
      end
    end

  context_ "#customer_communication_file_max_size" do
      before do
        dispute_evidence.receipt_image.attach(
          Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png")
        )
      end

  test "returns correct value" do
        expect(dispute_evidence.customer_communication_file_max_size < DisputeEvidence::STRIPE_MAX_COMBINED_FILE_SIZE).to be(true)
        expect(dispute_evidence.customer_communication_file_max_size).to eq(
          DisputeEvidence::STRIPE_MAX_COMBINED_FILE_SIZE -
          dispute_evidence.receipt_image.byte_size.to_i
        )
      end
    end

  context_ "#policy_image_max_size" do
      before do
        dispute_evidence.receipt_image.attach(
          Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png")
        )
      end

  test "returns correct value" do
        expect(dispute_evidence.policy_image_max_size < DisputeEvidence::STRIPE_MAX_COMBINED_FILE_SIZE).to be(true)
        expect(dispute_evidence.policy_image_max_size).to eq(
          DisputeEvidence::STRIPE_MAX_COMBINED_FILE_SIZE -
          dispute_evidence.receipt_image.byte_size.to_i -
          DisputeEvidence::MINIMUM_RECOMMENDED_CUSTOMER_COMMUNICATION_FILE_SIZE
        )
      end
    end

  context_ "#for_subscription_purchase?" do
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

  test "returns false if charge does not include any subscription purchase" do
        expect(dispute_evidence.for_subscription_purchase?).to be false
      end

  test "returns true if charge includes a subscription purchase" do
        charge.purchases << create(:membership_purchase)

        expect(dispute_evidence.for_subscription_purchase?).to be true
      end
    end
  end
end
