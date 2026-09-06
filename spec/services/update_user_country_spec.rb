# frozen_string_literal: true

require "spec_helper"

describe UpdateUserCountry do
  before do
    @user = create(:named_user)
    create(:ach_account_stripe_succeed, user: @user)
    create(:ach_account, user: @user)
    create(:user_compliance_info, user: @user)
    create(:merchant_account, user: @user, charge_processor_id: StripeChargeProcessor.charge_processor_id)
  end

  describe "#process" do
    UpdateUserCountry::PAYOUT_IN_FLIGHT_STATES.each do |in_flight_state|
      context "when the user has a payout still in the #{in_flight_state} state" do
        before do
          create(:payment, user: @user, state: in_flight_state)
        end

        it "raises PayoutInProcessingError and changes nothing" do
          old_compliance_info = @user.alive_user_compliance_info
          old_stripe_account = @user.stripe_account
          old_bank_account = @user.active_bank_account

          expect do
            UpdateUserCountry.new(new_country_code: "GB", user: @user).process
          end.to raise_error(UpdateUserCountry::PayoutInProcessingError)

          expect(old_compliance_info.reload.deleted?).to eq(false)
          expect(old_stripe_account.reload.deleted?).to eq(false)
          expect(old_bank_account.reload.deleted?).to eq(false)
        end
      end
    end

    context "when the user's payouts have all settled" do
      before do
        create(:payment_completed, user: @user)
        create(:payment_failed, user: @user)
      end

      it "allows the country change" do
        UpdateUserCountry.new(new_country_code: "GB", user: @user).process

        expect(@user.alive_user_compliance_info.legal_entity_country_code).to eq("GB")
      end
    end

    it "deletes the old compliance info and creates a new one" do
      old_compliance_info = @user.alive_user_compliance_info
      UpdateUserCountry.new(new_country_code: "GB", user: @user).process

      expect(old_compliance_info.reload.deleted?).to eq(true)
    end

    it "deletes the old stripe account" do
      old_stripe_account = @user.stripe_account
      UpdateUserCountry.new(new_country_code: "GB", user: @user).process

      expect(old_stripe_account.reload.deleted?).to eq(true)
    end

    it "marks all pending compliance info requests as provided" do
      create(:user_compliance_info_request, user: @user, field_needed: UserComplianceInfoFields::Individual::TAX_ID)
      create(:user_compliance_info_request, user: @user, field_needed: UserComplianceInfoFields::Individual::STRIPE_IDENTITY_DOCUMENT_ID)
      create(:user_compliance_info_request, user: @user, field_needed: UserComplianceInfoFields::Business::STRIPE_COMPANY_DOCUMENT_ID)

      expect(@user.user_compliance_info_requests.provided.count).to eq(0)
      expect(@user.user_compliance_info_requests.requested.count).to eq(3)

      UpdateUserCountry.new(new_country_code: "GB", user: @user).process

      expect(@user.user_compliance_info_requests.provided.count).to eq(3)
      expect(@user.user_compliance_info_requests.requested.count).to eq(0)
    end

    it "deletes the old bank account" do
      old_bank_account = @user.active_bank_account
      UpdateUserCountry.new(new_country_code: "GB", user: @user).process

      expect(old_bank_account.reload.deleted?).to eq(true)
    end

    it "removes products from recommendable search results after deleting the seller's only payout method", :elasticsearch_wait_for_refresh do
      seller = create(:compliant_user, name: "Country change seller")
      product = create(:product, user: seller, taxonomy: create(:taxonomy))
      create(:merchant_account, user: nil)
      create(:purchase, link: product, seller: seller, price_cents: product.price_cents)
      create(:user_compliance_info, user: seller)
      create(:canadian_bank_account, user: seller)
      seller.update!(payment_address: nil)
      index_model_records(Link)

      recommendable_product_ids = -> {
        Link.search(Link.search_options(ids: [product.id], include_rated_as_adult: true)).records.map(&:id)
      }
      expect(product.reload.recommendable?).to eq(true)
      expect(recommendable_product_ids.call).to eq([product.id])

      UpdateUserCountry.new(new_country_code: "GB", user: seller).process
      RefreshUserProductsRecommendationEligibilityJob.drain
      Link.__elasticsearch__.refresh_index!

      expect(product.reload.recommendable?).to eq(false)
      expect(EsClient.get(index: Link.index_name, id: product.id).dig("_source", "is_recommendable")).to eq(false)
      expect(recommendable_product_ids.call).to be_empty
    end

    it "adds country changed comment" do
      UpdateUserCountry.new(new_country_code: "GB", user: @user).process

      comment = @user.reload.comments.last
      expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_COUNTRY_CHANGED)
      expect(comment.content).to eq("Country changed from US to GB")
    end

    context "when old and new country are not Stripe-supported countries" do
      it "retains PayPal payment address" do
        payment_address = @user.payment_address
        allow(@user).to receive(:native_payouts_supported?).and_return(false)

        UpdateUserCountry.new(new_country_code: "GB", user: @user).process

        expect(@user.reload.payment_address).to eq(payment_address)
      end
    end

    it "clears the record of an invalidated PayPal payout address along with the address" do
      @user.invalidated_paypal_payout_address = "refused@example.com"
      @user.save!(validate: false)

      UpdateUserCountry.new(new_country_code: "GB", user: @user).process

      expect(@user.reload.invalidated_paypal_payout_address).to be_nil
      expect(@user.payment_address).to eq("")
    end

    context "when changing from Japan with invalid kana data" do
      before do
        @user.alive_user_compliance_info.mark_deleted(validate: false)
        jp_compliance = @user.user_compliance_infos.build(
          country: "Japan",
          first_name: "Taro",
          last_name: "Yamada",
          street_address: "address_full_match",
          city: "Tokyo",
          state: "Tokyo",
          zip_code: "1000001"
        )
        jp_compliance.street_address_kana = "123 Main St"
        jp_compliance.save!(validate: false)
        @user.reload
      end

      it "soft-deletes old compliance info without raising validation errors" do
        old_compliance_info = @user.alive_user_compliance_info
        expect(old_compliance_info.country).to eq("Japan")

        expect do
          UpdateUserCountry.new(new_country_code: "GB", user: @user).process
        end.not_to raise_error

        expect(old_compliance_info.reload.deleted?).to eq(true)
      end
    end

    context "when user has balance" do
      before do
        stub_const("GUMROAD_ADMIN_ID", create(:admin_user).id) # For negative credits
        @merchant_account = create(:merchant_account, user: @user)
        create(:balance, merchant_account: @merchant_account, user: @user, amount_cents: 1000, state: "unpaid")
      end

      it "marks balances as forfeited" do
        UpdateUserCountry.new(new_country_code: "GB", user: @user).process

        expect(@user.reload.balances.last.state).to eq("forfeited")
        expect(@user.reload.balances.last.merchant_account).to eq(@merchant_account)
      end

      it "adds comment on the user" do
        UpdateUserCountry.new(new_country_code: "GB", user: @user).process

        comment = @user.reload.comments.last
        expect(comment.comment_type).to eq(Comment::COMMENT_TYPE_BALANCE_FORFEITED)
        expect(comment.content).to eq("Balance of $10 has been forfeited. Reason: Country changed. Balance IDs: #{Balance.last.id}")
      end
    end
  end
end
