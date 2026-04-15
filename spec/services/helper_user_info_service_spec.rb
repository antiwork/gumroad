# frozen_string_literal: true

require "spec_helper"

describe HelperUserInfoService do
  include Rails.application.routes.url_helpers

  let(:user) { create(:user, email: "user@example.com") }

  describe "#customer_info" do
    let(:service) { described_class.new(email: user.email) }

    it "retrieves user info" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(2250)

      result = service.customer_info

      expect(result[:name]).to eq(user.name)
      expect(result[:value]).to eq(2250)
      expect(result[:actions]).to eq({
                                       "Admin (user)" => "http://app.test.gumroad.com:31337/admin/users/#{user.id}",
                                       "Admin (purchases)" => "http://app.test.gumroad.com:31337/admin/search/purchases?query=#{CGI.escape(user.email)}",
                                       "Impersonate" => "http://app.test.gumroad.com:31337/admin/helper_actions/impersonate/#{user.external_id}"
                                     })

      expect(result[:metadata]).to include(
        "User ID" => user.id,
        "Account Created" => user.created_at.to_fs(:formatted_date_full_month),
        "Account Status" => "Active",
        "Total Earnings Since Joining" => "$22.50"
      )
    end

    context "value calculation" do
      let(:product) { create(:product, user:, price_cents: 100_00) }

      it "returns the higher value between lifetime sales and last-90-day purchases" do
        # Bought $10.00 of products in the last 90 days.
        create(:purchase, purchaser: user, price_cents: 10_00, created_at: 95.days.ago)
        create(:purchase, purchaser: user, price_cents: 10_00, created_at: 1.day.ago)
        index_model_records(Purchase)

        expect(service.customer_info[:value]).to eq(10_00)

        # Sold $100.00 of products, before fees.
        sale = create(:purchase, link: product, price_cents: 100_00, created_at: 30.days.ago)
        index_model_records(Purchase)

        expect(service.customer_info[:value]).to eq(sale.payment_cents)
      end
    end

    context "when user is not found" do
      let(:service) { described_class.new(email: "inexistent@example.com") }

      it "returns empty user details and metadata" do
        result = service.customer_info
        expect(result[:name]).to be_nil
        expect(result[:value]).to be_nil
        expect(result[:actions]).to be_nil
        expect(result[:metadata]).to eq({})
      end
    end

    context "with recent purchase" do
      let(:service) { HelperUserInfoService.new(email: user.email) }

      it "includes recent purchase info" do
        product = create(:product)
        purchase = create(:purchase, purchaser: user, link: product, price_cents: 1_00, created_at: 1.day.ago)
        result = service.customer_info

        purchase_info = result[:metadata]["Most Recent Purchase"]
        expect(purchase_info).to include(
          "Status" => "Successful",
          "Product" => product.name,
          "Price" => purchase.formatted_display_price,
          "Date" => purchase.created_at.to_fs(:formatted_date_full_month),
          "Product URL" => product.long_url,
          "Creator Support Email" => purchase.seller.support_email || purchase.seller.form_email,
          "Creator Email" => purchase.seller_email,
          "Receipt URL" => receipt_purchase_url(purchase.external_id, host: DOMAIN, email: purchase.email),
          "License Key" => purchase.license_key
        )
      end
    end

    context "when user has a Stripe Connect account" do
      it "includes the stripe_connect_account_id in actions" do
        merchant_account = create(:merchant_account, charge_processor_id: StripeChargeProcessor.charge_processor_id)
        user_with_stripe = merchant_account.user
        service = described_class.new(email: user_with_stripe.email)

        result = service.customer_info
        expect(result[:actions]["View Stripe account"]).to eq("http://app.test.gumroad.com:31337/admin/helper_actions/stripe_dashboard/#{user_with_stripe.external_id}")
      end
    end

    context "when there's a failed purchase" do
      it "includes failed purchase info" do
        product = create(:product)
        failed_purchase = create(:purchase, purchase_state: "failed", purchaser: user, link: product, price_cents: 1_00, created_at: 1.day.ago)
        result = described_class.new(email: user.email).customer_info

        purchase_info = result[:metadata]["Most Recent Purchase"]
        expect(purchase_info).to include(
          "Status" => "Failed",
          "Error" => failed_purchase.formatted_error_code,
          "Product" => product.name,
          "Price" => failed_purchase.formatted_display_price,
          "Date" => failed_purchase.created_at.to_fs(:formatted_date_full_month)
        )
      end
    end

    context "when purchase has a refund policy" do
      it "includes refund policy info" do
        product = create(:product)
        purchase = create(:purchase, purchaser: user, link: product, created_at: 1.day.ago)
        purchase.create_purchase_refund_policy!(
          title: ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30],
          max_refund_period_in_days: 30,
          fine_print: "This is the fine print of the refund policy."
        )
        result = described_class.new(email: user.email).customer_info

        purchase_info = result[:metadata]["Most Recent Purchase"]
        expect(purchase_info["Refund Policy"]).to eq("This is the fine print of the refund policy.")
      end
    end

    context "when purchase has a license key" do
      it "includes license key info" do
        product = create(:product, is_licensed: true)
        purchase = create(:purchase, purchaser: user, link: product, created_at: 1.day.ago)
        license = create(:license, purchase: purchase)
        result = described_class.new(email: user.email).customer_info

        purchase_info = result[:metadata]["Most Recent Purchase"]
        expect(purchase_info["License Key"]).to eq(license.serial)
      end
    end

    context "when user has country" do
      it "includes country in the metadata" do
        user.update!(country: "United States")

        result = described_class.new(email: user.email).customer_info
        expect(result[:metadata]["Country"]).to eq("United States")
      end
    end

    context "when user has no country" do
      it "does not include country in the metadata" do
        user.update!(country: nil)

        result = described_class.new(email: user.email).customer_info
        expect(result[:metadata]).not_to have_key("Country")
      end
    end

    context "structured comments" do
      let(:service) { described_class.new(email: user.email) }

      it "returns structured comment objects with external_id" do
        comment = create(:comment,
                         commentable: user,
                         comment_type: Comment::COMMENT_TYPE_NOTE,
                         content: "Test note",
                         created_at: 1.hour.ago
        )

        result = service.customer_info
        expect(result[:comments]).to be_an(Array)
        expect(result[:comments].first).to include(
          id: comment.external_id,
          content: "Test note",
          comment_type: Comment::COMMENT_TYPE_NOTE
        )
        expect(result[:comments].first[:author_name]).to be_present
        expect(result[:comments].first[:created_at]).to be_present
      end

      it "returns comments in descending order" do
        create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE, content: "Older", created_at: 2.hours.ago)
        create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE, content: "Newer", created_at: 1.hour.ago)

        result = service.customer_info
        expect(result[:comments].first[:content]).to eq("Newer")
        expect(result[:comments].last[:content]).to eq("Older")
      end

      it "caps at STRUCTURED_COMMENTS_LIMIT" do
        (described_class::STRUCTURED_COMMENTS_LIMIT + 1).times { |i| create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE, content: "Note #{i}", created_at: i.minutes.ago) }

        result = service.customer_info
        expect(result[:comments].length).to eq(described_class::STRUCTURED_COMMENTS_LIMIT)
      end

      it "returns all comment types" do
        create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE, content: "A note")
        create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE, content: "A payout note", author_id: GUMROAD_ADMIN_ID)
        create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_FLAGGED, content: "A risk note")

        result = service.customer_info
        types = result[:comments].map { |c| c[:comment_type] }
        expect(types).to include(Comment::COMMENT_TYPE_NOTE, Comment::COMMENT_TYPE_PAYOUT_NOTE, Comment::COMMENT_TYPE_FLAGGED)
      end

      it "returns empty array when no user exists" do
        result = described_class.new(email: "nobody@example.com").customer_info
        expect(result[:comments]).to eq([])
      end

      it "returns empty array when user is found via support_email only" do
        user.update!(support_email: "support@example.com")
        result = described_class.new(email: "support@example.com").customer_info
        expect(result[:comments]).to eq([])
      end

      it "returns empty array for soft-deleted user" do
        user.mark_deleted!
        result = described_class.new(email: user.email).customer_info
        expect(result[:comments]).to eq([])
      end
    end

    context "can_add_comment" do
      it "is true when user exists by primary email" do
        result = described_class.new(email: user.email).customer_info
        expect(result[:can_add_comment]).to be true
      end

      it "is false when no user exists" do
        result = described_class.new(email: "nobody@example.com").customer_info
        expect(result[:can_add_comment]).to be false
      end

      it "is false when user is found via support_email only" do
        user.update!(support_email: "support@example.com")
        result = described_class.new(email: "support@example.com").customer_info
        expect(result[:can_add_comment]).to be false
      end

      it "is false for soft-deleted user" do
        user.mark_deleted!
        result = described_class.new(email: user.email).customer_info
        expect(result[:can_add_comment]).to be false
      end
    end
  end
end
