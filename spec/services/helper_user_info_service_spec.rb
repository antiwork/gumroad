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
                                       "Admin (purchases)" => "http://app.test.gumroad.com:31337/admin/search_purchases?query=#{CGI.escape(user.email)}",
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

    context "seller comments" do
      let(:service) { described_class.new(email: user.email) }

      context "when user has payout notes" do
        it "includes payout notes from admin" do
          create(:comment,
                 commentable: user,
                 comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE,
                 author_id: GUMROAD_ADMIN_ID,
                 content: "Payout delayed due to verification"
          )

          result = service.customer_info
          expect(result[:metadata]["Comments"]).to include("Payout Note: Payout delayed due to verification")
        end

        it "excludes payout notes not from admin" do
          other_user = create(:user)
          create(:comment,
                 commentable: user,
                 comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE,
                 author_id: other_user.id,
                 content: "Non-admin payout note"
          )

          result = service.customer_info
          comments = result[:metadata]["Comments"] || []
          expect(comments).not_to include("Payout Note: Non-admin payout note")
        end
      end

      context "when user has risk notes" do
        it "includes all risk state comment types" do
          Comment::RISK_STATE_COMMENT_TYPES.each_with_index do |comment_type, index|
            create(:comment,
                   commentable: user,
                   comment_type: comment_type,
                   content: "Risk note #{index + 1}",
                   created_at: index.minutes.ago
            )
          end

          result = service.customer_info
          comments = result[:metadata]["Comments"] || []
          Comment::RISK_STATE_COMMENT_TYPES.each_with_index do |_, index|
            expect(comments).to include("Risk Note: Risk note #{index + 1}")
          end
        end

        it "orders risk notes by creation time" do
          create(:comment,
                 commentable: user,
                 comment_type: Comment::COMMENT_TYPE_FLAGGED,
                 content: "Older risk note",
                 created_at: 2.hours.ago
          )
          create(:comment,
                 commentable: user,
                 comment_type: Comment::COMMENT_TYPE_COUNTRY_CHANGED,
                 content: "Newer risk note",
                 created_at: 1.hour.ago
          )

          result = service.customer_info
          comments = result[:metadata]["Comments"] || []
          older_index = comments.find_index { |comment| comment.include?("Older risk note") }
          newer_index = comments.find_index { |comment| comment.include?("Newer risk note") }

          expect(older_index).to be < newer_index
        end
      end

      context "when user has suspension notes" do
        context "when user is suspended" do
          let(:user) { create(:tos_user) }

          it "includes suspension notes" do
            create(:comment,
                   commentable: user,
                   comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE,
                   content: "Account suspended for policy violation"
            )

            result = service.customer_info
            expect(result[:metadata]["Comments"]).to include("Suspension Note: Account suspended for policy violation")
          end
        end

        context "when user is not suspended" do
          before { allow(user).to receive(:suspended?).and_return(false) }

          it "excludes suspension notes" do
            create(:comment,
                   commentable: user,
                   comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE,
                   content: "Account suspended for policy violation"
            )

            result = service.customer_info
            comments = result[:metadata]["Comments"] || []
            expect(comments).not_to include("Suspension Note: Account suspended for policy violation")
          end
        end
      end

      context "when user has other comment types" do
        it "includes general comments" do
          create(:comment,
                 commentable: user,
                 comment_type: Comment::COMMENT_TYPE_COUNTRY_CHANGED,
                 content: "General user comment"
          )

          result = service.customer_info
          expect(result[:metadata]["Comments"]).to include("Comment: General user comment")
        end

        it "includes custom comment types" do
          create(:comment,
                 commentable: user,
                 comment_type: "custom_type",
                 content: "Custom comment type"
          )

          result = service.customer_info
          expect(result[:metadata]["Comments"]).to include("Comment: Custom comment type")
        end
      end

      context "when user has multiple comment types" do
        it "includes all comments in chronological order" do
          create(:comment,
                 commentable: user,
                 comment_type: Comment::COMMENT_TYPE_PAYOUT_NOTE,
                 author_id: GUMROAD_ADMIN_ID,
                 content: "Payout note",
                 created_at: 3.hours.ago
          )
          create(:comment,
                 commentable: user,
                 comment_type: Comment::COMMENT_TYPE_FLAGGED,
                 content: "Risk note",
                 created_at: 2.hours.ago
          )
          create(:comment,
                 commentable: user,
                 comment_type: Comment::COMMENT_TYPE_COUNTRY_CHANGED,
                 content: "General note",
                 created_at: 1.hour.ago
          )

          result = service.customer_info
          comments = result[:metadata]["Comments"] || []
          expect(comments).to include("Payout Note: Payout note")
          expect(comments).to include("Risk Note: Risk note")
          expect(comments).to include("Comment: General note")

          payout_index = comments.find_index { |comment| comment.include?("Payout Note: Payout note") }
          risk_index = comments.find_index { |comment| comment.include?("Risk Note: Risk note") }
          general_index = comments.find_index { |comment| comment.include?("Comment: General note") }

          expect(payout_index).to be < risk_index
          expect(risk_index).to be < general_index
        end
      end

      context "when user has no comments" do
        it "does not include any comment information" do
          result = service.customer_info
          expect(result[:metadata]).not_to have_key("Comments")
        end
      end
    end
  end
end
