# frozen_string_literal: true

module Affiliate::AudienceMember
  extend ActiveSupport::Concern

  included do
    after_save :update_audience_member_details
    after_destroy :remove_from_audience_member_details
  end

  def update_audience_member_with_added_product(product_or_id)
    return unless persisted? && type == "DirectAffiliate" && should_be_audience_member?

    product_id = product_or_id.is_a?(Link) ? product_or_id.id : product_or_id
    member = AudienceMember.find_or_initialize_by(email: affiliate_user.email, seller:)
    return if member.details["affiliates"]&.any? { _1["id"] == id && _1["product_id"] == product_id }

    member.details["affiliates"] ||= []
    member.details["affiliates"] << audience_member_details(product_id:)
    member.save!
  end

  def update_audience_member_with_removed_product(product_or_id)
    return unless persisted? && type == "DirectAffiliate" && should_be_audience_member?

    product_id = product_or_id.is_a?(Link) ? product_or_id.id : product_or_id
    member = AudienceMember.find_by(email: affiliate_user.email, seller:)
    return if member.nil?

    member.details["affiliates"]&.delete_if { _1["id"] == id && _1["product_id"] == product_id }
    member.valid? ? member.save! : member.destroy!
  end

  def should_be_audience_member?
    type == "DirectAffiliate" && alive? && send_posts && seller.present? && EmailFormatValidator.valid?(affiliate_user&.email)
  end

  def audience_member_details(product_id:)
    { id:, product_id:, created_at: created_at.iso8601 }
  end

  private
    def update_audience_member_details
      return unless type == "DirectAffiliate"
      return if !previous_changes.keys.intersect?(%w[deleted_at flags])
      return remove_from_audience_member_details unless should_be_audience_member?
      return unless deleted_at_previously_changed?
      return if product_affiliates.empty?

      member = AudienceMember.find_or_initialize_by(email: affiliate_user.email, seller:)
      member.details["affiliates"] ||= []
      product_affiliates.each do
        member.details["affiliates"] << audience_member_details(product_id: _1.link_id)
      end
      member.save!
    end

    def remove_from_audience_member_details
      return unless type == "DirectAffiliate"
      member = AudienceMember.find_by(email: affiliate_user.email, seller:)
      return if member.nil?

      member.details["affiliates"]&.delete_if { _1["id"] == id }
      member.valid? ? member.save! : member.destroy!
    end
end
