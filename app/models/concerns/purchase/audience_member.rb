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
    }.compact_blank
  end

  def add_to_audience_member_details
    return unless should_be_audience_member?

    member = AudienceMember.find_or_initialize_by(email:, seller:)
    return if member.details["purchases"]&.any? { _1["id"] == id }
    member.details["purchases"] ||= []
    member.details["purchases"] << audience_member_details
    member.save!
  end

  def remove_from_audience_member_details(email = attributes["email"])
    member = AudienceMember.find_by(email:, seller:)
    return if member.nil?

    member.details["purchases"]&.delete_if { _1["id"] == id }
    member.valid? ? member.save! : member.destroy!
  end

  private
    def update_audience_member_details
      return if !previous_changes.keys.intersect?(%w[can_contact purchase_state stripe_refunded flags chargeback_date email])
      remove_from_audience_member_details(email_previously_was) if email_previously_changed? && !previously_new_record?
      return remove_from_audience_member_details unless should_be_audience_member?

      add_to_audience_member_details
    end
end
