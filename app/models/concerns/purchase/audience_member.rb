# frozen_string_literal: true

module Purchase::AudienceMember
  extend ActiveSupport::Concern

  # Attribute changes that can alter whether this purchase belongs in the audience or what its
  # audience_member_details contain.
  AUDIENCE_MEMBER_WATCHED_ATTRIBUTES = %w[can_contact purchase_state stripe_refunded flags chargeback_date email].freeze

  included do
    after_save :schedule_audience_member_refresh_if_changed
    after_destroy :schedule_audience_member_refresh
  end

  def should_be_audience_member?
    result = can_contact?
    result &= purchase_state.in?(%w[successful gift_receiver_purchase_successful not_charged])
    result &= !is_gift_sender_purchase?
    result &= EmailFormatValidator.valid?(email)
    if subscription_id.nil?
      result &= !stripe_refunded?
      result &= chargeback_date.blank? || chargeback_reversed?
    else
      result &= is_original_subscription_purchase?
      result &= !is_archived_original_subscription_purchase?
      result &= subscription.deactivated_at.nil?
      result &= !subscription.is_test_subscription?
    end
    result
  end

  def audience_member_details
    {
      id:,
      country: country_or_ip_country.to_s,
      created_at: created_at.iso8601,
      product_id: link_id,
      variant_ids: variant_attributes.ids,
      price_cents:,
      subscription_cancelled: subscription&.cancelled_at.present?,
      license_uses: license&.uses,
    }.compact_blank
  end

  # The audience_members projection is rebuilt out of band: writing it inline made checkout and
  # unsubscribe wait on the buyer's row lock (up to innodb_lock_wait_timeout) whenever two
  # requests touched the same (email, seller) pair. The 1-minute delay keeps the job from
  # running before this transaction commits; the job's unique lock coalesces bursts.
  def schedule_audience_member_refresh(email = self.email)
    RefreshAudienceMemberJob.perform_in(1.minute, email, seller_id)
  end

  # Synchronous rebuild for console/repair use (see
  # Onetime::RepairMissingSubscriptionAudienceMembers). Request paths use
  # schedule_audience_member_refresh instead.
  def rebuild_audience_member_details
    AudienceMember.find_or_initialize_by(email:, seller:).refresh!
  end

  private
    def schedule_audience_member_refresh_if_changed
      return if !previous_changes.keys.intersect?(AUDIENCE_MEMBER_WATCHED_ATTRIBUTES)

      schedule_audience_member_refresh(email_previously_was) if email_previously_changed? && !previously_new_record?
      schedule_audience_member_refresh
    end
end
