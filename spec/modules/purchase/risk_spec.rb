# frozen_string_literal: true

require "spec_helper"

describe Purchase::Risk do
  describe "check purchase for previous chargebacks" do
    it "returns errors if the email has charged-back" do
      product = create(:product)
      product_2 = create(:product)
      create(:purchase, link: product, email: "tuhins@gmail.com", chargeback_date: Time.current)
      new_purchase = build(:purchase, link: product_2, email: "tuhins@gmail.com", created_at: Time.current)
      new_purchase.send(:check_for_fraud)
      expect(new_purchase.errors.empty?).to be(false)
      expect(new_purchase.errors.full_messages).to eq ["There's an active chargeback on one of your past Gumroad purchases. Please withdraw it by contacting your charge processor and try again later."]
    end

    it "returns errors if the guid has charged-back" do
      product = create(:product)
      product_2 = create(:product)
      create(:purchase, link: product, browser_guid: "blahbluebleh", chargeback_date: Time.current)
      new_purchase = build(:purchase, link: product_2, browser_guid: "blahbluebleh", created_at: Time.current)
      new_purchase.send(:check_for_fraud)
      expect(new_purchase.errors.empty?).to be(false)
      expect(new_purchase.errors.full_messages).to eq ["There's an active chargeback on one of your past Gumroad purchases. Please withdraw it by contacting your charge processor and try again later."]
    end

    it "returns errors if the email is associated with suspended for fraud creator" do
      product = create(:product)
      create(:user, email: "test@test.test", user_risk_state: "suspended_for_fraud")
      create(:purchase, link: product, email: "test@test.test")
      new_purchase = build(:purchase, link: product, email: "test@test.test")
      new_purchase.send(:check_for_fraud)
      expect(new_purchase.errors.empty?).to be(false)
    end

    it "doesn't return error when buyer user doesn't exist" do
      product = create(:product)
      purchase = build(:purchase, link: product, email: "nonexistent@example.com")
      purchase.send(:check_for_past_fraudulent_buyers)
      expect(purchase.errors).to be_empty
    end

    it "doesn't return error if the chargeback has been won" do
      product = create(:product)
      product_2 = create(:product)
      chargeback_purchase = create(:purchase, link: product, browser_guid: "blahbluebleh", chargeback_date: Time.current)
      chargeback_purchase.chargeback_reversed = true
      chargeback_purchase.save!
      new_purchase = build(:purchase, link: product_2, browser_guid: "blahbluebleh", created_at: Time.current)
      new_purchase.send(:check_for_fraud)
      expect(new_purchase.errors.empty?).to be(true)
    end
  end

  describe "#check_for_fraud" do
    before do
      @user = create(:user, account_created_ip: "123.121.11.1")
      @product = create(:product, user: @user)
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "192.378.12.1", nil, expires_in: 1.hour)
    end

    it "handles timeout and returns nil" do
      purchase = build(:purchase, link: @product)

      allow(purchase).to receive(:check_for_past_blocked_emails).and_raise(Timeout::Error.new("timeout"))
      allow(purchase).to receive(:logger).and_return(double(info: nil))

      result = purchase.send(:check_for_fraud)
      expect(result).to be_nil
    end

    it "returns early when errors are present" do
      purchase = build(:purchase, link: @product, email: "blocked@example.com")
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "blocked@example.com", nil, expires_in: 1.hour)

      expect(purchase).to receive(:check_for_past_blocked_emails).and_call_original
      expect(purchase).not_to receive(:check_for_past_blocked_email_domains)

      purchase.send(:check_for_fraud)
      expect(purchase.errors).not_to be_empty
    end

    it "returns errors if the buyer ip_address has been blocked" do
      good_purchase = build(:purchase, link: @product, ip_address: "128.12.11.11")
      good_purchase.send(:check_for_fraud)
      expect(good_purchase.errors.empty?).to be(true)

      bad_purchase = build(:purchase, link: @product, ip_address: "192.378.12.1")
      bad_purchase.send(:check_for_fraud)
      expect(bad_purchase.errors.empty?).to be(false)
      expect(bad_purchase.errors.full_messages).to eq ["Your card was not charged. Please try again on a different browser and/or internet connection."]
    end

    it "returns errors if the buyer browser_guid has been blocked" do
      browser_guid = "abc123"
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:browser_guid], browser_guid, nil, expires_in: 1.hour)

      bad_purchase = build(:purchase, link: @product, browser_guid:)
      bad_purchase.send(:check_for_fraud)
      expect(bad_purchase.errors.empty?).to be(false)
      expect(bad_purchase.errors.full_messages).to eq ["Your card was not charged. Please try again on a different browser and/or internet connection."]
    end

    it "returns errors if the seller ip_address has been blocked" do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "123.121.11.1", nil, expires_in: 1.hour)
      bad_purchase = build(:purchase, link: @product, seller: @user)
      bad_purchase.send(:check_for_fraud)
      expect(bad_purchase.errors.empty?).to be(false)
    end

    describe "ip_address check" do
      let(:blocked_ip_address) { "192.1.2.3" }

      before do
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], blocked_ip_address, nil, expires_in: 1.hour)
      end

      it "returns error if the purchaser's ip_address has been blocked" do
        purchaser = create(:user, current_sign_in_ip: blocked_ip_address)
        purchase = build(:purchase, purchaser:)

        expect do
          purchase.check_for_fraud
        end.to change { purchase.error_code }
          .from(nil).to(PurchaseErrorCode::BLOCKED_IP_ADDRESS)
          .and change { purchase.errors.empty? }.from(true).to(false)
          .and change { purchase.errors.full_messages }.from([]).to(["Your card was not charged. Please try again on a different browser and/or internet connection."])
      end

      describe "subscription purchase" do
        let(:subscription) { create(:subscription) }

        context "when it is an original subscription purchase" do
          it "returns error if the ip_address is blocked" do
            purchase = build(:membership_purchase, is_original_subscription_purchase: true, ip_address: blocked_ip_address, subscription:)
            purchase.send(:check_for_fraud)
            expect(purchase.errors.empty?).to be(false)
            expect(purchase.errors.full_messages).to eq ["Your card was not charged. Please try again on a different browser and/or internet connection."]
          end
        end

        context "when it is a subscription recurring charge" do
          it "doesn't block the purchase when ip_address is blocked" do
            purchase = build(:membership_purchase, is_original_subscription_purchase: false, ip_address: blocked_ip_address, subscription:)
            purchase.send(:check_for_fraud)
            expect(purchase.errors).to be_empty
            expect(purchase).to be_valid
          end
        end

        context "when it's a free purchase" do
          it "doesn't block the purchase when ip_address is blocked" do
            purchase = build(:free_purchase, ip_address: blocked_ip_address)
            purchase.send(:check_for_fraud)

            expect(purchase.errors).to be_empty
            expect(purchase).to be_valid
          end
        end
      end
    end

    context "when the creator's ip_address has been blocked but the seller is compliant" do
      let(:seller) { @product.user }

      before do
        seller.update!(account_created_ip: "123.121.11.1", user_risk_state: "compliant")
        BlockedObject.block!(BLOCKED_OBJECT_TYPES[:ip_address], "123.121.11.1", nil, expires_in: 1.hour)
      end

      it "doesn't return errors" do
        purchase = build(:purchase, link: @product, seller:)
        purchase.send(:check_for_fraud)
        expect(purchase.errors.empty?).to be(true)
      end
    end

    it "returns errors if the email has an active blockage" do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "edgar_the_baddie@gumroad.com", nil, expires_in: 3.days)
      bad_purchase = build(:purchase, link: @product, seller: @user, email: "edgar_the_baddie@gumroad.com")
      bad_purchase.send(:check_for_fraud)
      expect(bad_purchase.errors.empty?).to be(false)
    end

    describe "#check_for_past_blocked_email_domains" do
      let!(:purchaser) { create(:user) }
      let!(:purchase) { build(:purchase, purchaser:, email: "john@example.com") }

      context "when it is a paid product" do
        vague_purchase_error_notice = "Your card was not charged."

        it "returns error if the specified email domain has been blocked" do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], "example.com", nil)

          expect do
            purchase.check_for_fraud
          end.to change { purchase.error_code }.from(nil).to(PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
           .and change { purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice)
        end

        it "returns error if the purchaser's email domain has been blocked" do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], Mail::Address.new(purchaser.email).domain, nil)

          expect do
            purchase.check_for_fraud
          end.to change { purchase.error_code }.from(nil).to(PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
           .and change { purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice)
        end

        context "when it is a gift purchase" do
          let!(:product) { create(:product, price_cents: 100) }
          let(:gift) { create(:gift, gifter_email: "gifter@gifter.com", giftee_email: "giftee@giftee.com", link: product) }
          let(:gifter_purchase) do build(:purchase, link: product,
                                                    seller: product.user,
                                                    price_cents: product.price_cents,
                                                    email: gift.gifter_email,
                                                    is_gift_sender_purchase: true,
                                                    gift_given: gift,
                                                    purchase_state: "in_progress") end

          let(:giftee_purchase) do build(:purchase, link: product,
                                                    seller: product.user,
                                                    email: gift.giftee_email,
                                                    price_cents: 0,
                                                    is_gift_receiver_purchase: true,
                                                    gift_received: gift,
                                                    purchase_state: "in_progress") end

          before do
            gift.gifter_purchase = gifter_purchase
            gift.giftee_purchase = giftee_purchase
          end

          it "returns error if the gift recipient's email domain has been blocked" do
            BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], "giftee.com", nil)

            expect(giftee_purchase.price_cents).to eq 0
            expect(gifter_purchase.price_cents).to eq 100

            expect do
              giftee_purchase.check_for_fraud
            end.to change { giftee_purchase.error_code }.from(nil).to(PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
             .and change { giftee_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice)
          end

          it "returns error if the gift sender's email domain has been blocked" do
            BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], "gifter.com", nil)

            expect do
              gifter_purchase.check_for_fraud
            end.to change { gifter_purchase.error_code }.from(nil).to(PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
             .and change { gifter_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice)
          end
        end
      end

      context "when it is a free product" do
        let!(:free_purchase) { build(:purchase, purchaser:, email: "john@example.com", price_cents: 0) }

        vague_purchase_error_notice_for_free_products = "The transaction could not complete."

        it "returns error if the specified email domain has been blocked" do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], "example.com", nil)

          expect do
            free_purchase.check_for_fraud
          end.to change { free_purchase.error_code }.from(nil).to(PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
           .and change { free_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice_for_free_products)
        end

        it "returns error if the purchaser's email domain has been blocked" do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], Mail::Address.new(purchaser.email).domain, nil)

          expect do
            free_purchase.check_for_fraud
          end.to change { free_purchase.error_code }.from(nil).to(PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
           .and change { free_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice_for_free_products)
        end

        context "when it is a gift purchase" do
          let!(:product) { create(:product, price_cents: 0) }
          let(:gift) { create(:gift, gifter_email: "gifter@gifter.com", giftee_email: "giftee@giftee.com", link: product) }
          let(:gifter_purchase) do build(:purchase, link: product,
                                                    seller: product.user,
                                                    price_cents: product.price_cents,
                                                    email: gift.gifter_email,
                                                    is_gift_sender_purchase: true,
                                                    gift_given: gift,
                                                    purchase_state: "in_progress") end

          let(:giftee_purchase) do build(:purchase, link: product,
                                                    seller: product.user,
                                                    email: gift.giftee_email,
                                                    price_cents: 0,
                                                    is_gift_receiver_purchase: true,
                                                    gift_received: gift,
                                                    purchase_state: "in_progress") end

          before do
            gift.gifter_purchase = gifter_purchase
            gift.giftee_purchase = giftee_purchase
          end

          it "returns error if the gift recipient's email domain has been blocked" do
            BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], "giftee.com", nil)

            expect(giftee_purchase.price_cents).to eq 0
            expect(gifter_purchase.price_cents).to eq 0

            expect do
              giftee_purchase.check_for_fraud
            end.to change { giftee_purchase.error_code }.from(nil).to(PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
             .and change { giftee_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice_for_free_products)
          end

          it "returns error if the gift sender's email domain has been blocked" do
            BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email_domain], "gifter.com", nil)

            expect do
              gifter_purchase.check_for_fraud
            end.to change { gifter_purchase.error_code }.from(nil).to(PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
             .and change { gifter_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice_for_free_products)
          end
        end
      end

      it "doesn't return an error if neither the purchaser email's domain nor the specified email's domain has been blocked" do
        expect do
          purchase.check_for_fraud
        end.to_not change { purchase.error_code }

        expect(purchase.errors.any?).to be(false)
      end

      context "when purchaser has blank email" do
        let(:purchaser) { create(:user, email: "", provider: "twitter") }

        it "doesn't return an error" do
          expect do
            purchase.check_for_fraud
          end.to_not change { purchase.error_code }

          expect(purchase.errors.any?).to be(false)
        end
      end
    end

    describe "#check_for_past_blocked_emails" do
      let(:purchaser) { create(:user) }
      let(:purchase) { build(:purchase, purchaser:, email: "john@example.com") }

      context "when it is a paid product" do
        vague_purchase_error_notice = "Your card was not charged."

        it "returns error if the specified email has been blocked" do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "john@example.com", nil)

          expect do
            purchase.check_for_fraud
          end.to change { purchase.error_code }.from(nil).to(PurchaseErrorCode::TEMPORARILY_BLOCKED_EMAIL_ADDRESS)
           .and change { purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice)
        end

        it "returns error if the purchaser's email has been blocked" do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], purchaser.email, nil)

          expect do
            purchase.check_for_fraud
          end.to change { purchase.error_code }.from(nil).to(PurchaseErrorCode::TEMPORARILY_BLOCKED_EMAIL_ADDRESS)
           .and change { purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice)
        end

        context "when it is a gift purchase" do
          let!(:product) { create(:product, price_cents: 100) }
          let(:gift) { create(:gift, gifter_email: "gifter@gifter.com", giftee_email: "giftee@giftee.com", link: product) }
          let(:gifter_purchase) do build(:purchase, link: product,
                                                    seller: product.user,
                                                    price_cents: product.price_cents,
                                                    email: gift.gifter_email,
                                                    is_gift_sender_purchase: true,
                                                    gift_given: gift,
                                                    purchase_state: "in_progress") end

          let(:giftee_purchase) do build(:purchase, link: product,
                                                    seller: product.user,
                                                    email: gift.giftee_email,
                                                    price_cents: 0,
                                                    is_gift_receiver_purchase: true,
                                                    gift_received: gift,
                                                    purchase_state: "in_progress") end

          before do
            gift.gifter_purchase = gifter_purchase
            gift.giftee_purchase = giftee_purchase
          end

          it "returns error if the gift recipient's email has been blocked" do
            BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], gift.giftee_email, nil)

            expect(giftee_purchase.price_cents).to eq 0
            expect(gifter_purchase.price_cents).to eq 100

            expect do
              giftee_purchase.check_for_fraud
            end.to change { giftee_purchase.error_code }.from(nil).to(PurchaseErrorCode::TEMPORARILY_BLOCKED_EMAIL_ADDRESS)
             .and change { giftee_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice)
          end

          it "returns error if the gift sender's email has been blocked" do
            BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], gift.gifter_email, nil)

            expect do
              gifter_purchase.check_for_fraud
            end.to change { gifter_purchase.error_code }.from(nil).to(PurchaseErrorCode::TEMPORARILY_BLOCKED_EMAIL_ADDRESS)
             .and change { gifter_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice)
          end
        end
      end

      context "when it is a free product" do
        let(:free_purchase) { build(:purchase, purchaser:, email: "john@example.com", price_cents: 0) }
        vague_purchase_error_notice_for_free_products = "The transaction could not complete."

        it "returns error if the specified email has been blocked" do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "john@example.com", nil)

          expect do
            free_purchase.check_for_fraud
          end.to change { free_purchase.error_code }.from(nil).to(PurchaseErrorCode::TEMPORARILY_BLOCKED_EMAIL_ADDRESS)
           .and change { free_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice_for_free_products)
        end

        it "returns error if the purchaser's email has been blocked" do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], purchaser.email, nil)

          expect do
            free_purchase.check_for_fraud
          end.to change { free_purchase.error_code }.from(nil).to(PurchaseErrorCode::TEMPORARILY_BLOCKED_EMAIL_ADDRESS)
           .and change { free_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice_for_free_products)
        end

        context "when it is a gift purchase" do
          let!(:product) { create(:product, price_cents: 0) }
          let(:gift) { create(:gift, gifter_email: "gifter@gifter.com", giftee_email: "giftee@giftee.com", link: product) }
          let(:gifter_purchase) do build(:purchase, link: product,
                                                    seller: product.user,
                                                    price_cents: product.price_cents,
                                                    email: gift.gifter_email,
                                                    is_gift_sender_purchase: true,
                                                    gift_given: gift,
                                                    purchase_state: "in_progress") end

          let(:giftee_purchase) do build(:purchase, link: product,
                                                    seller: product.user,
                                                    email: gift.giftee_email,
                                                    price_cents: 0,
                                                    is_gift_receiver_purchase: true,
                                                    gift_received: gift,
                                                    purchase_state: "in_progress") end

          before do
            gift.gifter_purchase = gifter_purchase
            gift.giftee_purchase = giftee_purchase
          end

          it "returns error if the gift recipient's email has been blocked" do
            BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], gift.giftee_email, nil)

            expect(giftee_purchase.price_cents).to eq 0
            expect(gifter_purchase.price_cents).to eq 0

            expect do
              giftee_purchase.check_for_fraud
            end.to change { giftee_purchase.error_code }.from(nil).to(PurchaseErrorCode::TEMPORARILY_BLOCKED_EMAIL_ADDRESS)
             .and change { giftee_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice_for_free_products)
          end

          it "returns error if the gift sender's email has been blocked" do
            BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], gift.gifter_email, nil)

            expect do
              gifter_purchase.check_for_fraud
            end.to change { gifter_purchase.error_code }.from(nil).to(PurchaseErrorCode::TEMPORARILY_BLOCKED_EMAIL_ADDRESS)
             .and change { gifter_purchase.errors.full_messages.to_sentence }.from("").to(vague_purchase_error_notice_for_free_products)
          end
        end
      end

      it "doesn't return an error if neither the purchaser's email nor the specified email has been blocked" do
        expect do
          purchase.check_for_fraud
        end.to_not change { purchase.error_code }

        expect(purchase.errors.any?).to be(false)
      end

      context "when purchaser has blank email and there exists a BlockedObject with a blank 'object_value'" do
        let(:purchaser) { create(:user, email: "", provider: "twitter") }

        it "doesn't return an error" do
          BlockedObject.block!(BLOCKED_OBJECT_TYPES[:browser_guid], "", nil)

          expect do
            purchase.check_for_fraud
          end.to_not change { purchase.error_code }

          expect(purchase.errors.any?).to be(false)
        end
      end
    end

    it "doesn't return errors if the email has an inactive blockage" do
      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:email], "edgar_the_baddie@gumroad.com", nil, expires_in: -3.days)
      bad_purchase = build(:purchase, link: @product, seller: @user, email: "edgar_the_baddie@gumroad.com")
      bad_purchase.send(:check_for_fraud)
      expect(bad_purchase.errors.empty?).to be(true)
    end
  end
end
