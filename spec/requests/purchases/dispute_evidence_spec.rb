# frozen_string_literal: true

require("spec_helper")

describe("Dispute evidence page", type: :system, js: true) do
  let(:dispute) { create(:dispute_formalized, reason: Dispute::REASON_FRAUDULENT) }
  let(:dispute_evidence) { create(:dispute_evidence, dispute:) }
  let(:purchase) { dispute_evidence.disputable.purchase_for_dispute_evidence }
  let(:product) { purchase.link }
  let(:evidence_token) do
    purchase.secure_external_id(
      scope: Purchases::DisputeEvidenceController::SECURE_ID_SCOPE,
      expires_at: dispute_evidence.seller_response_due_at
    )
  end

  # gp#1921: login is now required outright, so system specs must sign in as the seller-owner
  # to reach a page that used to be reachable via the token alone.
  before do
    login_as(purchase.seller)
  end

  # Saving no longer forwards to Stripe — we hold the response until the deadline — but the
  # confirmation modal stays, because after the deadline nothing more can be added.
  def submit_and_confirm
    click_on("Save response")
    within_modal "Save your response?" do
      click_on("Confirm and save")
    end
  end

  it "renders the page" do
    visit purchase_dispute_evidence_path(evidence_token)

    expect(page).to have_text("Submit additional information")
    expect(page).to have_text(/Any additional information you can provide by .+ \(72 hours left\) will help us win on your behalf\./)
    expect(page).to have_text("The cardholder claims they did not authorize the purchase.")
    expect(page).to have_text("Why should you win this dispute?")
    expect(page).not_to have_text("Why is the customer not entitled to a refund?")
    expect(page).to have_button("Save response", disabled: true)

    expect(page).to have_selector("[role=listitem] h4", text: "Receipt")
  end

  describe "reason_for_winning field" do
    it "renders filtered options by fraudulent reason" do
      visit purchase_dispute_evidence_path(evidence_token)

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
      visit purchase_dispute_evidence_path(evidence_token)

      within_fieldset("Why should you win this dispute?") do
        choose("Other")
      end
      expect(page).to have_button("Save response", disabled: true)
      fill_in("Why should you win this dispute?", with: "Sample text.")
      expect(page).to have_button("Save response")
    end

    it "submits the form successfully" do
      visit purchase_dispute_evidence_path(evidence_token)

      within_fieldset("Why should you win this dispute?") do
        choose("The cardholder was refunded")
      end
      submit_and_confirm

      expect(page).to have_text("Thank you!")

      dispute_evidence.reload
      expect(dispute_evidence.reason_for_winning).to eq("The cardholder was refunded")
    end
  end

  context "cancellation_rebuttal field" do
    context "when the purchase is not a subscription" do
      it "doesn't render the field" do
        visit purchase_dispute_evidence_path(evidence_token)

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
          visit purchase_dispute_evidence_path(evidence_token)

          expect(page).to have_radio_button("The customer did not request cancellation")
        end

        it "requires a value when Other is selected" do
          visit purchase_dispute_evidence_path(evidence_token)

          within_fieldset("Why was the customer's subscription not canceled?") do
            choose("Other")
          end
          expect(page).to have_button("Save response", disabled: true)
          fill_in("Why was the customer's subscription not canceled?", with: "Sample text.")
          expect(page).to have_button("Save response")
        end

        it "submits the form successfully" do
          visit purchase_dispute_evidence_path(evidence_token)

          within_fieldset("Why was the customer's subscription not canceled?") do
            choose("Other")
          end
          fill_in("Why was the customer's subscription not canceled?", with: "Cancellation rebuttal")
          submit_and_confirm

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
          visit purchase_dispute_evidence_path(evidence_token)

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
          visit purchase_dispute_evidence_path(evidence_token)

          fill_in("Why is the customer not entitled to a refund?", with: "Refund refusal explanation")
          submit_and_confirm

          expect(page).to have_text("Thank you!")

          dispute_evidence.reload
          expect(dispute_evidence.refund_refusal_explanation).to eq("Refund refusal explanation")
        end
      end
    end
  end

  describe "validation errors" do
    it "shows validation error message when submission fails" do
      visit purchase_dispute_evidence_path(evidence_token)

      within_fieldset("Why should you win this dispute?") do
        choose("Other")
      end

      page.execute_script("document.querySelector('textarea').removeAttribute('maxLength')")

      fill_in("Why should you win this dispute?", with: "a" * 3001)
      submit_and_confirm

      expect(page).to have_alert(text: "Reason for winning is too long")
    end
  end

  describe "customer_communication_file field" do
    it "submits the form successfully" do
      # Purging in test ENV returns Aws::S3::Errors::AccessDenied
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
      visit purchase_dispute_evidence_path(evidence_token)

      page.attach_file(file_fixture("smilie.png")) do
        click_on "Upload customer communication"
      end
      wait_for_ajax
      # For some reason, the signed_id is not passed to the server until we wait for a few seconds (wait_for_ajax is not enough)
      sleep(3)
      submit_and_confirm

      expect(page).to have_text("Thank you!")

      dispute_evidence.reload
      expect(dispute_evidence.customer_communication_file.attached?).to be(true)
    end

    it "merges multiple files into a single PDF, preserving the upload order" do
      # Purging in test ENV returns Aws::S3::Errors::AccessDenied
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_return(nil)
      visit purchase_dispute_evidence_path(evidence_token)

      page.attach_file([file_fixture("smilie.png"), file_fixture("test.pdf")]) do
        click_on "Upload customer communication"
      end
      wait_for_ajax
      expect(page).to have_selector("[role=listitem] h4", text: "1. smilie.png")
      expect(page).to have_selector("[role=listitem] h4", text: "2. test.pdf")
      # For some reason, the signed_id is not passed to the server until we wait for a few seconds (wait_for_ajax is not enough)
      sleep(3)
      submit_and_confirm

      expect(page).to have_text("Thank you!")

      dispute_evidence.reload
      expect(dispute_evidence.customer_communication_file.attached?).to be(true)
      expect(dispute_evidence.customer_communication_file.content_type).to eq("application/pdf")
      pages = PDF::Reader.new(StringIO.new(dispute_evidence.customer_communication_file.download)).pages
      expect(pages.size).to eq(2)
      # The image page is sized to the source image (smilie.png is 1006x1006), which proves
      # it comes before the carried-through PDF page.
      first_page_media_box = pages.first.attributes[:MediaBox]
      expect((first_page_media_box[2] - first_page_media_box[0]).round).to eq(1006)
    end

    it "allows the user to delete an uploaded file" do
      visit purchase_dispute_evidence_path(evidence_token)

      page.attach_file(file_fixture("smilie.png")) do
        click_on "Upload customer communication"
      end
      wait_for_ajax
      expect(page).to have_selector("[role=listitem] h4", text: "smilie.png")
      expect(page).to have_button("Save response")

      click_on("Remove")
      wait_for_ajax
      expect(page).to have_button("Upload customer communication")
      expect(page).to have_button("Save response", disabled: true)
    end
  end

  describe "submit confirmation" do
    it "says the response is held until the deadline and does not save when the seller cancels" do
      visit purchase_dispute_evidence_path(evidence_token)

      expect(page).to have_text("You can keep adding to this until the deadline.")

      within_fieldset("Why should you win this dispute?") do
        choose("The cardholder was refunded")
      end
      click_on("Save response")

      within_modal "Save your response?" do
        expect(page).to have_text("We send this to our payment processor at the deadline, not now")
        click_on("Cancel")
      end

      expect(page).not_to have_text("Thank you!")
      expect(dispute_evidence.reload.seller_submitted?).to be(false)
    end
  end
end
