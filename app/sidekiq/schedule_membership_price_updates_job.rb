# frozen_string_literal: true

class ScheduleMembershipPriceUpdatesJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(tier_id)
    tier = Variant.find(tier_id)
    return unless tier.apply_price_changes_to_existing_memberships?

    product = tier.link
    return unless product.is_tiered_membership?

    product.subscriptions.includes(original_purchase: :variant_attributes).find_each do |subscription|
      next if subscription.charges_completed? || subscription.deactivated?
      next unless subscription.for_tier?(tier)
      effective_on = subscription.end_time_of_subscription
      effective_on += subscription.period until effective_on >= tier.subscription_price_change_effective_date

      original_purchase = subscription.original_purchase
      plan_change = subscription.latest_plan_change
      selected_tier = plan_change.present? ? plan_change.tier : subscription.tier
      next if selected_tier.id != tier_id

      selected_recurrence = plan_change.present? ? plan_change.recurrence : subscription.recurrence

      existing_price = plan_change.present? ? plan_change.perceived_price_cents : original_purchase.displayed_price_cents
      new_price = nil
      if plan_change.present?
        ActiveRecord::Base.transaction do
          new_product_price = subscription.link.prices.is_buy.alive.find_by(recurrence: plan_change.recurrence) ||
            subscription.link.prices.is_buy.find_by(recurrence: plan_change.recurrence) # use live price if exists, else deleted price

          begin
            subscription.update_current_plan!(
              new_variants: [plan_change.tier],
              new_price: new_product_price,
              new_quantity: plan_change.quantity,
              is_applying_plan_change: true,
              skip_preparing_for_charge: true,
            )
          rescue Subscription::UpdateFailed => e
            Rails.logger.info("ScheduleMembershipPriceUpdatesJob failed for #{subscription.id}: #{e.class} (#{e.message})")
            raise ActiveRecord::Rollback
          end
          new_price = subscription.reload.original_purchase.displayed_price_cents
          raise ActiveRecord::Rollback
        end
      else
        ActiveRecord::Base.transaction do
          original_purchase.set_price_and_rate
          new_price = original_purchase.displayed_price_cents
          raise ActiveRecord::Rollback
        end
      end

      if new_price.nil? || new_price <= 0 || existing_price == new_price
        reason = if new_price.nil?
          "nil price"
        elsif new_price <= 0
          "zero or negative price (#{new_price})"
        else
          "price has not changed"
        end
        Bugsnag.notify("Not adding a plan change for membership price change - subscription_id: #{subscription.id} - reason: #{reason}")
        next
      end

      Rails.logger.info("Adding a plan change for membership price change - subscription_id: #{subscription.id}, tier_id: #{tier_id}, effective_on: #{effective_on}")
      new_plan_change = subscription.subscription_plan_changes.create!(tier: selected_tier,
                                                                       recurrence: selected_recurrence,
                                                                       perceived_price_cents: new_price,
                                                                       for_product_price_change: true,
                                                                       effective_on:)
      subscription.subscription_plan_changes.for_product_price_change.alive.where.not(id: new_plan_change.id).each(&:mark_deleted!)
    end
  end
end
