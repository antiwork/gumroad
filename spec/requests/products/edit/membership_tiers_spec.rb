# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Product Edit Memberships", type: :system, js: true) do
  include ProductTieredPricingHelpers
  include ProductEditPageHelpers

  def reorder_rows(row:, place_before:)
    row.find("[aria-grabbed='false']").drag_to place_before
  end

  let(:seller) { create(:named_seller) }

  include_context "with switching account to user as admin for seller"

  describe "memberships" do
    before do
      @product = create(:membership_product, user: seller)
      create(:membership_purchase, link: @product, variant_attributes: [@product.default_tier])
    end

    it "displays the number of active supporters for each tier", :sidekiq_inline, :elasticsearch_wait_for_refresh do
      visit edit_link_path(@product.unique_permalink)

      expect(tier_rows[0]).to have_text "1 supporter"
    end

    it "allows user to update product" do
      visit edit_link_path(@product.unique_permalink)

      new_name = "Slot machine"
      fill_in("Name", with: new_name, match: :first)
      save_change
      expect(@product.reload.name).to eq new_name
    end

    it "allows creator to update duration" do
      visit edit_link_path(@product.unique_permalink)

      check "Automatically end memberships after a number of months"
      fill_in("Number of months", with: 18)

      expect do
        save_change
      end.to(change { @product.reload.duration_in_months }.to(18))

      uncheck "Automatically end memberships after a number of months"
      expect do
        save_change
      end.to(change { @product.reload.duration_in_months }.to(nil))
    end

    it "allows creator to update duration of a membership product" do
      visit edit_link_path(@product.unique_permalink)

      check "Automatically end memberships after a number of months"
      fill_in("Number of months", with: 18)

      expect do
        save_change
      end.to(change { @product.reload.duration_in_months }.to(18))
    end

    it "allows creator to share all posts with new members" do
      visit edit_link_path(@product.unique_permalink)

      check "New members will get access to all posts you have published"
      expect do
        save_change
      end.to(change { @product.reload.should_show_all_posts }.to(true))
    end

    it "allows creator to enable a free trial and defaults to one week" do
      visit edit_link_path(@product.unique_permalink)

      check "Offer a free trial"

      in_preview do
        expect(page).to have_text "All memberships include a 1 week free trial"
      end

      save_change

      @product.reload
      expect(@product.free_trial_enabled?).to eq true
      expect(@product.free_trial_duration_amount).to eq 1
      expect(@product.free_trial_duration_unit).to eq "week"
    end

    it "allows creator to enable a one month free trial" do
      visit edit_link_path(@product.unique_permalink)

      check "Offer a free trial"
      select "one month", from: "Charge members after"

      in_preview do
        expect(page).to have_text "All memberships include a 1 month free trial"
      end

      save_change

      @product.reload
      expect(@product.free_trial_enabled?).to eq true
      expect(@product.free_trial_duration_amount).to eq 1
      expect(@product.free_trial_duration_unit).to eq "month"
    end

    context "changing an existing free trial" do
      before do
        @product.update!(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: "month")
      end

      it "allows creator to disable a free trial" do
        visit edit_link_path(@product.unique_permalink)

        in_preview do
          expect(page).to have_text "All memberships include a 1 month free trial"
        end

        uncheck "Offer a free trial"

        in_preview do
          expect(page).not_to have_text "All memberships include"
        end

        save_change

        @product.reload
        expect(@product.free_trial_enabled?).to eq false
        expect(@product.free_trial_duration_amount).to be_nil
        expect(@product.free_trial_duration_unit).to be_nil
      end

      it "allows creator to change the free trial duration" do
        visit edit_link_path(@product.unique_permalink)

        select "one week", from: "Charge members after"

        in_preview do
          expect(page).to have_text "All memberships include a 1 week free trial"
        end

        save_change

        @product.reload
        expect(@product.free_trial_enabled?).to eq true
        expect(@product.free_trial_duration_amount).to eq 1
        expect(@product.free_trial_duration_unit).to eq "week"
      end
    end

    describe "cancellation discount" do
      context "when cancellation discounts are enabled" do
        before do
          Feature.activate_user(:cancellation_discounts, seller)
          @product.alive_variants.first.prices.first.update!(price_cents: 500)
        end

        it "allows the seller to create a cancellation discount" do
          visit edit_link_path(@product.unique_permalink)

          find_field("Offer a cancellation discount", checked: false).check
          fill_in "Fixed amount", with: 1

          save_change

          cancellation_discount = @product.cancellation_discount_offer_code
          expect(cancellation_discount.user).to eq seller
          expect(cancellation_discount.products).to eq [@product]
          expect(cancellation_discount.amount_cents).to eq 100
          expect(cancellation_discount.amount_percentage).to be_nil
          expect(cancellation_discount.duration_in_billing_cycles).to be_nil

          refresh

          expect(page).to have_checked_field("Offer a cancellation discount")
          expect(page).to have_field("Fixed amount", with: "1")
          choose "Percentage"
          fill_in "Percentage", with: 10
          save_change

          cancellation_discount.reload
          expect(cancellation_discount).to eq(@product.cancellation_discount_offer_code)
          expect(cancellation_discount.amount_percentage).to eq 10
          expect(cancellation_discount.amount_cents).to be_nil

          refresh

          find_field("Offer a cancellation discount", checked: true).uncheck
          save_change

          expect(@product.cancellation_discount_offer_code).to be_nil
          expect(cancellation_discount.reload).to be_deleted
        end
      end

      context "when cancellation discounts are disabled" do
        it "does not show the cancellation discount selector" do
          visit edit_link_path(@product.unique_permalink)

          expect(page).not_to have_field "Offer a cancellation discount"
        end
      end
    end
  end

  describe "membership tiers" do
    before do
      @product = create(:membership_product, user: seller)
    end

    it "starts out with one tier, named Untitled" do
      visit edit_link_path(@product.unique_permalink)

      expect(tier_rows.size).to eq 1
      expect(tier_rows[0]).to have_text "Untitled"
    end

    it "has a valid share url" do
      first_tier = @product.tier_category.variants.first
      first_tier.update!(name: "First Tier")

      visit edit_link_path(@product.unique_permalink)

      within tier_rows[0] do
        new_window = window_opened_by { click_on "Share" }
        within_window new_window do
          expect(page).to have_text(@product.name)
          expect(page).to have_text(@product.user.name)
          expect(page).to have_radio_button(first_tier.name)
        end
      end
    end

    it "allows to create more tiers" do
      visit edit_link_path(@product.unique_permalink)

      click_on "Add tier"

      within tier_rows[1] do
        fill_in "Name", with: "Premium"
        check "Toggle recurrence option: Monthly"
        fill_in "Amount monthly", with: 3
      end

      save_change

      expect(@product.variant_categories.first.variants.alive.size).to eq 2
      expect(@product.variant_categories.first.variants.alive.last.name).to eq "Premium"
    end

    it "allows to edit quantity limit" do
      visit edit_link_path(@product.unique_permalink)

      within tier_rows[0] do
        fill_in "Maximum number of active supporters", with: "250"
      end

      save_change

      expect(@product.variant_categories.first.variants.alive.first.max_purchase_count).to eq 250
    end

    context "when membership has rich content" do
      let(:membership_product) { create(:membership_product_with_preset_tiered_pricing, user: seller) }

      before do
        create(:rich_content, entity: membership_product.alive_variants.first, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is tier-level rich content 1", "type" => "text" }] }])
        create(:rich_content, entity: membership_product.alive_variants.second, description: [{ "type" => "paragraph", "content" => [{ "text" => "This is tier-level rich content 2", "type" => "text" }] }])
      end

      it "allows deleting a tier with a confirmation dialog" do
        visit edit_link_path(membership_product.unique_permalink)

        within tier_rows[0] do
          click_on "Remove"
        end

        within_modal "Remove First Tier?" do
          expect(page).to have_text("If you delete this tier, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest tier as a fallback. If no tier exists, they will see the product-level content.")
          click_on "No, cancel"
        end

        save_change
        refresh

        expect(membership_product.alive_variants.size).to eq 2

        within tier_rows[0] do
          click_on "Remove"
        end

        within_modal "Remove First Tier?" do
          expect(page).to have_text("If you delete this tier, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest tier as a fallback. If no tier exists, they will see the product-level content.")
          click_on "Yes, remove"
        end

        save_change

        expect(membership_product.alive_variants.pluck(:name)).to contain_exactly("Second Tier")
      end
    end

    context "when setting quantity limit" do
      before do
        tier_category = @product.tier_category
        first_tier = @product.default_tier
        second_tier = create(:variant, variant_category: tier_category, name: "2nd Tier")
        create(:variant_price, variant: second_tier, recurrence: @product.subscription_duration)

        # first tier has 2 active subscriptions, 1 inactive subscription, and 1 non-subscription purchase
        active_subscription = create(:subscription, link: @product)
        active_subscription2 = create(:subscription, link: @product)
        create(:purchase, link: @product, variant_attributes: [first_tier], subscription: active_subscription, is_original_subscription_purchase: true)
        create(:purchase, link: @product, variant_attributes: [first_tier], subscription: active_subscription2, is_original_subscription_purchase: true)
        inactive_subscription = create(:subscription, link: @product, deactivated_at: Time.current)
        create(:purchase, link: @product, variant_attributes: [first_tier], subscription: inactive_subscription, is_original_subscription_purchase: true)
        create(:purchase, link: @product, variant_attributes: [first_tier])

        # second tier has 1 active subscription, 1 inactive subscription, and 1 non-subscription purchase
        active_subscription = create(:subscription, link: @product)
        create(:purchase, link: @product, variant_attributes: [second_tier], subscription: active_subscription, is_original_subscription_purchase: true)
        create(:purchase, link: @product, variant_attributes: [second_tier], subscription: active_subscription2, is_original_subscription_purchase: true)
        inactive_subscription = create(:subscription, link: @product, deactivated_at: Time.current)
        create(:purchase, link: @product, variant_attributes: [second_tier], subscription: inactive_subscription, is_original_subscription_purchase: true)
        create(:purchase, link: @product, variant_attributes: [second_tier])
      end

      it "prohibits setting quantity limit lower than current active subscriptions + non-subscription purchases" do
        visit edit_link_path(@product.unique_permalink)

        within tier_rows[0] do
          fill_in "Maximum number of active supporters", with: "2"
        end

        save_change(expect_message: "You have chosen an amount lower than what you have already sold. Please enter an amount greater than 3.")
        expect(@product.variant_categories.first.variants.alive.first.max_purchase_count).to be_nil
      end

      it "excludes inactive subscriptions and purchases of other tiers from the current purchase count" do
        visit edit_link_path(@product.unique_permalink)

        within tier_rows[0] do
          fill_in "Maximum number of active supporters", with: "3"
        end

        save_change
        expect(@product.variant_categories.first.variants.alive.first.max_purchase_count).to eq 3
      end
    end

    it "allows to re-order tiers" do
      visit edit_link_path(@product.unique_permalink)

      click_on "Add tier"

      within tier_rows[1] do
        fill_in "Name", with: "Second tier"
        check "Toggle recurrence option: Monthly"
        fill_in "Amount monthly", with: 3
      end

      reorder_rows row: tier_rows[0], place_before: tier_rows[1]

      save_change

      expect(@product.tier_category.variants.reload.alive.in_order.pluck(:name)).to eq ["Second tier", "Untitled"]
    end

    it "allows to delete tiers" do
      visit edit_link_path(@product.unique_permalink)

      click_on "Add tier"

      within tier_rows[1] do
        fill_in "Name", with: "New"
        check "Toggle recurrence option: Monthly"
        fill_in "Amount monthly", with: 3
      end

      save_change

      within tier_rows[0] do
        click_on "Remove"
      end

      within_modal "Remove Untitled?" do
        expect(page).to have_text("If you delete this tier, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest tier as a fallback. If no tier exists, they will see the product-level content.")
        click_on "Yes, remove"
      end

      save_change

      expect(@product.variant_categories.first.variants.alive.size).to eq 1
      expect(@product.variant_categories.first.variants.alive.first.name).to eq "New"
    end

    it "does not allow to save with zero tiers" do
      visit edit_link_path(@product.unique_permalink)

      within tier_rows[0] do
        click_on "Remove"
      end

      within_modal "Remove Untitled?" do
        expect(page).to have_text("If you delete this tier, its associated content will be removed as well. Your existing customers who purchased it will see the content from the current cheapest tier as a fallback. If no tier exists, they will see the product-level content.")
        click_on "Yes, remove"
      end

      save_change(expect_message: "Memberships should have at least one tier.")

      expect(@product.variant_categories.first.variants.alive.size).to eq 1
    end

    describe "pricing" do
      it "allows to enable, disable, and change recurrence values for each tier" do
        visit edit_link_path(@product.unique_permalink)

        within tier_rows[0] do
          fill_in "Amount monthly", with: 3

          check "Toggle recurrence option: Quarterly"
          # defaults to monthly x 3
          expect(page).to have_field("Amount quarterly", with: "9")
          fill_in "Amount quarterly", with: 5
        end

        save_change

        expect(tier_pricing_values(@product)).to eq [
          {
            name: "Untitled",
            pwyw: false,
            values: {
              "monthly" => {
                enabled: true,
                price_cents: 300,
                price: "3",
                suggested_price_cents: nil,
              },
              "quarterly" => {
                enabled: true,
                price_cents: 500,
                price: "5",
                suggested_price_cents: nil,
              },
              "biannually" => { enabled: false },
              "yearly" => { enabled: false },
              "every_two_years" => { enabled: false },
            }
          }
        ]

        within tier_rows[0] do
          uncheck "Toggle recurrence option: Quarterly"
          check "Toggle recurrence option: Yearly"
          fill_in "Amount yearly", with: 13
        end

        save_change

        expect(tier_pricing_values(@product)).to eq [
          {
            name: "Untitled",
            pwyw: false,
            values: {
              "monthly" => {
                enabled: true,
                price_cents: 300,
                price: "3",
                suggested_price_cents: nil,
              },
              "quarterly" => { enabled: false },
              "biannually" => { enabled: false },
              "yearly" => {
                enabled: true,
                price_cents: 1300,
                price: "13",
                suggested_price_cents: nil,
              },
              "every_two_years" => { enabled: false },
            }
          }
        ]
      end

      it "does not allow to save if not all tiers have the same recurrences enabled" do
        visit edit_link_path(@product.unique_permalink)

        within tier_rows[0] do
          fill_in "Amount monthly", with: 3
        end

        click_on "Add tier"

        within tier_rows[1] do
          fill_in "Name", with: "Second tier"

          check "Toggle recurrence option: Monthly"
          fill_in "Amount monthly", with: 3

          check "Toggle recurrence option: Quarterly"
          fill_in "Amount quarterly", with: 3
        end

        save_change(expect_message: "All tiers must have the same set of payment options.")
      end

      it "does not allow to save if any tier is missing a price for the product's default recurrence" do
        visit edit_link_path(@product.unique_permalink)

        within tier_rows[0] do
          uncheck "Toggle recurrence option: Monthly"
        end

        save_change(expect_message: "Please provide a price for the default payment option.")
      end

      context "with pay-what-you-want enabled" do
        it "allows to enable pay-what-you-want on a per-tier basis and enter suggested values per each enabled recurrence" do
          visit edit_link_path(@product.unique_permalink)

          within tier_rows[0] do
            fill_in "Amount monthly", with: 3
          end

          click_on "Add tier"

          within tier_rows[1] do
            fill_in "Name", with: "Second tier"

            check "Toggle recurrence option: Monthly"
            fill_in "Amount monthly", with: 5

            check "Allow customers to pay what they want"
            fill_in "Suggested amount monthly", with: 10
          end

          save_change

          expect(tier_pricing_values(@product)).to eq [
            {
              name: "Untitled",
              pwyw: false,
              values: {
                "monthly" => {
                  enabled: true,
                  price_cents: 300,
                  price: "3",
                  suggested_price_cents: nil,
                },
                "quarterly" => { enabled: false },
                "biannually" => { enabled: false },
                "yearly" => { enabled: false },
                "every_two_years" => { enabled: false },
              }
            },
            {
              name: "Second tier",
              pwyw: true,
              values: {
                "monthly" => {
                  enabled: true,
                  price_cents: 500,
                  price: "5",
                  suggested_price_cents: 1000,
                  suggested_price: "10"
                },
                "quarterly" => { enabled: false },
                "biannually" => { enabled: false },
                "yearly" => { enabled: false },
                "every_two_years" => { enabled: false },
              }
            }
          ]
        end

        it "requires that suggested price is >= price" do
          visit edit_link_path(@product.unique_permalink)

          within tier_rows[0] do
            fill_in "Amount monthly", with: 10

            check "Allow customers to pay what they want"
            fill_in "Suggested amount monthly", with: 9
          end

          save_change(expect_message: "The suggested price you entered was too low.")
        end
      end

      it "allows to change default recurrence in settings" do
        visit edit_link_path(@product.unique_permalink)

        within tier_rows[0] do
          check "Toggle recurrence option: Monthly"
          check "Toggle recurrence option: Quarterly"
          fill_in "Amount quarterly", with: 3
        end

        select "every 3 months", from: "Default payment frequency"
        save_change

        expect(@product.reload.subscription_duration).to eq "quarterly"
      end

      describe "applying price changes to existing memberships" do
        let(:tier) { @product.tiers.first }

        it "allows applying price changes to existing memberships on that tier" do
          freeze_time do
            visit edit_link_path(@product.unique_permalink)

            within tier_rows[0] do
              expect(page).not_to have_text "Effective date for existing customers"
              check "Apply price changes to existing customers"
              expect(page).not_to have_status(text: "You have scheduled a pricing update for existing customers on")
              expect(page).to have_text "Effective date for existing customers"
            end
            save_change

            expect(tier.apply_price_changes_to_existing_memberships).to eq true
            expect(tier.subscription_price_change_effective_date).to eq(Date.today + 7)
            expect(tier.subscription_price_change_message).to be_nil
          end
        end

        it "allows setting an effective date and custom message" do
          visit edit_link_path(@product.unique_permalink)
          effective_date = (7.days.from_now + 1.month).to_date.change(day: 12)

          within tier_rows[0] do
            check "Apply price changes to existing customers"
            fill_in "Effective date for existing customers", with: effective_date.strftime("%m%d%Y")
            set_rich_text_editor_input(find("[aria-label='Custom message']"), to_text: "hello")
            sleep(1)
          end

          save_change

          expect(tier.apply_price_changes_to_existing_memberships).to eq true
          expect(tier.subscription_price_change_effective_date).to eq effective_date
          expect(tier.subscription_price_change_message).to eq "<p>hello</p>"
        end

        it "does not allow setting an effective date less than 7 days in the future" do
          visit edit_link_path(@product.unique_permalink)

          within tier_rows[0] do
            check "Apply price changes to existing customers"
            fill_in "Effective date for existing customers", with: "01-01-2020\t"
          end
          expect(page).to have_text "The effective date must be at least 7 days from today"

          expect do
            click_on "Save changes"
            wait_for_ajax
          end.not_to change { tier.reload.subscription_price_change_effective_date }
          expect(page).to have_alert(text: "Validation failed: The effective date must be at least 7 days from today")

          within tier_rows[0] do
            fill_in "Effective date for existing customers", with: "01-01-#{Date.today.year + 2}\t"
          end
          expect(page).not_to have_text "The effective date must be at least 7 days from today"
        end

        it "allows turning off this setting" do
          tier.update!(apply_price_changes_to_existing_memberships: true,
                       subscription_price_change_effective_date: 7.days.from_now.to_date,
                       subscription_price_change_message: "<p>hello this is a description</p>")
          formatted_date = tier.subscription_price_change_effective_date.strftime("%B %-d, %Y")

          visit edit_link_path(@product.unique_permalink)

          within tier_rows[0] do
            expect(page).to have_alert(text: "You have scheduled a pricing update for existing customers on #{formatted_date}")
            uncheck "Apply price changes to existing customers"
            expect(page).not_to have_alert(text: "You have scheduled a pricing update for existing customers on #{formatted_date}")

            # displays the same values upon re-enabling
            check "Apply price changes to existing customers"
            expect(page).to have_alert(text: "You have scheduled a pricing update for existing customers on #{formatted_date}")
            expect(page).to have_field("Effective date for existing customers", with: tier.subscription_price_change_effective_date.iso8601[0..10])
            expect(page).to have_text("hello this is a description")

            uncheck "Apply price changes to existing customers"
          end

          save_change

          tier.reload
          expect(tier.apply_price_changes_to_existing_memberships).to eq false
          expect(tier.subscription_price_change_effective_date).to be_nil
          expect(tier.subscription_price_change_message).to be_nil
        end

        describe "sample email" do
          before { tier.update!(apply_price_changes_to_existing_memberships: true, subscription_price_change_effective_date: 7.days.from_now.to_date) }

          it "allows sending a sample email when no attributes have changed" do
            mail = double("mail")
            expect(mail).to receive(:deliver_later)
            expect(CustomerLowPriorityMailer).to receive(:sample_subscription_price_change_notification).
                                                  with(user: user_with_role_for_seller, tier:, effective_date: tier.subscription_price_change_effective_date,
                                                       recurrence: "monthly", new_price: tier.prices.alive.find_by(recurrence: "monthly").price_cents,
                                                       custom_message: nil).
                                                  and_return(mail)

            visit edit_link_path(@product.unique_permalink)
            within tier_rows[0] do
              click_on "Get a sample"
            end
            expect(page).to have_alert(text: "Email sample sent! Check your email")
          end

          it "includes the edited price, effective date, and custom message if set" do
            effective_date = (7.days.from_now + 1.month).to_date.change(day: 12)
            new_price = 8_00

            mail = double("mail")
            expect(mail).to receive(:deliver_later)
            expect(CustomerLowPriorityMailer).to receive(:sample_subscription_price_change_notification).
                                                  with(user: user_with_role_for_seller, tier:, effective_date: effective_date.to_date,
                                                       recurrence: "monthly", new_price:, custom_message: "<p>hello</p>").
                                                  and_return(mail)

            visit edit_link_path(@product.unique_permalink)
            within tier_rows[0] do
              fill_in "Amount monthly", with: new_price / 100
              fill_in "Effective date for existing customers", with: effective_date.strftime("%m%d%Y")
              set_rich_text_editor_input(find("[aria-label='Custom message']"), to_text: "hello")
              sleep(1)
              click_on "Get a sample"
            end
            expect(page).to have_alert(text: "Email sample sent! Check your email")
          end

          it "defaults to a monthly $10 price if there is no price set" do
            mail = double("mail")
            expect(mail).to receive(:deliver_later)
            expect(CustomerLowPriorityMailer).to receive(:sample_subscription_price_change_notification).
                                                  with(user: user_with_role_for_seller, tier:, effective_date: tier.subscription_price_change_effective_date,
                                                       recurrence: "monthly", new_price: 10_00, custom_message: nil).
                                                  and_return(mail)

            visit edit_link_path(@product.unique_permalink)
            within tier_rows[0] do
              uncheck "Toggle recurrence option: Monthly"
              click_on "Get a sample"
            end
            expect(page).to have_alert(text: "Email sample sent! Check your email")
          end

          it "shows an error message if error is raised", :realistic_error_responses do
            allow(CustomerLowPriorityMailer).to receive(:sample_subscription_price_change_notification).and_raise(StandardError)

            visit edit_link_path(@product.unique_permalink)
            within tier_rows[0] do
              click_on "Get a sample"
            end
            expect(page).to have_alert(text: "Error sending email")
          end
        end
      end
    end
  end
end
