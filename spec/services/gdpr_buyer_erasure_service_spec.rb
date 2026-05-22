# frozen_string_literal: true

require "spec_helper"

describe GdprBuyerErasureService do
  let(:admin) { create(:user, is_team_member: true) }
  let(:buyer_email) { "guest-buyer@example.com" }

  describe "#perform!" do
    it "raises when email is blank" do
      expect { described_class.new("", performed_by: admin).perform! }.to raise_error(ArgumentError, /Email is required/)
    end

    it "raises when email belongs to an active registered user" do
      create(:user, email: "registered@example.com")
      expect { described_class.new("registered@example.com", performed_by: admin).perform! }.to raise_error(ArgumentError, /Use GdprDataErasureService/)
    end

    it "raises when email belongs to a soft-deleted registered user" do
      create(:user, email: "deleted-user@example.com", deleted_at: Time.current)
      expect { described_class.new("deleted-user@example.com", performed_by: admin).perform! }.to raise_error(ArgumentError, /Use GdprDataErasureService/)
    end

    it "does not log validation failures as erasure failures" do
      expect(Rails.logger).not_to receive(:error).with(/GDPR buyer erasure failed/)
      expect { described_class.new("", performed_by: admin).perform! }.to raise_error(ArgumentError)
    end

    it "raises when any purchase under this email belongs to a registered user" do
      registered_buyer = create(:user)
      purchase = create(:free_purchase, email: "mixed-owner@example.com", purchaser: nil)
      purchase.update_columns(purchaser_id: registered_buyer.id)
      expect { described_class.new("mixed-owner@example.com", performed_by: admin).perform! }
        .to raise_error(ArgumentError, /belonging to registered users/)
      expect(purchase.reload.email).to eq("mixed-owner@example.com")
    end

    context "with guest buyer data" do
      let!(:purchase1) do
        create(:free_purchase, email: buyer_email, purchaser: nil).tap do |p|
          p.update_columns(
            full_name: "Jane Doe",
            ip_address: "1.2.3.4",
            street_address: "123 Main St",
            city: "NYC",
            state: "NY",
            zip_code: "10001",
            country: "US",
            stripe_fingerprint: "fp_123",
            card_visual: "**** 4242",
            card_bin: "424242",
            browser_guid: "guid-1",
            custom_fields: '{"phone": "555-1234"}',
          )
        end
      end
      let!(:purchase2) do
        create(:free_purchase, email: buyer_email, purchaser: nil).tap do |p|
          p.update_columns(full_name: "Jane Doe", ip_address: "1.2.3.5", browser_guid: "guid-2")
        end
      end
      let!(:unrelated_purchase) { create(:free_purchase, email: "other@example.com", purchaser: nil) }

      it "anonymizes all purchases matching the email" do
        result = described_class.new(buyer_email, performed_by: admin).perform!

        expect(result[:success]).to be(true)
        expect(result[:counts][:purchases]).to eq(2)

        purchase1.reload
        expect(purchase1.email).to end_with("@deleted.gumroad.com")
        expect(purchase1.full_name).to eq("[deleted]")
        expect(purchase1.ip_address).to be_nil
        expect(purchase1.street_address).to be_nil
        expect(purchase1.city).to be_nil
        expect(purchase1.stripe_fingerprint).to be_nil
        expect(purchase1.card_visual).to be_nil
        expect(purchase1.card_bin).to be_nil
        expect(purchase1.custom_fields).to be_blank

        unrelated_purchase.reload
        expect(unrelated_purchase.email).to eq("other@example.com")
      end

      it "anonymizes followers by email" do
        follower = Follower.create!(email: buyer_email, user: purchase1.seller)

        described_class.new(buyer_email, performed_by: admin).perform!

        follower.reload
        expect(follower.email).to end_with("@deleted.gumroad.com")
      end

      it "anonymizes carts by email" do
        cart = Cart.create!(email: buyer_email, ip_address: "5.6.7.8", browser_guid: "abc123", user: purchase1.seller)

        described_class.new(buyer_email, performed_by: admin).perform!

        cart.reload
        expect(cart.email).to end_with("@deleted.gumroad.com")
        expect(cart.ip_address).to be_nil
        expect(cart.browser_guid).to be_nil
      end

      it "logs erasure on affected sellers" do
        described_class.new(buyer_email, performed_by: admin).perform!

        seller = purchase1.seller.reload
        comment = seller.comments.last
        expect(comment.content).to include("GDPR buyer erasure")
        expect(comment.author_id).to eq(admin.id)
      end

      it "generates a deterministic anonymized email" do
        result = described_class.new(buyer_email, performed_by: admin).perform!

        expect(result[:anonymized_to]).to start_with("buyer-")
        expect(result[:anonymized_to]).to end_with("@deleted.gumroad.com")
      end

      it "does not touch purchases with different emails" do
        described_class.new(buyer_email, performed_by: admin).perform!

        unrelated_purchase.reload
        expect(unrelated_purchase.full_name).not_to eq("[deleted]")
      end

      it "completes the erasure even if logging fails" do
        allow(User).to receive(:find_by).and_call_original
        allow(User).to receive(:find_by).with(id: purchase1.seller_id).and_raise(StandardError, "log failure")

        expect { described_class.new(buyer_email, performed_by: admin).perform! }.not_to raise_error

        purchase1.reload
        expect(purchase1.email).to end_with("@deleted.gumroad.com")
        expect(purchase1.full_name).to eq("[deleted]")
      end

      it "continues logging on other sellers when one seller's comment fails" do
        other_purchase = create(:free_purchase, email: buyer_email, purchaser: nil)
        seller_a = purchase1.seller
        seller_b = other_purchase.seller

        allow(User).to receive(:find_by).and_call_original
        allow(User).to receive(:find_by).with(id: seller_a.id).and_raise(StandardError, "boom")

        described_class.new(buyer_email, performed_by: admin).perform!

        expect(seller_b.reload.comments.where("content LIKE ?", "%GDPR buyer erasure%")).to exist
      end

      it "anonymizes email-type blocked_customer_objects" do
        seller = purchase1.seller
        block = BlockedCustomerObject.create!(
          seller: seller,
          object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email],
          object_value: buyer_email,
          blocked_at: Time.current
        )

        described_class.new(buyer_email, performed_by: admin).perform!

        expect(block.reload.object_value).to end_with("@deleted.gumroad.com")
      end

      it "anonymizes fingerprint-type blocked_customer_objects via buyer_email" do
        seller = purchase1.seller
        block = BlockedCustomerObject.create!(
          seller: seller,
          object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:charge_processor_fingerprint],
          object_value: "fp_xyz",
          buyer_email: buyer_email,
          blocked_at: Time.current
        )

        described_class.new(buyer_email, performed_by: admin).perform!

        expect(block.reload.buyer_email).to end_with("@deleted.gumroad.com")
        expect(block.object_value).to eq("fp_xyz")
      end

      it "merges duplicate email-type blocked_customer_objects when an anonymized row already exists" do
        seller = purchase1.seller
        anonymized = described_class.new(buyer_email, performed_by: admin).send(:generate_anonymized_email)
        existing_anonymized = BlockedCustomerObject.create!(
          seller: seller,
          object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email],
          object_value: anonymized,
          blocked_at: Time.current
        )
        fresh = BlockedCustomerObject.create!(
          seller: seller,
          object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email],
          object_value: buyer_email,
          blocked_at: Time.current
        )

        expect { described_class.new(buyer_email, performed_by: admin).perform! }.not_to raise_error
        expect(BlockedCustomerObject.where(id: existing_anonymized.id)).to exist
        expect(BlockedCustomerObject.where(id: fresh.id)).not_to exist
      end

      it "does not anonymize discover_searches whose browser_guid is also used by another buyer's purchase" do
        shared_guid = "shared-guid-#{SecureRandom.hex(4)}"
        purchase1.update_columns(browser_guid: shared_guid)
        other_buyer_purchase = create(:free_purchase, email: "other-guest@example.com", purchaser: nil)
        other_buyer_purchase.update_columns(browser_guid: shared_guid)
        search = DiscoverSearch.create!(browser_guid: shared_guid, ip_address: "9.9.9.9")

        described_class.new(buyer_email, performed_by: admin).perform!

        search.reload
        expect(search.browser_guid).to eq(shared_guid)
        expect(search.ip_address).to eq("9.9.9.9")
      end

      describe "charges with shared purchases across buyers" do
        let!(:other_buyer_purchase) { create(:free_purchase, email: "other@example.com", purchaser: nil) }

        it "nullifies fingerprint on charges whose purchases are all owned by the erased buyer" do
          charge = create(:charge, payment_method_fingerprint: "fp_exclusive")
          ChargePurchase.create!(charge: charge, purchase: purchase1)
          ChargePurchase.create!(charge: charge, purchase: purchase2)

          described_class.new(buyer_email, performed_by: admin).perform!

          expect(charge.reload.payment_method_fingerprint).to be_nil
        end

        it "leaves fingerprint untouched on charges shared with another buyer's purchase" do
          shared_charge = create(:charge, payment_method_fingerprint: "fp_shared")
          ChargePurchase.create!(charge: shared_charge, purchase: purchase1)
          ChargePurchase.create!(charge: shared_charge, purchase: other_buyer_purchase)

          described_class.new(buyer_email, performed_by: admin).perform!

          expect(shared_charge.reload.payment_method_fingerprint).to eq("fp_shared")
        end
      end

      describe "second erasure after a fresh purchase under the same email" do
        it "merges duplicate audience_members without violating the unique index" do
          seller = purchase1.seller
          anonymized = described_class.new(buyer_email, performed_by: admin).send(:generate_anonymized_email)
          AudienceMember.where(seller: seller, email: [buyer_email, anonymized]).delete_all
          existing_anonymized = AudienceMember.new(seller: seller, email: anonymized, details: { purchases: [{ id: 1 }] })
          existing_anonymized.save!(validate: false)
          fresh = AudienceMember.new(seller: seller, email: buyer_email, details: { purchases: [{ id: 2 }] })
          fresh.save!(validate: false)

          expect { described_class.new(buyer_email, performed_by: admin).perform! }.not_to raise_error
          expect(AudienceMember.where(seller: seller, email: buyer_email).count).to eq(0)
          expect(AudienceMember.where(id: existing_anonymized.id)).to exist
          expect(AudienceMember.where(id: fresh.id)).not_to exist
        end
      end

      describe "credit cards" do
        it "anonymizes guest credit cards but leaves user-owned cards untouched" do
          guest_card = CreditCard.new(visual: "**** 1111", card_type: "visa", stripe_fingerprint: "fp_guest")
          guest_card.save!(validate: false)
          owned_card = CreditCard.new(visual: "**** 2222", card_type: "visa", stripe_fingerprint: "fp_owned")
          owned_card.save!(validate: false)
          User.find(create(:user).id).update_columns(credit_card_id: owned_card.id)

          purchase1.update_columns(credit_card_id: guest_card.id)
          purchase2.update_columns(credit_card_id: owned_card.id)

          described_class.new(buyer_email, performed_by: admin).perform!

          expect(guest_card.reload.visual).to eq("[redacted]")
          expect(owned_card.reload.visual).to eq("**** 2222")
        end

        it "does not anonymize a credit card also used by another buyer's purchase" do
          shared_card = CreditCard.new(visual: "**** 9999", card_type: "visa", stripe_fingerprint: "fp_shared")
          shared_card.save!(validate: false)

          purchase1.update_columns(credit_card_id: shared_card.id)
          other_buyer_purchase = create(:free_purchase, email: "other-guest@example.com", purchaser: nil)
          other_buyer_purchase.update_columns(credit_card_id: shared_card.id)

          described_class.new(buyer_email, performed_by: admin).perform!

          expect(shared_card.reload.visual).to eq("**** 9999")
        end
      end
    end
  end
end
