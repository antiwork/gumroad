# frozen_string_literal: true

require "spec_helper"

describe ChargePreorderWorker, :vcr do
  describe "#perform" do
    before do
      @good_card = build(:chargeable)
      @good_card_but_cant_charge = build(:chargeable_success_charge_decline)
      product = create(:product, price_cents: 600, is_in_preorder_state: false)
      preorder_product = create(:preorder_product_with_content, link: product)
      preorder_product.update_attribute(:release_at, Time.current) # bypass validation
      authorization_purchase = build(:purchase, link: product, chargeable: @good_card, purchase_state: "in_progress",
                                                is_preorder_authorization: true)
      @preorder = preorder_product.build_preorder(authorization_purchase)
    end

    it "charges the preorder and mark it as successful" do
      @preorder.authorize!
      @preorder.mark_authorization_successful!
      described_class.new.perform(@preorder.id)

      expect(@preorder.reload.state).to eq "charge_successful"
      expect(@preorder.authorization_purchase.purchase_state).to eq "preorder_concluded_successfully"

      expect(@preorder.purchases.count).to eq 2
      expect(@preorder.purchases.last.purchase_state).to eq "successful"
    end

    it "raises an error if preorder product is not in chargeable state" do
      @preorder.authorize!
      @preorder.mark_authorization_successful!
      @preorder.link.update!(is_in_preorder_state: true)
      expect do
        described_class.new.perform(@preorder.id)
      end.to raise_error(/Unable to charge preorder #{@preorder.id}/)
    end

    it "retries the charge if the purchase fails with 'processing_error'",
       vcr: { cassette_name: "_manual/should_retry_the_charge_if_the_purchase_fails_with_processing_error_" } do
      # The vcr cassette was manually changed in order to simulate processing_error charge error. This was
      # necessary because stripe doesn't allow customer creation with the processing_error test card.
      @preorder.authorize!
      @preorder.mark_authorization_successful!

      @preorder.credit_card = CreditCard.create(@good_card_but_cant_charge)
      described_class.new.perform(@preorder.id)

      expect(described_class).to have_enqueued_sidekiq_job(@preorder.id, 2)

      expect(@preorder.reload.state).to eq "authorization_successful"
      expect(@preorder.purchases.count).to eq 2
      expect(@preorder.purchases.last.purchase_state).to eq "failed"
      expect(@preorder.purchases.last.stripe_error_code).to eq "processing_error"
    end

    it "retries the charge three times if the purchase fails with 'processing_error'",
       vcr: { cassette_name: "_manual/retries_the_charge_three_times_if_the_purchase_fails_with_processing_error_" } do
      # The vcr cassette was manually changed in order to simulate processing_error charge error. This was
      # necessary because stripe doesn't allow customer creation with the processing_error test card.
      @preorder.authorize!
      @preorder.mark_authorization_successful!

      @preorder.credit_card = CreditCard.create(@good_card_but_cant_charge)
      described_class.new.perform(@preorder.id)

      expect(described_class).to have_enqueued_sidekiq_job(@preorder.id, 2)
      described_class.perform_one # Run the scheduled job

      expect(described_class).to have_enqueued_sidekiq_job(@preorder.id, 3)
      described_class.perform_one

      allow(Rails.logger).to receive(:info)
      expect(described_class).to have_enqueued_sidekiq_job(@preorder.id, 4)
      described_class.perform_one

      expect(Rails.logger).to(have_received(:info)
        .with("ChargePreorder: Gave up charging Preorder #{@preorder.id} after 4 attempts."))
      expect(described_class).to_not have_enqueued_sidekiq_job(@preorder.id, 5)
    end

    it "sends an email to the buyer if the purchase fails with 'card_declined'" do
      @preorder.authorize!
      @preorder.mark_authorization_successful!

      @preorder.credit_card = CreditCard.create(@good_card_but_cant_charge)

      mail_double = double
      allow(mail_double).to receive(:deliver_later)
      expect(CustomerLowPriorityMailer).to receive(:preorder_card_declined).with(@preorder.id).and_return(mail_double)

      described_class.new.perform(@preorder.id)

      expect(@preorder.reload.state).to eq "authorization_successful"
      expect(@preorder.purchases.count).to eq 2
      expect(@preorder.purchases.last.purchase_state).to eq "failed"
      expect(@preorder.purchases.last.stripe_error_code).to eq "card_declined_generic_decline"
    end

    it "schedules CancelPreorderWorker job to cancel the preorder after 2 weeks if purchase fails with 'card_declined' error" do
      @preorder.authorize!
      @preorder.mark_authorization_successful!
      @preorder.credit_card = CreditCard.create(@good_card_but_cant_charge)

      travel_to(Time.current) do
        described_class.new.perform(@preorder.id)

        expect(@preorder.reload.state).to eq "authorization_successful"
        expect(@preorder.purchases.count).to eq 2
        expect(@preorder.purchases.last.purchase_state).to eq "failed"
        expect(@preorder.purchases.last.stripe_error_code).to eq "card_declined_generic_decline"

        job = CancelPreorderWorker.jobs.last
        expect(job["args"][0]).to eq(@preorder.id)
        expect(job["at"]).to eq(2.weeks.from_now.to_f)
      end
    end
  end
end
