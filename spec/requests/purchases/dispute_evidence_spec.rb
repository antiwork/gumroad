# frozen_string_literal: true

require("spec_helper")

describe("Dispute evidence page", type: :system, js: true) do
  let(:dispute) { create(:dispute_formalized, reason: Dispute::REASON_FRAUDULENT) }
  let(:dispute_evidence) { create(:dispute_evidence, dispute:) }
  let(:purchase) { dispute_evidence.disputable.purchase_for_dispute_evidence }
  let(:product) { purchase.link }

  it "renders the page" do
    visit purchase_dispute_evidence_path(purchase.external_id)

    expect(page).to have_text("Submit additional information")
    expect(page).to have_text("Any additional information you can provide in the next 72 hours will help us win on your behalf.")
    expect(page).to have_text("The cardholder claims they did not authorize the purchase.")
    expect(page).to have_text("Why should you win this dispute?")
    expect(page).not_to have_text("Why is the customer not entitled to a refund?")
    expect(page).to have_button("Submit", disabled: true)

    expect(page).to have_selector("[role=listitem] h4", text: "Receipt")
  end

  describe "reason_for_winning field" do
    it "renders filtered options by fraudulent reason" do
      visit purchase_dispute_evidence_path(purchase.external_id)

      within_fieldset("Why should you win this dispute?") do
        expect(page).to have_text("The cardholder withdrew the dispute")
        expect(page).to have_text("The cardholder was refunded")
        expect(page).not_to have_text("The transaction was non-refundable")
        expect(page).not_to have_text("The refund or cancellation request was made after the date allowed by your terms")
        expect(page).not_to have_text("The product received was as advertised")
        expect(page).not_to have_text("The cardholder received a credit or voucher")
        expect(page).not_to have_text("The cardholder received the product or service")
        expect(page).to have_text("The purchase was made by the rightful cardholder")
        expect(page).not_to have_text("The purchase is unique")
        expect(page).not_to have_text("The product, service, event or booking was cancelled or delayed due to a government order (COVID-19)")
        expect(page).to have_text("Other")
      end
    end

    it "requires a value when Other is selected" do
      visit purchase_dispute_evidence_path(purchase.external_id)

      within_fieldset("Why should you win this dispute?") do
        choose("Other")
      end
      expect(page).to have_button("Submit", disabled: true)
      fill_in("Why should you win this dispute?", with: "Sample text.")
      expect(page).to have_button("Submit")
    end

    it "submits the form successfully" do
      visit purchase_dispute_evidence_path(purchase.external_id)

      within_fieldset("Why should you win this dispute?") do
        choose("The cardholder was refunded")
      end
      click_on("Submit")

      expect(page).to have_text("Thank you!")

      dispute_evidence.reload
      expect(dispute_evidence.reason_for_winning).to eq("The cardholder was refunded")
    end
  end

  context "cancellation_rebuttal field" do
    context "when the purchase is not a subscription" do
      it "doesn't render the field" do
        visit purchase_dispute_evidence_path(purchase.external_id)

        expect(page).not_to have_radio_button("The customer did not request cancellation")
      end
    end

    context "when the purchase is a subscription" do
      let(:dispute) do
        create(
          :dispute_formalized,
          purchase: create(:membership_purchase),
          reason: Dispute::REASON_SUBSCRIPTION_CANCELED
        )
      end

      context "when the dispute reason is subscription_canceled" do
        it "renders the field" do
          visit purchase_dispute_evidence_path(purchase.external_id)

          expect(page).to have_radio_button("The customer did not request cancellation")
        end

        it "requires a value when Other is selected" do
          visit purchase_dispute_evidence_path(purchase.external_id)

          within_fieldset("Why was the customer's subscription not canceled?") do
            choose("Other")
          end
          expect(page).to have_button("Submit", disabled: true)
          fill_in("Why was the customer's subscription not canceled?", with: "Sample text.")
          expect(page).to have_button("Submit")
        end

        it "submits the form successfully" do
          visit purchase_dispute_evidence_path(purchase.external_id)

          within_fieldset("Why was the customer's subscription not canceled?") do
            choose("Other")
          end
          fill_in("Why was the customer's subscription not canceled?", with: "Cancellation rebuttal")
          click_on("Submit")

          expect(page).to have_text("Thank you!")

          dispute_evidence.reload
          expect(dispute_evidence.cancellation_rebuttal).to eq("Cancellation rebuttal")
        end
      end

      context "when the dispute reason is not subscription_canceled" do
        before do
          dispute.update!(reason: Dispute::REASON_FRAUDULENT)
        end

        it "doesn't render the field" do
          visit purchase_dispute_evidence_path(purchase.external_id)

          expect(page).not_to have_radio_button("The customer did not request cancellation")
        end
      end
    end
  end

  describe "refund_refusal_explanation field" do
    [Dispute::REASON_CREDIT_NOT_PROCESSED, Dispute::REASON_GENERAL].each do |reason|
      context "when the dispute reason is #{reason}" do
        let(:dispute) { create(:dispute_formalized, reason:) }

        it "renders the field" do
          visit purchase_dispute_evidence_path(purchase.external_id)

          fill_in("Why is the customer not entitled to a refund?", with: "Refund refusal explanation")
          click_on("Submit")

          expect(page).to have_text("Thank you!")

          dispute_evidence.reload
          expect(dispute_evidence.refund_refusal_explanation).to eq("Refund refusal explanation")
        end
      end
    end
  end

  describe "customer_communication_file field" do
    it "submits the form successfully" do
      # Purging in test ENV returns Aws::S3::Errors::AccessDenied
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
      visit purchase_dispute_evidence_path(purchase.external_id)

      page.attach_file(file_fixture("smilie.png")) do
        click_on "Upload customer communication"
      end
      wait_for_ajax
      # For some reason, the signed_id is not passed to the server until we wait for a few seconds (wait_for_ajax is not enough)
      sleep(3)
      click_on("Submit")

      expect(page).to have_text("Thank you!")

      dispute_evidence.reload
      expect(dispute_evidence.customer_communication_file.attached?).to be(true)
    end

    it "allows the user to delete uploaded file" do
      visit purchase_dispute_evidence_path(purchase.external_id)

      page.attach_file(file_fixture("smilie.png")) do
        click_on "Upload customer communication"
      end
      wait_for_ajax
      expect(page).to have_selector("[role=listitem] h4", text: "Customer communication")
      expect(page).to have_button("Submit")

      click_on("Remove")
      wait_for_ajax
      expect(page).to have_button("Upload customer communication")
      expect(page).to have_button("Submit", disabled: true)
    end
  end
end
