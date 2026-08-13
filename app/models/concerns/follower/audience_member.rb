# frozen_string_literal: true

module Follower::AudienceMember
  extend ActiveSupport::Concern

  included do
    after_save :update_audience_member_details
    after_destroy :remove_from_audience_member_details
  end

  def should_be_audience_member?
    confirmed_at.present? && EmailFormatValidator.valid?(email)
  end

  def audience_member_details
    { id:, created_at: }
  end

  private
    def update_audience_member_details
      return unless confirmed_at_previously_changed? || email_previously_changed?
      remove_from_audience_member_details(email_previously_was) if email_previously_changed? && !previously_new_record?
      return remove_from_audience_member_details unless should_be_audience_member?

      retried ||= false
      # See Purchase::AudienceMember#add_to_audience_member_details for the race, the `.lock`
      # requirement on retry, and the `retried ||=` gotcha.
      member = retried ? AudienceMember.lock.find_or_initialize_by(email:, seller: user) : AudienceMember.find_or_initialize_by(email:, seller: user)
      member.details["follower"] = audience_member_details
      member.save!
    rescue ActiveRecord::RecordNotUnique
      raise if retried
      retried = true
      retry
    rescue ActiveRecord::LockWaitTimeout => e
      # See Purchase::AudienceMember#add_to_audience_member_details — do not retry.
      ErrorNotifier.notify(e)
      RefreshAudienceMemberJob.perform_in(1.minute, email, followed_id)
    end

    def remove_from_audience_member_details(email = attributes["email"])
      member = AudienceMember.find_by(email:, seller: user)
      return if member.nil?

      member.details.delete("follower")
      member.valid? ? member.save! : member.destroy!
    rescue ActiveRecord::LockWaitTimeout => e
      ErrorNotifier.notify(e)
      RefreshAudienceMemberJob.perform_in(1.minute, email, followed_id)
    end
end
