# frozen_string_literal: true

require "test_helper"

class CreatorAnalyticsChurnElasticsearchFetcherTest < ActiveSupport::TestCase
  self.described_class = CreatorAnalytics::Churn::ElasticsearchFetcher



  context_ CreatorAnalytics::Churn::ElasticsearchFetcher do
    let(:seller) { create(:user, timezone: "UTC", created_at: Time.utc(2020, 1, 1)) }
    let(:product1) { create(:product, :is_subscription, user: seller) }
    let(:product2) { create(:product, :is_subscription, user: seller) }
    let(:products) { [product1, product2] }
    let(:start_date) { Date.new(2020, 1, 15) }
    let(:end_date) { Date.new(2020, 1, 20) }
    let(:date_window) do
      CreatorAnalytics::Churn::DateWindow.new(
        seller:,
        product_scope: CreatorAnalytics::Churn::ProductScope.new(seller:),
        start_date:,
        end_date:
      )
    end
    let(:service) { described_class.new(seller:, products:, date_window:) }

    def create_subscription_purchase(
      product:,
      created_at:,
      subscription_cancelled_at: nil,
      subscription_deactivated_at: nil,
      price_cents: 100,
      recurrence: BasePrice::Recurrence::MONTHLY
    )
      price = create(:price, link: product, price_cents:, recurrence:)
      subscription = create(
        :subscription,
        link: product,
        user: seller,
        cancelled_at: subscription_cancelled_at,
        deactivated_at: subscription_deactivated_at,
        price:
      )
      purchase = create(
        :purchase,
        link: product,
        seller:,
        subscription:,
        is_original_subscription_purchase: true,
        created_at:,
        price_cents:
      )
      purchase
    end

  context_ "#churn_events" do
  context_ "when seller timezone observes DST" do
        let(:seller) { create(:user, timezone: "Pacific Time (US & Canada)") }
        let(:products) { [product1, product2] }
        let(:start_date) { Date.new(2020, 5, 31) }
        let(:end_date) { Date.new(2020, 6, 1) }

        before do
          create_subscription_purchase(
            product: product1,
            created_at: Time.utc(2020, 5, 1),
            subscription_cancelled_at: Time.utc(2020, 6, 1, 7, 30),
            price_cents: 100
          )
          create_subscription_purchase(
            product: product2,
            created_at: Time.utc(2020, 5, 1),
            subscription_cancelled_at: Time.utc(2020, 6, 1, 6, 30),
            price_cents: 200
          )
          index_model_records(Purchase)
        end

  test "buckets churn events using the seller timezone" do
          result = service.churn_events

          expect(result[[product1.id, Date.new(2020, 6, 1)]]).to include(
            churned_count: 1,
            revenue_lost_cents: 100
          )
          expect(result[[product2.id, Date.new(2020, 5, 31)]]).to include(
            churned_count: 1,
            revenue_lost_cents: 200
          )
        end
      end

  context_ "when products are empty" do
        let(:products) { [] }

  test "returns empty hash" do
          expect(service.churn_events).to eq({})
        end
      end

  context_ "when products are present" do
        before do
          create_subscription_purchase(
            product: product1,
            created_at: Time.utc(2020, 1, 10),
            subscription_cancelled_at: Time.utc(2020, 1, 15, 10)
          )
          create_subscription_purchase(
            product: product1,
            created_at: Time.utc(2020, 1, 10),
            subscription_cancelled_at: Time.utc(2020, 1, 15, 14),
            price_cents: 1200,
            recurrence: BasePrice::Recurrence::YEARLY
          )
          create_subscription_purchase(
            product: product1,
            created_at: Time.utc(2020, 1, 10),
            subscription_cancelled_at: Time.utc(2020, 1, 16, 10)
          )
          create_subscription_purchase(
            product: product2,
            created_at: Time.utc(2020, 1, 10),
            subscription_cancelled_at: Time.utc(2020, 1, 15, 12)
          )
          create_subscription_purchase(
            product: product2,
            created_at: Time.utc(2020, 1, 10),
            subscription_cancelled_at: Time.utc(2020, 1, 15, 16)
          )
          create_subscription_purchase(
            product: product2,
            created_at: Time.utc(2020, 1, 10),
            subscription_cancelled_at: Time.utc(2020, 1, 15, 18)
          )
          index_model_records(Purchase)
        end

  test "returns churn events grouped by product_id and date" do
          expect(Purchase).to receive(:search).once.and_call_original
          result = service.churn_events

          expect(result[[product1.id, Date.new(2020, 1, 15)]]).to include(
            churned_count: 2,
            revenue_lost_cents: 200
          )
          expect(result[[product1.id, Date.new(2020, 1, 16)]]).to include(
            churned_count: 1,
            revenue_lost_cents: 100
          )
          expect(result[[product2.id, Date.new(2020, 1, 15)]]).to include(
            churned_count: 3,
            revenue_lost_cents: 300
          )
        end

  test "handles pagination" do
          stub_const("#{described_class}::ES_MAX_BUCKET_SIZE", 2)
          expect(Purchase).to receive(:search).at_least(:once).and_call_original
          result = service.churn_events

          expect(result.keys.length).to eq(3)
        end
      end

  context_ "when cancellations and deactivations diverge" do
        let(:products) { [product1] }

  test "counts churn based on cancellations, not deactivations" do
          create_subscription_purchase(
            product: product1,
            created_at: Time.utc(2020, 1, 10),
            subscription_cancelled_at: Time.utc(2020, 1, 16, 10)
          )
          create_subscription_purchase(
            product: product1,
            created_at: Time.utc(2020, 1, 10),
            subscription_deactivated_at: Time.utc(2020, 1, 17, 10)
          )
          index_model_records(Purchase)

          result = service.churn_events

          expect(result[[product1.id, Date.new(2020, 1, 16)]]).to include(
            churned_count: 1,
            revenue_lost_cents: 100
          )
          expect(result).not_to have_key([product1.id, Date.new(2020, 1, 17)])
        end
      end

  context_ "when a subscription changes plans before cancellation" do
        let(:product) { create(:product, :is_subscription, user: seller) }
        let(:products) { [product] }
        let(:start_date) { Date.new(2020, 4, 1) }
        let(:end_date) { Date.new(2020, 4, 30) }
        let(:original_price) { create(:price, link: product, price_cents: 1_000, recurrence: BasePrice::Recurrence::MONTHLY) }
        let(:new_price) { create(:price, link: product, price_cents: 3_000, recurrence: BasePrice::Recurrence::MONTHLY) }
        let(:subscription) { create(:subscription, link: product, user: seller, price: original_price) }
        let(:original_purchase) do
          create(
            :purchase,
            link: product,
            seller:,
            subscription:,
            is_original_subscription_purchase: true,
            created_at: Time.utc(2020, 4, 1),
            price_cents: original_price.price_cents
          )
        end

        before do
          original_purchase.update_flag!(:is_archived_original_subscription_purchase, true, true)
          subscription.last_payment_option.update!(price: new_price)
          create(
            :purchase,
            link: product,
            seller:,
            subscription:,
            is_original_subscription_purchase: true,
            purchase_state: "not_charged",
            succeeded_at: nil,
            created_at: Time.utc(2020, 4, 5),
            price_cents: new_price.price_cents
          )
          subscription.update!(cancelled_at: Time.utc(2020, 4, 10, 12))
          index_model_records(Purchase)
        end

  test "uses the archived original purchase price for revenue lost" do
          result = service.churn_events

          expect(result[[product.id, Date.new(2020, 4, 10)]]).to include(
            churned_count: 1,
            revenue_lost_cents: original_price.price_cents
          )
        end
      end
    end

  context_ "#new_subscriptions" do
  context_ "when products are empty" do
        let(:products) { [] }

  test "returns empty hash" do
          expect(service.new_subscriptions).to eq({})
        end
      end

  context_ "when products are present" do
        before do
          create_subscription_purchase(product: product1, created_at: Time.utc(2020, 1, 15, 10))
          create_subscription_purchase(product: product1, created_at: Time.utc(2020, 1, 15, 14))
          create_subscription_purchase(product: product1, created_at: Time.utc(2020, 1, 15, 18))
          create_subscription_purchase(product: product1, created_at: Time.utc(2020, 1, 16, 10))
          create_subscription_purchase(product: product1, created_at: Time.utc(2020, 1, 16, 14))
          create_subscription_purchase(product: product2, created_at: Time.utc(2020, 1, 15, 12))
          create_subscription_purchase(product: product2, created_at: Time.utc(2020, 1, 15, 16))
          index_model_records(Purchase)
        end

  test "returns new subscription counts grouped by product_id and date" do
          expect(Purchase).to receive(:search).once.and_call_original
          result = service.new_subscriptions

          expect(result[[product1.id, Date.new(2020, 1, 15)]]).to eq(3)
          expect(result[[product1.id, Date.new(2020, 1, 16)]]).to eq(2)
          expect(result[[product2.id, Date.new(2020, 1, 15)]]).to eq(2)
        end

  test "handles pagination" do
          stub_const("#{described_class}::ES_MAX_BUCKET_SIZE", 2)
          expect(Purchase).to receive(:search).at_least(:once).and_call_original
          result = service.new_subscriptions

          expect(result.keys.length).to eq(3)
        end
      end
    end

  context_ "#initial_active_counts" do
  context_ "when products are empty" do
        let(:products) { [] }

  test "returns empty hash" do
          expect(service.initial_active_counts).to eq({})
        end
      end

  context_ "when products are present" do
        before do
          create_subscription_purchase(product: product1, created_at: Time.utc(2020, 1, 10))
          create_subscription_purchase(product: product1, created_at: Time.utc(2020, 1, 12))
          create_subscription_purchase(product: product1, created_at: Time.utc(2020, 1, 13))
          create_subscription_purchase(product: product2, created_at: Time.utc(2020, 1, 11))
          create_subscription_purchase(product: product2, created_at: Time.utc(2020, 1, 14))
          index_model_records(Purchase)
        end

  test "returns active subscriber counts per product" do
          expect(Purchase).to receive(:search).once.and_call_original
          result = service.initial_active_counts

          expect(result[product1.id]).to eq(3)
          expect(result[product2.id]).to eq(2)
        end

  test "excludes deactivated subscriptions before start_date" do
          create_subscription_purchase(
            product: product1,
            created_at: Time.utc(2020, 1, 10),
            subscription_deactivated_at: Time.utc(2020, 1, 14)
          )
          index_model_records(Purchase)

          expect(Purchase).to receive(:search).once.and_call_original
          result = service.initial_active_counts

          expect(result[product1.id]).to eq(3)
        end

  test "includes subscriptions deactivated after start_date" do
          create_subscription_purchase(
            product: product1,
            created_at: Time.utc(2020, 1, 10),
            subscription_deactivated_at: Time.utc(2020, 1, 16)
          )
          index_model_records(Purchase)

          expect(Purchase).to receive(:search).once.and_call_original
          result = service.initial_active_counts

          expect(result[product1.id]).to eq(4)
        end

  test "handles pagination" do
          stub_const("#{described_class}::ES_MAX_BUCKET_SIZE", 1)
          expect(Purchase).to receive(:search).at_least(:once).and_call_original
          result = service.initial_active_counts

          expect(result.keys.length).to eq(2)
        end
      end
    end
  end
end
