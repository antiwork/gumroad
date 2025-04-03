# frozen_string_literal: true

class AffiliateRequestMailerPreview < ActionMailer::Preview
  def notify_requester_of_request_submission
    AffiliateRequestMailer.notify_requester_of_request_submission(AffiliateRequest.last&.id)
  end

  def notify_seller_of_new_request
    AffiliateRequestMailer.notify_seller_of_new_request(AffiliateRequest.last&.id)
  end

  def notify_requester_of_request_approval
    AffiliateRequestMailer.notify_requester_of_request_approval(AffiliateRequest.last&.id)
  end

  def notify_unregistered_requester_of_request_approval
    AffiliateRequestMailer.notify_unregistered_requester_of_request_approval(AffiliateRequest.last&.id)
  end

  def notify_requester_of_ignored_request
    AffiliateRequestMailer.notify_requester_of_ignored_request(AffiliateRequest.last&.id)
  end
end
