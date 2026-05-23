# frozen_string_literal: true

require "test_helper"

class ModelsPurchasePurchaseSubscriptionTest < ActiveSupport::TestCase
  self.rspec_metadata = { vcr: true }



  context_ "PurchaseSubscription", :vcr do
    include CurrencyHelper
    include ProductsHelper

    def verify_balance(user, expected_balance)
      expect(user.unpaid_balance_cents).to eq expected_balance
    end

  context_ "subscriptions" do
  context_ "original subscription purchase" do
        before do
          tier_prices = [
            { monthly: { enabled: true, price: 2 }, quarterly: { enabled: true, price: 12 },
              biannually: { enabled: true, price: 20 }, yearly: { enabled: true, price: 30 },
              every_two_years: { enabled: true, price: 50 } },
            { monthly: { enabled: true, price: 4 }, quarterly: { enabled: true, price: 13 },
              biannually: { enabled: true, price: 21 }, yearly: { enabled: true, price: 31 },
              every_two_years: { enabled: true, price: 51 } }
          ]
          @product = create(:membership_product_with_preset_tiered_pricing, recurrence_price_values: tier_prices)
          @seller = @product.user
          @merchant_account = create(:merchant_account, user: @seller)
          @buyer = create(:user)
          @purchase = create(:membership_purchase, link: @product, seller: @seller, subscription: @subscription, price_cents: 200, purchase_state: "in_progress", merchant_account: @merchant_account)
          @subscription = @purchase.subscription
          @buyer = @purchase.purchaser
        end

  context_ "when set to successful" do
  test "increments seller's balance" do
            expect { @purchase.update_balance_and_mark_successful! }.to change {
              @purchase.link.user.reload.unpaid_balance_cents
            }.by(@purchase.payment_cents)
          end

  test "creates url_redirect" do
            expect { @purchase.update_balance_and_mark_successful! }.to change {
              UrlRedirect.count
            }
          end

  context_ "subscription jobs" do
  test "enqueues a recurring charge" do
              freeze_time do
                @purchase.update_balance_and_mark_successful!

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id).at(@subscription.reload.end_time_of_subscription)
              end
            end

  context_ "renewal reminders" do
              before { allow(@subscription).to receive(:send_renewal_reminders?).and_return(true) }

  test "schedules a renewal reminder if the billing period is quarterly" do
                freeze_time do
                  payment_option = @subscription.last_payment_option
                  payment_option.update!(price: @product.prices.find_by(recurrence: "quarterly"))

                  @purchase.update_balance_and_mark_successful!

                  reminder_time = @subscription.reload.send_renewal_reminder_at
                  expect(RecurringChargeReminderWorker).to have_enqueued_sidekiq_job(@subscription.id).at(reminder_time)
                end
              end

  test "schedules a renewal reminder if the billing period is biannually" do
                freeze_time do
                  payment_option = @subscription.last_payment_option
                  payment_option.update!(price: @product.prices.find_by(recurrence: "biannually"))

                  @purchase.update_balance_and_mark_successful!

                  reminder_time = @subscription.reload.send_renewal_reminder_at
                  expect(RecurringChargeReminderWorker).to have_enqueued_sidekiq_job(@subscription.id).at(reminder_time)
                end
              end

  test "schedules a renewal reminder if the billing period is yearly" do
                freeze_time do
                  payment_option = @subscription.last_payment_option
                  payment_option.update!(price: @product.prices.find_by(recurrence: "yearly"))

                  @purchase.update_balance_and_mark_successful!

                  reminder_time = @subscription.reload.send_renewal_reminder_at
                  expect(RecurringChargeReminderWorker).to have_enqueued_sidekiq_job(@subscription.id).at(reminder_time)
                end
              end

  test "schedules a renewal reminder if the billing period is every two years" do
                freeze_time do
                  payment_option = @subscription.last_payment_option
                  payment_option.update!(price: @product.prices.find_by(recurrence: "every_two_years"))

                  @purchase.update_balance_and_mark_successful!

                  reminder_time = @subscription.reload.send_renewal_reminder_at
                  expect(RecurringChargeReminderWorker).to have_enqueued_sidekiq_job(@subscription.id).at(reminder_time)
                end
              end

  test "schedules a renewal reminder if the billing period is monthly" do
                freeze_time do
                  payment_option = @subscription.last_payment_option
                  payment_option.update!(price: @product.prices.find_by(recurrence: "monthly"))

                  @purchase.update_balance_and_mark_successful!

                  reminder_time = @subscription.reload.send_renewal_reminder_at
                  expect(RecurringChargeReminderWorker).to have_enqueued_sidekiq_job(@subscription.id).at(reminder_time)
                end
              end

  test "does not schedule a renewal reminder irrespective of the billing period if the feature is disabled" do
                allow(@subscription).to receive(:send_renewal_reminders?).and_return(false)

                freeze_time do
                  payment_option = @subscription.last_payment_option
                  payment_option.update!(price: @product.prices.find_by(recurrence: "quarterly"))

                  @purchase.update_balance_and_mark_successful!

                  expect(RecurringChargeReminderWorker.jobs.count).to eq(0)
                end
              end
            end

  context_ "with shipping information" do
              before do
                @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :monthly, require_shipping: true)
                @subscription = create(:subscription, link: @product)
                @purchase = create(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                              link: @product, seller: @seller, price_cents: 200, fee_cents: 10, purchase_state: "successful",
                                              full_name: "Edgar Gumstein", street_address: "123 Gum Road", country: "USA", state: "CA",
                                              city: "San Francisco", subscription: @subscription, zip_code: "94117")
              end

  test "is valid without shipping information" do
                @recurring_charge = build(:purchase, is_original_subscription_purchase: false, credit_card: create(:credit_card), purchaser: @buyer,
                                                     link: @product, seller: @seller, price_cents: 200, fee_cents: 10,
                                                     purchase_state: "in_progress", subscription: @subscription)
                expect(@recurring_charge.update_balance_and_mark_successful!).to be(true)
              end
            end

  context_ "yearly subscriptions" do
              before do
                @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :yearly)
                @subscription = create(:subscription, link: @product)
                @purchase = build(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                             link: @product, seller: @seller, subscription: @subscription, price_cents: 200, fee_cents: 10, purchase_state: "in_progress")
              end

  test "enqueues a recurring charge" do
                mail_double = double
                allow(mail_double).to receive(:deliver_later)
                freeze_time do
                  @purchase.update_balance_and_mark_successful!

                  expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id)
                  expect(RecurringChargeWorker.jobs.last["at"]).to be_within(2).of(1.year.from_now.to_f)
                end
              end
            end

  context_ "quarterly subscriptions" do
              before do
                @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :quarterly)
                @subscription = create(:subscription, link: @product)
                @purchase = build(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                             link: @product, seller: @seller, subscription: @subscription, price_cents: 200, fee_cents: 10, purchase_state: "in_progress")
              end

  test "enqueues a recurring charge" do
                mail_double = double
                allow(mail_double).to receive(:deliver_later)
                freeze_time do
                  @purchase.update_balance_and_mark_successful!

                  expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id)
                  expect(RecurringChargeWorker.jobs.last["at"]).to be_within(2).of(3.months.from_now.to_f)
                end
              end
            end

  context_ "biannually subscriptions" do
              before do
                @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :biannually)
                @subscription = create(:subscription, link: @product)
                @purchase = build(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                             link: @product, seller: @seller, subscription: @subscription, price_cents: 200, fee_cents: 10, purchase_state: "in_progress")
              end

  test "enqueues a recurring charge" do
                mail_double = double
                allow(mail_double).to receive(:deliver_later)
                freeze_time do
                  @purchase.update_balance_and_mark_successful!

                  expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id)
                  expect(RecurringChargeWorker.jobs.last["at"]).to be_within(2).of(6.months.from_now.to_f)
                end
              end
            end

  context_ "every two years subscriptions" do
              before do
                @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :every_two_years)
                @subscription = create(:subscription, link: @product)
                @purchase = build(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                             link: @product, seller: @seller, subscription: @subscription, price_cents: 200, fee_cents: 10, purchase_state: "in_progress")
              end

  test "enqueues a recurring charge" do
                mail_double = double
                allow(mail_double).to receive(:deliver_later)
                freeze_time do
                  @purchase.update_balance_and_mark_successful!

                  expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id)
                  expect(RecurringChargeWorker.jobs.last["at"]).to be_within(2).of(2.years.from_now.to_f)
                end
              end
            end
          end
        end
      end

  context_ "recurring subscription purchase" do
  context_ "for a digital product" do
          let(:seller) { create(:named_seller) }
          let(:link) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :monthly) }
          let(:buyer) { create(:user) }
          let(:subscription) { create(:subscription, link:) }
          let(:purchase) do
            build(:purchase, credit_card: create(:credit_card), purchaser: buyer, link:, seller:,
                             price_cents: 200, fee_cents: 10, purchase_state: "in_progress", subscription:)
          end
          before do
            create(:purchase, subscription:, is_original_subscription_purchase: true)
            index_model_records(Purchase)
          end

  context_ "when set to successful" do
  test "increments seller's balance" do
              expect { purchase.update_balance_and_mark_successful! }.to change {
                seller.reload.unpaid_balance_cents
              }.by(purchase.payment_cents)
            end

  test "creates url_redirect" do
              expect { purchase.update_balance_and_mark_successful! }.to change {
                UrlRedirect.count
              }
            end

  test "enqueues a job to send the receipt" do
              purchase.update_balance_and_mark_successful!
              expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id).on("critical")
            end

  test "sends an email to the creator" do
              mail_double = double
              allow(mail_double).to receive(:deliver_later)
              expect(ContactingCreatorMailer).to receive(:notify).and_return(mail_double)

              purchase.update_balance_and_mark_successful!
            end

  test "does not send an email to the creator if notifications are disabled" do
              expect(ContactingCreatorMailer).not_to receive(:mail)
              seller.update!(enable_recurring_subscription_charge_email: true)

              Sidekiq::Testing.inline! do
                purchase.update_balance_and_mark_successful!
              end
            end

  test "does not send a push notification to the creator if notifications are disabled" do
              seller.update!(enable_recurring_subscription_charge_push_notification: true)

              Sidekiq::Testing.inline! do
                purchase.update_balance_and_mark_successful!
              end

              expect(PushNotificationWorker.jobs.size).to eq(0)
            end

  test "bills the original amount even when subscription and variant prices change" do
              category = create(:variant_category, title: "sizes", link:)
              variant = create(:variant, name: "small", price_difference_cents: 300, variant_category: category, max_purchase_count: 5)
              subscription = create(:subscription, link:)
              purchase = build(:purchase, subscription:, is_original_subscription_purchase: true, seller: link.user, link:)
              purchase.variant_attributes << variant
              purchase.save!

              link.update!(price_cents: 9999)
              variant.update!(price_difference_cents: 500)

              travel_to(1.day.from_now) do
                subscription.charge!
              end

              expect(subscription.purchases.size).to be 2
              expect(subscription.purchases.last.price_cents).to be purchase.price_cents
            end

  context_ "monthly charges" do
              let(:link) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :monthly) }

  test "enqueues a recurring charge" do
                freeze_time do
                  purchase.update_balance_and_mark_successful!

                  expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(subscription.id).at(1.month.from_now)
                end
              end
            end

  context_ "yearly charges" do
              let(:link) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :yearly) }

  test "enqueues a recurring charge" do
                freeze_time do
                  purchase.update_balance_and_mark_successful!

                  expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(subscription.id).at(1.year.from_now)
                end
              end
            end

  context_ "quarterly charges" do
              let(:link) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :quarterly) }

  test "enqueues a recurring charge" do
                freeze_time do
                  purchase.update_balance_and_mark_successful!

                  expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(subscription.id).at(3.months.from_now)
                end
              end
            end

  context_ "biannually charges" do
              let(:link) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :biannually) }

  test "enqueues a recurring charge" do
                freeze_time do
                  purchase.update_balance_and_mark_successful!

                  expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(subscription.id).at(6.months.from_now)
                end
              end
            end

  context_ "every two years charges" do
              let(:link) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :every_two_years) }

  test "enqueues a recurring charge" do
                freeze_time do
                  purchase.update_balance_and_mark_successful!

                  expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(subscription.id).at(2.years.from_now)
                end
              end
            end

  test "is successful even if the product is unpublished" do
              link.update_attribute(:purchase_disabled_at, Time.current)
              purchase.update_balance_and_mark_successful!
              expect(purchase.reload.successful?).to be(true)
            end
          end

  context_ "when subscription is invalid" do
            before do
              @seller = create(:user)
              @product = create(:subscription_product, user: @seller)
              @buyer = create(:user)

              @subscription = create(:subscription, link: @product)
              create(:purchase, subscription: @subscription, is_original_subscription_purchase: true)

              @subscription.cancelled_at = Time.current
              @subscription.save
              @purchase = build(:purchase, is_original_subscription_purchase: false, credit_card: create(:credit_card), purchaser: @buyer,
                                           link: @product, seller: @seller, price_cents: 200, fee_cents: 10,
                                           purchase_state: "in_progress", subscription: @subscription.reload)
            end

  test "purchase is not valid" do
              expect(@purchase.save).to be(true)
              expect(@purchase.error_code).to eq "subscription_inactive"
            end
          end
        end

  context_ "for a physical product" do
          let(:seller) { create(:named_seller) }
          let(:product) do
            product = create(:physical_product, user: seller, is_recurring_billing: true, subscription_duration: :monthly)
            product.shipping_destinations.first.update!(country_code: Compliance::Countries::USA.alpha2)
            product
          end
          let(:subscription) { create(:subscription, link: product) }
          let(:original_purchase) do
            create(:physical_purchase, link: product, subscription:, is_original_subscription_purchase: true)
          end

          before do
            expect(original_purchase.shipping_cents).to eq(0) # Creates the original purchase as well
          end

  test "uses the original shipping cost" do
            # Set a new shipping cost
            product.shipping_destinations.first.update!(one_item_rate_cents: 500, multiple_items_rate_cents: 500)

            purchase = create(:physical_purchase, credit_card: create(:credit_card), purchaser: create(:user),
                                                  link: product, seller:, price_cents: 200, fee_cents: 10,
                                                  purchase_state: "in_progress", subscription:)
            purchase.process!

            expect(purchase.shipping_cents).to eq(0)
          end
        end
      end

  context_ "with dollars and cents price difference" do
        before do
          @buyer = create(:user)
          @seller = create(:user)
          @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :monthly)
          @subscription = create(:subscription, link: @product)
          @purchase = create(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                        link: @product, seller: @seller, price_cents: 250, subscription: @subscription, purchase_state: "in_progress")
          expect(@purchase.update_balance_and_mark_successful!).to be(true)
        end

  test "recurring charges are valid" do
          @recurring_charge = build(:purchase, is_original_subscription_purchase: false, credit_card: create(:credit_card), purchaser: @buyer,
                                               link: @product, seller: @seller, price_cents: 250,
                                               subscription: @subscription, purchase_state: "in_progress")
          @recurring_charge.process!
          expect(@recurring_charge.errors.present?).to be(false)
          expect(@recurring_charge.update_balance_and_mark_successful!).to be(true)
        end
      end
    end
  end
end
