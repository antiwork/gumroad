# frozen_string_literal: true

require "spec_helper"

describe "PurchaseSubscription", :vcr do
  include CurrencyHelper
  include ProductsHelper

  def verify_balance(user, expected_balance)
    expect(user.unpaid_balance_cents).to eq expected_balance
  end

  describe "subscriptions" do
    describe "original subscription purchase" do
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
        @buyer = create(:user)
        @purchase = create(:membership_purchase, link: @product, seller: @seller, subscription: @subscription, price_cents: 200, purchase_state: "in_progress")
        @subscription = @purchase.subscription
        @buyer = @purchase.purchaser
      end

      describe "when set to successful" do
        it "increments seller's balance" do
          expect { @purchase.update_balance_and_mark_successful! }.to change {
            @purchase.link.user.reload.unpaid_balance_cents
          }.by(@purchase.payment_cents)
        end

        it "creates url_redirect" do
          expect { @purchase.update_balance_and_mark_successful! }.to change {
            UrlRedirect.count
          }
        end

        describe "subscription jobs" do
          it "enqueues a recurring charge" do
            freeze_time do
              @purchase.update_balance_and_mark_successful!

              expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id).at(1.month.from_now)
            end
          end

          describe "renewal reminders" do
            before { allow(@subscription).to receive(:send_renewal_reminders?).and_return(true) }

            it "schedules a renewal reminder if the billing period is quarterly" do
              freeze_time do
                payment_option = @subscription.last_payment_option
                payment_option.update!(price: @product.prices.find_by(recurrence: "quarterly"))
                reminder_time = 3.months.from_now - BasePrice::Recurrence::RECURRENCE_TO_RENEWAL_REMINDER_EMAIL_DAYS["quarterly"]

                @purchase.update_balance_and_mark_successful!

                expect(RecurringChargeReminderWorker).to have_enqueued_sidekiq_job(@subscription.id).at(reminder_time)
              end
            end

            it "schedules a renewal reminder if the billing period is biannually" do
              freeze_time do
                payment_option = @subscription.last_payment_option
                payment_option.update!(price: @product.prices.find_by(recurrence: "biannually"))
                reminder_time = 6.months.from_now - BasePrice::Recurrence::RECURRENCE_TO_RENEWAL_REMINDER_EMAIL_DAYS["biannually"]

                @purchase.update_balance_and_mark_successful!

                expect(RecurringChargeReminderWorker).to have_enqueued_sidekiq_job(@subscription.id).at(reminder_time)
              end
            end

            it "schedules a renewal reminder if the billing period is yearly" do
              freeze_time do
                payment_option = @subscription.last_payment_option
                payment_option.update!(price: @product.prices.find_by(recurrence: "yearly"))
                reminder_time = 1.year.from_now - BasePrice::Recurrence::RECURRENCE_TO_RENEWAL_REMINDER_EMAIL_DAYS["yearly"]

                @purchase.update_balance_and_mark_successful!

                expect(RecurringChargeReminderWorker).to have_enqueued_sidekiq_job(@subscription.id).at(reminder_time)
              end
            end

            it "schedules a renewal reminder if the billing period is every two years" do
              freeze_time do
                payment_option = @subscription.last_payment_option
                payment_option.update!(price: @product.prices.find_by(recurrence: "every_two_years"))
                reminder_time = 2.years.from_now - BasePrice::Recurrence::RECURRENCE_TO_RENEWAL_REMINDER_EMAIL_DAYS["every_two_years"]

                @purchase.update_balance_and_mark_successful!

                expect(RecurringChargeReminderWorker).to have_enqueued_sidekiq_job(@subscription.id).at(reminder_time)
              end
            end

            it "schedules a renewal reminder if the billing period is monthly" do
              freeze_time do
                payment_option = @subscription.last_payment_option
                payment_option.update!(price: @product.prices.find_by(recurrence: "monthly"))
                reminder_time = 1.month.from_now - BasePrice::Recurrence::RECURRENCE_TO_RENEWAL_REMINDER_EMAIL_DAYS["monthly"]

                @purchase.update_balance_and_mark_successful!

                expect(RecurringChargeReminderWorker).to have_enqueued_sidekiq_job(@subscription.id).at(reminder_time)
              end
            end

            it "does not schedule a renewal reminder irrespective of the billing period if the feature is disabled" do
              allow(@subscription).to receive(:send_renewal_reminders?).and_return(false)

              freeze_time do
                payment_option = @subscription.last_payment_option
                payment_option.update!(price: @product.prices.find_by(recurrence: "quarterly"))

                @purchase.update_balance_and_mark_successful!

                expect(RecurringChargeReminderWorker.jobs.count).to eq(0)
              end
            end
          end

          describe "with shipping information" do
            before do
              @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :monthly, require_shipping: true)
              @subscription = create(:subscription, link: @product)
              @purchase = create(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                            link: @product, seller: @seller, price_cents: 200, fee_cents: 10, purchase_state: "successful",
                                            full_name: "Edgar Gumstein", street_address: "123 Gum Road", country: "USA", state: "CA",
                                            city: "San Francisco", subscription: @subscription, zip_code: "94117")
            end

            it "is valid without shipping information" do
              @recurring_charge = build(:purchase, is_original_subscription_purchase: false, credit_card: create(:credit_card), purchaser: @buyer,
                                                   link: @product, seller: @seller, price_cents: 200, fee_cents: 10,
                                                   purchase_state: "in_progress", subscription: @subscription)
              expect(@recurring_charge.update_balance_and_mark_successful!).to be(true)
            end
          end

          describe "yearly subscriptions" do
            before do
              @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :yearly)
              @subscription = create(:subscription, link: @product)
              @purchase = build(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                           link: @product, seller: @seller, subscription: @subscription, price_cents: 200, fee_cents: 10, purchase_state: "in_progress")
            end

            it "enqueues a recurring charge" do
              mail_double = double
              allow(mail_double).to receive(:deliver_later)
              freeze_time do
                @purchase.update_balance_and_mark_successful!

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id).at(1.year.from_now)
              end
            end
          end

          describe "quarterly subscriptions" do
            before do
              @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :quarterly)
              @subscription = create(:subscription, link: @product)
              @purchase = build(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                           link: @product, seller: @seller, subscription: @subscription, price_cents: 200, fee_cents: 10, purchase_state: "in_progress")
            end

            it "enqueues a recurring charge" do
              mail_double = double
              allow(mail_double).to receive(:deliver_later)
              freeze_time do
                @purchase.update_balance_and_mark_successful!

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id).at(3.months.from_now)
              end
            end
          end

          describe "biannually subscriptions" do
            before do
              @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :biannually)
              @subscription = create(:subscription, link: @product)
              @purchase = build(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                           link: @product, seller: @seller, subscription: @subscription, price_cents: 200, fee_cents: 10, purchase_state: "in_progress")
            end

            it "enqueues a recurring charge" do
              mail_double = double
              allow(mail_double).to receive(:deliver_later)
              freeze_time do
                @purchase.update_balance_and_mark_successful!

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id).at(6.months.from_now)
              end
            end
          end

          describe "every two years subscriptions" do
            before do
              @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :every_two_years)
              @subscription = create(:subscription, link: @product)
              @purchase = build(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                           link: @product, seller: @seller, subscription: @subscription, price_cents: 200, fee_cents: 10, purchase_state: "in_progress")
            end

            it "enqueues a recurring charge" do
              mail_double = double
              allow(mail_double).to receive(:deliver_later)
              freeze_time do
                @purchase.update_balance_and_mark_successful!

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(@subscription.id).at(2.years.from_now)
              end
            end
          end
        end
      end
    end

    describe "recurring subscription purchase" do
      context "for a digital product" do
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

        describe "when set to successful" do
          it "increments seller's balance" do
            expect { purchase.update_balance_and_mark_successful! }.to change {
              seller.reload.unpaid_balance_cents
            }.by(purchase.payment_cents)
          end

          it "creates url_redirect" do
            expect { purchase.update_balance_and_mark_successful! }.to change {
              UrlRedirect.count
            }
          end

          it "enqueues a job to send the receipt" do
            purchase.update_balance_and_mark_successful!
            expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id).on("critical")
          end

          it "sends an email to the creator" do
            mail_double = double
            allow(mail_double).to receive(:deliver_later)
            expect(ContactingCreatorMailer).to receive(:notify).and_return(mail_double)

            purchase.update_balance_and_mark_successful!
          end

          it "does not send an email to the creator if notifications are disabled" do
            expect(ContactingCreatorMailer).to_not receive(:mail)
            seller.update!(enable_recurring_subscription_charge_email: true)

            Sidekiq::Testing.inline! do
              purchase.update_balance_and_mark_successful!
            end
          end

          it "does not send a push notification to the creator if notifications are disabled" do
            seller.update!(enable_recurring_subscription_charge_push_notification: true)

            Sidekiq::Testing.inline! do
              purchase.update_balance_and_mark_successful!
            end

            expect(PushNotificationWorker.jobs.size).to eq(0)
          end

          it "bills the original amount even when subscription and variant prices change" do
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

          describe "monthly charges" do
            let(:link) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :monthly) }

            it "enqueues a recurring charge" do
              freeze_time do
                purchase.update_balance_and_mark_successful!

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(subscription.id).at(1.month.from_now)
              end
            end
          end

          describe "yearly charges" do
            let(:link) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :yearly) }

            it "enqueues a recurring charge" do
              freeze_time do
                purchase.update_balance_and_mark_successful!

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(subscription.id).at(1.year.from_now)
              end
            end
          end

          describe "quarterly charges" do
            let(:link) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :quarterly) }

            it "enqueues a recurring charge" do
              freeze_time do
                purchase.update_balance_and_mark_successful!

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(subscription.id).at(3.months.from_now)
              end
            end
          end

          describe "biannually charges" do
            let(:link) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :biannually) }

            it "enqueues a recurring charge" do
              freeze_time do
                purchase.update_balance_and_mark_successful!

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(subscription.id).at(6.months.from_now)
              end
            end
          end

          describe "every two years charges" do
            let(:link) { create(:product, user: seller, is_recurring_billing: true, subscription_duration: :every_two_years) }

            it "enqueues a recurring charge" do
              freeze_time do
                purchase.update_balance_and_mark_successful!

                expect(RecurringChargeWorker).to have_enqueued_sidekiq_job(subscription.id).at(2.years.from_now)
              end
            end
          end

          it "is successful even if the product is unpublished" do
            link.update_attribute(:purchase_disabled_at, Time.current)
            purchase.update_balance_and_mark_successful!
            expect(purchase.reload.successful?).to be(true)
          end
        end

        describe "when subscription is invalid" do
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

          it "purchase is not valid" do
            expect(@purchase.save).to be(true)
            expect(@purchase.error_code).to eq "subscription_inactive"
          end
        end
      end

      context "for a physical product" do
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

        it "uses the original shipping cost" do
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

    describe "with dollars and cents price difference" do
      before do
        @buyer = create(:user)
        @seller = create(:user)
        @product = create(:product, user: @seller, is_recurring_billing: true, subscription_duration: :monthly)
        @subscription = create(:subscription, link: @product)
        @purchase = create(:purchase, is_original_subscription_purchase: true, credit_card: create(:credit_card), purchaser: @buyer,
                                      link: @product, seller: @seller, price_cents: 250, subscription: @subscription, purchase_state: "in_progress")
        expect(@purchase.update_balance_and_mark_successful!).to be(true)
      end

      it "recurring charges are valid" do
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
