# frozen_string_literal: true

require "spec_helper"

describe SellerMobileAnalyticsService do
  before do
    @user = create(:user, timezone: "UTC")
    @product = create(:product, user: @user)
  end

  describe "#process" do
    it "returns the proper purchase data for all time" do
      valid_purchases = []
      travel_to(1.year.ago) do
        valid_purchases << create(:purchase, link: @product)
        valid_purchases << create(:purchase, link: @product, is_gift_sender_purchase: true)
        create(:purchase, link: @product, is_gift_receiver_purchase: true, purchase_state: "gift_receiver_purchase_successful")
        valid_purchases << create(:purchase, link: @product, chargeback_date: Time.current)
        valid_purchases << create(:purchase, link: @product, chargeback_date: Time.current, chargeback_reversed: true)
        refunded_purchase = create(:purchase, link: @product)
        create(:refund, purchase: create(:purchase, link: @product))
        valid_purchases << refunded_purchase
      end

      travel_to(2.weeks.ago) do
        valid_purchases << create(:purchase, link: @product)
      end

      valid_purchases << create(:purchase, link: @product)

      valid_purchases << begin
        preorder = create(:preorder)
        purchase = create(:purchase, link: @product, purchase_state: "preorder_concluded_successfully")
        purchase.update!(preorder:)
        create(:purchase, link: @product, preorder:)
        purchase
      end

      valid_purchases << begin
        purchase = create(:purchase, link: @product)
        purchase.refund_partial_purchase!(1, purchase.seller)
        purchase.refund_partial_purchase!(2, purchase.seller)
        purchase
      end

      index_model_records(Purchase)

      result = described_class.new(@user, range: "all").process

      expected_revenue_in_cents = \
        valid_purchases.sum(&:price_cents) - \
        valid_purchases.select(&:stripe_partially_refunded?).flat_map(&:refunds).sum(&:amount_cents) - \
        valid_purchases.select(&:refunded?).sum(&:price_cents) - \
        valid_purchases.select(&:chargedback_not_reversed?).sum(&:price_cents)
      expect(result[:revenue]).to eq expected_revenue_in_cents
      expect(result[:formatted_revenue]).to eq Money.new(expected_revenue_in_cents, "USD").format(no_cents_if_whole: true)
    end

    it "returns the proper purchase data for the year" do
      valid_purchases = []
      travel_to(Date.today.beginning_of_year - 2.days) do
        create(:purchase, link: @product)
      end
      travel_to(Date.today.beginning_of_year + 2.days) do
        valid_purchases << create(:purchase, link: @product)
      end

      valid_purchases << create(:purchase, link: @product)

      index_model_records(Purchase)

      result = described_class.new(@user, range: "year").process

      expected_revenue_in_cents = valid_purchases.sum(&:price_cents)
      expect(result[:revenue]).to eq expected_revenue_in_cents
      expect(result[:formatted_revenue]).to eq Money.new(expected_revenue_in_cents, "USD").format(no_cents_if_whole: true)
    end

    it "returns the proper purchase data for current month" do
      valid_purchases = []
      travel_to(1.year.ago) do
        create(:purchase, link: @product)
      end

      travel_to(Date.today.beginning_of_month + 2.days) do
        valid_purchases << create(:purchase, link: @product)
      end

      valid_purchases << create(:purchase, link: @product)

      index_model_records(Purchase)

      result = described_class.new(@user, range: "month").process

      expected_revenue_in_cents = valid_purchases.sum(&:price_cents)
      expect(result[:revenue]).to eq expected_revenue_in_cents
      expect(result[:formatted_revenue]).to eq Money.new(expected_revenue_in_cents, "USD").format(no_cents_if_whole: true)
    end

    it "returns the proper purchase data for the current week" do
      valid_purchases = []
      travel_to(1.year.ago) do
        create(:purchase, link: @product)
      end

      travel_to(2.weeks.ago) do
        create(:purchase, link: @product)
      end

      travel_to(Date.today.beginning_of_week + 2.days) do
        valid_purchases << create(:purchase, link: @product)
        valid_purchases << create(:purchase, link: @product, created_at: 1.day.ago)
        create(:purchase, link: @product, created_at: 3.days.ago)
      end

      index_model_records(Purchase)

      result = described_class.new(@user, range: "week").process

      expected_revenue_in_cents = valid_purchases.sum(&:price_cents)
      expect(result[:revenue]).to eq expected_revenue_in_cents
      expect(result[:formatted_revenue]).to eq Money.new(expected_revenue_in_cents, "USD").format(no_cents_if_whole: true)
    end

    it "returns the proper purchase data for the current day" do
      valid_purchases = []
      travel_to(1.year.ago) do
        create(:purchase, link: @product)
      end

      travel_to(2.weeks.ago) do
        create(:purchase, link: @product)
      end

      valid_purchases << create(:purchase, link: @product)

      index_model_records(Purchase)

      result = described_class.new(@user, range: "day").process

      expected_revenue_in_cents = valid_purchases.sum(&:price_cents)
      expect(result[:revenue]).to eq expected_revenue_in_cents
      expect(result[:formatted_revenue]).to eq Money.new(expected_revenue_in_cents, "USD").format(no_cents_if_whole: true)
    end

    context "when not requesting optional fields" do
      it "only returns revenue" do
        create(:purchase, link: @product)
        result = described_class.new(@user).process
        expect(result.keys).to match_array([:revenue, :formatted_revenue])
      end
    end

    context "when requesting optional fields" do
      context "when requesting :purchases" do
        it "returns purchases records as json" do
          expected_purchases = create_list(:purchase, 2, link: @product)
          index_model_records(Purchase)
          result = described_class.new(@user, fields: [:purchases]).process
          expect(result.keys).to match_array([:revenue, :formatted_revenue, :purchases])
          expect(result[:purchases]).to match_array(expected_purchases.as_json(creator_app_api: true))
        end

        it "limits purchases returned to SALES_LIMIT" do
          stub_const("#{described_class}::SALES_LIMIT", 5)
          create_list(:purchase, 7, link: @product)
          index_model_records(Purchase)
          result = described_class.new(@user, fields: [:purchases]).process
          expect(result[:purchases].size).to eq 5
        end

        context "with query parameter" do
          it "passes seller_query to search options when query is provided" do
            create(:purchase, link: @product, email: "john@example.com", full_name: "John Doe")
            create(:purchase, link: @product, email: "jane@example.com", full_name: "Jane Smith")
            index_model_records(Purchase)

            expect(PurchaseSearchService).to receive(:search).with(
              hash_including(seller_query: "john")
            ).and_call_original

            described_class.new(@user, fields: [:purchases], query: "john").process
          end

          it "does not pass seller_query when query is nil" do
            create(:purchase, link: @product)
            index_model_records(Purchase)

            expect(PurchaseSearchService).to receive(:search).with(
              hash_not_including(:seller_query)
            ).and_call_original

            described_class.new(@user, fields: [:purchases], query: nil).process
          end

          it "does not pass seller_query when query is empty" do
            create(:purchase, link: @product)
            index_model_records(Purchase)

            expect(PurchaseSearchService).to receive(:search).with(
              hash_not_including(:seller_query)
            ).and_call_original

            described_class.new(@user, fields: [:purchases], query: "").process
          end

          it "does not pass seller_query when query is whitespace only" do
            create(:purchase, link: @product)
            index_model_records(Purchase)

            expect(PurchaseSearchService).to receive(:search).with(
              hash_not_including(:seller_query)
            ).and_call_original

            described_class.new(@user, fields: [:purchases], query: "   ").process
          end
        end
      end

      context "when requesting :sales_count" do
        it "returns the total count of sales" do
          create_list(:purchase, 2, link: @product)
          index_model_records(Purchase)
          result = described_class.new(@user, fields: [:sales_count]).process
          expect(result.keys).to match_array([:revenue, :formatted_revenue, :sales_count])
          expect(result[:sales_count]).to eq(2)
        end

        context "with query parameter" do
          it "does not pass seller_query to search options when only requesting sales_count" do
            create(:purchase, link: @product)
            index_model_records(Purchase)

            expect(PurchaseSearchService).to receive(:search).with(
              hash_not_including(:seller_query)
            ).and_call_original

            described_class.new(@user, fields: [:sales_count], query: "test").process
          end
        end
      end
    end

    context "with an invalid range" do
      it "raises an error" do
        expect { described_class.new(@user, range: "1d").process }.to raise_error(/Invalid range 1d/)
      end
    end
  end
end
