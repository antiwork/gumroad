# frozen_string_literal: true

# Helper methods for testing managing subscription functionality
module ManageSubscriptionHelpers
  def shared_setup(originally_subscribed_at: nil, recommendable: false)
    @email = generate(:email)
    @user = create(:user, email: @email)
    @credit_card = create(:credit_card, user: @user)
    @user.update!(credit_card: @credit_card)

    @product = create(:membership_product_with_preset_tiered_pricing, recommendable ? :recommendable : nil, recurrence_price_values: [
                        {
                          BasePrice::Recurrence::MONTHLY => { enabled: true, price: 3 },
                          BasePrice::Recurrence::QUARTERLY => { enabled: true, price: 5.99 },
                          BasePrice::Recurrence::YEARLY => { enabled: true, price: 10 },
                          BasePrice::Recurrence::EVERY_TWO_YEARS => { enabled: true, price: 18 },
                        },
                        # more expensive tier
                        {
                          BasePrice::Recurrence::MONTHLY => { enabled: true, price: 5 },
                          BasePrice::Recurrence::QUARTERLY => { enabled: true, price: 10.50 },
                          BasePrice::Recurrence::YEARLY => { enabled: true, price: 20 },
                          BasePrice::Recurrence::EVERY_TWO_YEARS => { enabled: true, price: 35 },
                        },
                        # cheaper tier
                        {
                          BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2.50 },
                          BasePrice::Recurrence::QUARTERLY => { enabled: true, price: 4 },
                          BasePrice::Recurrence::YEARLY => { enabled: true, price: 7.75 },
                          BasePrice::Recurrence::EVERY_TWO_YEARS => { enabled: true, price: 15 },
                        },
                      ])
    @monthly_product_price = @product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::MONTHLY)
    @quarterly_product_price = @product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::QUARTERLY)
    @yearly_product_price = @product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
    @every_two_years_product_price = @product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS)

    # Tiers
    @original_tier = @product.default_tier
    @original_tier_monthly_price = @original_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::MONTHLY)
    @original_tier_quarterly_price = @original_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::QUARTERLY)
    @original_tier_yearly_price = @original_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::YEARLY)
    @original_tier_every_two_years_price = @original_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS)

    @new_tier = @product.tiers.where.not(id: @original_tier.id).take!
    @new_tier_monthly_price = @new_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::MONTHLY)
    @new_tier_quarterly_price = @new_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::QUARTERLY)
    @new_tier_yearly_price = @new_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::YEARLY)
    @new_tier_every_two_years_price = @new_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::EVERY_TWO_YEARS)

    @lower_tier = @product.tiers.where.not(id: [@original_tier.id, @new_tier.id]).take!
    @lower_tier_quarterly_price = @lower_tier.prices.alive.find_by(recurrence: BasePrice::Recurrence::QUARTERLY)

    @originally_subscribed_at = originally_subscribed_at || Time.utc(2020, 04, 01) # default to a month with 30 days for easier calculation

    # Prorated upgrade prices, 1 month into a quarterly membership
    # Apply 66%, or $3.95, prorated discount
    @new_tier_yearly_upgrade_cost_after_one_month = 16_05 # $20 - $3.95
    @new_tier_quarterly_upgrade_cost_after_one_month = 6_55 # 10.50 - $3.95
    @original_tier_yearly_upgrade_cost_after_one_month = 6_05 # 10 - $3.95
  end

  def setup_subscription_with_vat(vat_id: nil)
    shared_setup
    create(:zip_tax_rate, country: "FR", zip_code: nil, state: nil, combined_rate: 0.20, is_seller_responsible: false)

    travel_to(@originally_subscribed_at) do
      purchase_params = {
        email: @user.email,
        country: "FR",
        sales_tax_country_code_election: "FR",
        is_original_subscription_purchase: true,
        ip_address: "2.16.255.255",
        ip_country: "France",
      }
      purchase_params[:business_vat_id] = vat_id if vat_id.present?
      params = {
        variant_ids: [@original_tier.external_id],
        price_id: @quarterly_product_price.external_id,
        purchase: purchase_params,
      }

      @original_purchase, error = Purchase::CreateService.new(
        product: @product,
        params:,
        buyer: @user
      ).perform

      expect(error).to be_nil
      expect(@original_purchase.purchase_state).to eq "successful"
    end

    @subscription = @original_purchase.subscription
  end

  def setup_subscription(pwyw: false, with_product_files: false, originally_subscribed_at: nil, recurrence: BasePrice::Recurrence::QUARTERLY, free_trial: false, offer_code: nil, was_product_recommended: false, discover_fee_per_thousand: nil, is_multiseat_license: false, quantity: 1, gift: nil)
    shared_setup(recommendable: was_product_recommended)
    @product.update!(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week) if free_trial
    @product.update!(discover_fee_per_thousand:) if discover_fee_per_thousand
    @product.update!(is_multiseat_license: quantity > 1 || is_multiseat_license)

    create(:product_file, link: @product) if with_product_files

    # Subscription
    @subscription = create_subscription(
      product_price: @product.prices.alive.find_by!(recurrence:),
      tier: @original_tier,
      tier_price: @original_tier.prices.alive.find_by(recurrence:),
      pwyw:,
      with_product_files:,
      offer_code:,
      was_product_recommended:,
      quantity:,
      gift:
    )
    @subscription.update!(flat_fee_applicable: false)
    @original_purchase = @subscription.original_purchase
    @original_purchase.update!(gift_given: gift, is_gift_sender_purchase: true) if gift

    if is_multiseat_license
      create(:license, purchase: @subscription.original_purchase)
      @product.update(is_licensed: true)
    end
  end

  def create_subscription(product_price:, tier:, tier_price:, pwyw: false, with_product_files: false, offer_code: nil, was_product_recommended: false, quantity: 1, gift: nil)
    subscription = create(:subscription,
                          user: gift ? nil : @user,
                          link: @product,
                          price: product_price,
                          credit_card: gift ? nil : @credit_card,
                          free_trial_ends_at: @product.free_trial_enabled && !gift ? @originally_subscribed_at + @product.free_trial_duration : nil)

    travel_to(@originally_subscribed_at) do
      price = tier_price.price_cents
      price -= offer_code.amount_off(tier_price.price_cents) if offer_code.present?

      original_purchase = create(:purchase,
                                 is_original_subscription_purchase: true,
                                 link: @product,
                                 subscription:,
                                 variant_attributes: [tier],
                                 price_cents: price * quantity,
                                 quantity:,
                                 credit_card: @credit_card,
                                 purchaser: @user,
                                 email: @user.email,
                                 is_free_trial_purchase: gift ? false : @product.free_trial_enabled?,
                                 offer_code:,
                                 purchase_state: "in_progress",
                                 was_product_recommended:)
      if pwyw
        tier.update!(customizable_price: true)
        original_purchase.perceived_price_cents = tier_price.price_cents + 1_00
      end

      if was_product_recommended
        create(:recommended_purchase_info_via_discover, purchase: original_purchase, discover_fee_per_thousand: @product.discover_fee_per_thousand)
      end

      original_purchase.process!
      original_purchase.update_balance_and_mark_successful!

      subscription.reload
      expect(original_purchase.purchase_state).to eq @product.free_trial_enabled? ? "not_charged" : "successful"
      if pwyw
        expect(original_purchase.displayed_price_cents).to eq price + 1_00
      else
        expect(original_purchase.displayed_price_cents).to eq price * quantity
      end
    end

    subscription
  end

  def change_product_currency_to(currency)
    @product.update!(price_currency_type: currency)
    @product.prices.update_all(currency:)
    @product.tiers.map { |t| t.prices.update_all(currency:) }
  end

  def set_tier_price_difference_below_min_upgrade_price(currency)
    old_price_cents = @original_tier_quarterly_price.price_cents
    # set new selection's price to be greater than original price, but by
    # less than the CAD minimum product price
    @min_price_in_currency = min_price_for(currency)
    @new_price = old_price_cents + (@min_price_in_currency / 2)
    @new_tier_quarterly_price.update!(price_cents: @new_price)
  end

  def setup_subscription_token(subscription: nil)
    (subscription || @subscription).update!(token: "valid_token", token_expires_at: Subscription::TOKEN_VALIDITY.from_now)
  end
end
