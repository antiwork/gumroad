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

    it "does not log the original buyer email in plaintext when the erasure fails" do
      buyer_email = "leak-check@example.com"
      create(:free_purchase, email: buyer_email, purchaser: nil)
      allow(Purchase).to receive(:where).and_call_original
      allow_any_instance_of(ActiveRecord::Relation).to receive(:update_all).and_raise(StandardError, "boom")
      logged = []
      allow(Rails.logger).to receive(:error) { |msg| logged << msg }

      expect { described_class.new(buyer_email, performed_by: admin).perform! }.to raise_error(StandardError)

      expect(logged.join("\n")).not_to include(buyer_email)
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

      def build_event(attrs)
        Event.new({
          ip_address: "9.9.9.9",
          ip_country: "US",
          ip_state: "NY",
          billing_zip: "11111",
          card_type: "visa",
          card_visual: "**** 4242",
          fingerprint: "fp_event",
          browser_fingerprint: "bfp_event",
          browser_plugins: "Flash, Java",
          browser_guid: "guid_event",
          event_name: "purchase",
        }.merge(attrs)).tap { _1.save!(validate: false) }
      end

      it "anonymizes all PII columns on events tied to the buyer's purchases" do
        event = build_event(purchase_id: purchase1.id, email: buyer_email)

        described_class.new(buyer_email, performed_by: admin).perform!

        event.reload
        expect(event.email).to be_nil
        expect(event.ip_address).to be_nil
        expect(event.ip_country).to be_nil
        expect(event.ip_state).to be_nil
        expect(event.billing_zip).to be_nil
        expect(event.card_type).to be_nil
        expect(event.card_visual).to be_nil
        expect(event.fingerprint).to be_nil
        expect(event.browser_fingerprint).to be_nil
        expect(event.browser_plugins).to be_nil
        expect(event.browser_guid).to be_nil
      end

      it "anonymizes events located by purchase even when the email column is empty" do
        event = build_event(purchase_id: purchase2.id, email: nil)

        described_class.new(buyer_email, performed_by: admin).perform!

        event.reload
        expect(event.ip_address).to be_nil
        expect(event.browser_guid).to be_nil
      end

      it "leaves events tied to unrelated purchases untouched" do
        event = build_event(purchase_id: unrelated_purchase.id, email: "other@example.com")

        described_class.new(buyer_email, performed_by: admin).perform!

        event.reload
        expect(event.ip_address).to eq("9.9.9.9")
        expect(event.browser_guid).to eq("guid_event")
      end

      it "anonymizes events on a re-run after the events step was skipped, even though purchases were already anonymized" do
        event = build_event(purchase_id: purchase1.id, email: buyer_email)

        first_run = described_class.new(buyer_email, performed_by: admin)
        allow(first_run).to receive(:anonymize_events!).and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
        first_result = first_run.perform!

        expect(first_result[:skipped]).to include(:events)
        expect(purchase1.reload.email).to end_with("@deleted.gumroad.com")
        expect(event.reload.ip_address).to eq("9.9.9.9")

        second_result = described_class.new(buyer_email, performed_by: admin).perform!

        expect(second_result[:skipped]).to be_empty
        expect(second_result[:counts][:events]).to eq(1)
        expect(event.reload.ip_address).to be_nil
        expect(event.browser_guid).to be_nil
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

      it "uses HMAC keyed on secret_key_base, not a plain truncated SHA256 of the email" do
        service = described_class.new(buyer_email, performed_by: admin)
        anonymized = service.send(:generate_anonymized_email)
        plain_sha_truncated = Digest::SHA256.hexdigest(buyer_email)[0..11]
        expect(anonymized).not_to include(plain_sha_truncated)
        expect(anonymized).to include(OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, buyer_email)[0..15])
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

      it "swallows unexpected log_erasure! failures so a logging hiccup is not reported as a failed erasure" do
        service = described_class.new(buyer_email, performed_by: admin)
        service.instance_variable_set(:@anonymized_email, "buyer-test@deleted.gumroad.com")
        service.instance_variable_set(:@seller_ids, nil)

        expect { service.send(:log_erasure!) }.not_to raise_error
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

      it "anonymizes buyer_email on email-type blocked_customer_objects that have it populated" do
        seller = purchase1.seller
        block = BlockedCustomerObject.new(
          seller: seller,
          object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email],
          object_value: buyer_email,
          buyer_email: buyer_email,
          blocked_at: Time.current
        )
        block.save!(validate: false)

        described_class.new(buyer_email, performed_by: admin).perform!

        block.reload
        expect(block.object_value).to end_with("@deleted.gumroad.com")
        expect(block.buyer_email).to end_with("@deleted.gumroad.com")
      end

      it "does not count email-type blocked_customer_objects under the fingerprint scope" do
        seller = purchase1.seller
        # An email-type row that happens to have buyer_email set should not be
        # counted twice when we tally fingerprint-type vs email-type updates.
        email_row = BlockedCustomerObject.new(
          seller: seller,
          object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email],
          object_value: buyer_email,
          buyer_email: buyer_email,
          blocked_at: Time.current
        )
        email_row.save!(validate: false)

        result = described_class.new(buyer_email, performed_by: admin).perform!

        # One row touched once (object_value updated), not double-counted.
        expect(result[:counts][:blocked_customer_objects]).to eq(1)
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

          anonymized_member_ids = AudienceMember.where(email: buyer_email).where.not(id: fresh.id).ids
          ElasticsearchIndexerWorker.jobs.clear

          expect { described_class.new(buyer_email, performed_by: admin).perform! }.not_to raise_error
          expect(AudienceMember.where(seller: seller, email: buyer_email).count).to eq(0)
          expect(AudienceMember.where(id: existing_anonymized.id)).to exist
          expect(AudienceMember.where(id: fresh.id)).not_to exist

          indexer_args = ElasticsearchIndexerWorker.jobs.map { _1["args"] }
          expect(indexer_args).to include(["delete", { "record_id" => fresh.id, "class_name" => "AudienceMember" }])
          expect(anonymized_member_ids).to be_present
          anonymized_member_ids.each do |member_id|
            reindex_args = indexer_args.find { _1[0] == "index" && _1[1]["record_id"] == member_id }
            expect(reindex_args).to be_present
          end
        end
      end

      describe "audience members Elasticsearch sync" do
        it "reindexes anonymized members with the anonymized document passed inline" do
          anonymized = described_class.new(buyer_email, performed_by: admin).send(:generate_anonymized_email)
          member_ids = AudienceMember.where(email: buyer_email).ids
          expect(member_ids).to be_present
          ElasticsearchIndexerWorker.jobs.clear

          described_class.new(buyer_email, performed_by: admin).perform!

          audience_member_args = ElasticsearchIndexerWorker.jobs.map { _1["args"] }.select { _1[1]["class_name"] == "AudienceMember" }
          expect(audience_member_args.count { _1[0] == "delete" }).to eq(0)
          member_ids.each do |member_id|
            reindex_args = audience_member_args.find { _1[0] == "index" && _1[1]["record_id"] == member_id }
            expect(reindex_args).to be_present
            expect(reindex_args[1]["body"]).to include(
              "email" => anonymized,
              "customer" => false,
              "follower" => false,
              "affiliate" => false,
              "purchases" => [],
              "affiliates" => [],
              "follower_id" => nil,
            )
          end

          AudienceMember.where(id: member_ids).each do |member|
            expect(member.customer).to eq(false)
            expect(member.min_paid_cents).to be_nil
            expect(member.max_purchase_created_at).to be_nil
          end
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

      describe "best-effort behavior on lock-wait timeouts" do
        it "skips a timed-out step, still erases the rest, and reports it as skipped" do
          # Simulate the events table contending for a lock (the #438 failure):
          # the events step times out, but purchases and everything else must
          # still be anonymized rather than rolled back.
          allow_any_instance_of(described_class).to receive(:anonymize_events!).and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")

          result = described_class.new(buyer_email, performed_by: admin).perform!

          expect(result[:success]).to be(true)
          expect(result[:skipped]).to eq([:events])
          # The rest of the erasure still happened.
          expect(purchase1.reload.email).to eq(result[:anonymized_to])
          expect(purchase1.full_name).to eq(GdprDataErasureService::ANONYMIZED_NAME)
          expect(purchase2.reload.email).to eq(result[:anonymized_to])
        end

        it "treats StatementTimeout and QueryCanceled as non-critical skips too" do
          allow_any_instance_of(described_class).to receive(:anonymize_carts!).and_raise(ActiveRecord::StatementTimeout, "statement timeout")
          allow_any_instance_of(described_class).to receive(:anonymize_followers!).and_raise(ActiveRecord::QueryCanceled, "canceling statement")

          result = described_class.new(buyer_email, performed_by: admin).perform!

          expect(result[:success]).to be(true)
          expect(result[:skipped]).to match_array(%i[carts followers])
          expect(purchase1.reload.email).to eq(result[:anonymized_to])
        end

        it "records skipped tables in the seller admin comment" do
          allow_any_instance_of(described_class).to receive(:anonymize_events!).and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
          seller = purchase1.seller

          described_class.new(buyer_email, performed_by: admin).perform!

          comment = seller.reload.comments.last
          expect(comment.content).to include("skipped due to lock-wait timeouts")
          expect(comment.content).to include("events")
        end

        it "still raises (does NOT silence) a non-timeout error" do
          allow_any_instance_of(described_class).to receive(:anonymize_purchases!).and_raise(StandardError, "boom")

          expect { described_class.new(buyer_email, performed_by: admin).perform! }.to raise_error(StandardError, /boom/)
        end

        it "returns an empty skipped list when nothing times out" do
          result = described_class.new(buyer_email, performed_by: admin).perform!

          expect(result[:skipped]).to eq([])
        end
      end
    end
  end
end
