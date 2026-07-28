# frozen_string_literal: true

module Purchase::AudienceMember
  extend ActiveSupport::Concern

  included do
    after_save :update_audience_member_details
    after_destroy :remove_from_audience_member_details
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

  def add_to_audience_member_details
    return unless should_be_audience_member?

    member = AudienceMember.find_or_initialize_by(email:, seller:)
    member.details["purchases"] ||= []
    member.details["purchases"].delete_if { _1["id"] == id }
    member.details["purchases"] << audience_member_details
    member.save!
  end

  def remove_from_audience_member_details(email = attributes["email"])
    member = AudienceMember.find_by(email:, seller:)
    return if member.nil?

    member.details["purchases"]&.delete_if { _1["id"] == id }
    member.valid? ? member.save! : member.destroy!
  end

  # Rebuilds the buyer's whole audience_members row from live purchase/follower/affiliate
  # state, instead of just adding or removing this one purchase from it.
  def rebuild_audience_member_details
    AudienceMember.find_or_initialize_by(email:, seller:).refresh!
  end

  private
    def update_audience_member_details
      return if !previous_changes.keys.intersect?(%w[can_contact purchase_state stripe_refunded flags chargeback_date email])
      remove_from_audience_member_details(email_previously_was) if email_previously_changed? && !previously_new_record?
      # Re-subscribing has to rebuild the buyer's audience_members row from scratch rather than
      # append this single purchase to it.
      #
      # Unsubscribing sets can_contact = false on EVERY purchase row for the (email, seller)
      # pair, and once the last contactable purchase is gone the audience_members row itself is
      # destroyed. Re-subscribing flips those rows back one at a time, and each row's callback
      # only ever knows about itself. Two things then go wrong: a row that is not an audience
      # member in its own right (a subscription renewal charge, which is skipped because only
      # the original purchase represents a subscription) contributes nothing at all, and any
      # purchase that was already contactable is never saved, so it never gets re-added. A buyer
      # can end up with no audience row at all while their subscription keeps billing, which
      # makes them invisible to every post, blast, and workflow the creator sends.
      return rebuild_audience_member_details if resubscribed?
      return remove_from_audience_member_details unless should_be_audience_member?

      add_to_audience_member_details
    end

    # True when this save is what flipped an existing purchase from unsubscribed back to
    # contactable. Excludes brand new rows, whose can_contact is "changed" simply by being set.
    def resubscribed?
      return false if previously_new_record?

      can_contact_previously_changed? && can_contact?
    end
end
