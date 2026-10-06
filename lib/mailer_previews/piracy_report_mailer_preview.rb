# frozen_string_literal: true

class PiracyReportMailerPreview < ActionMailer::Preview
  def signature_request
    PiracyReportMailer.signature_request(PiracyReport.last&.id)
  end
end
