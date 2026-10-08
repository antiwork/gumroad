# frozen_string_literal: true

# The only path that sends notices, so turning the flag off stops all sending with no backlog to cancel.
class SendSignedPiracyNoticesJob
  include Sidekiq::Job
  sidekiq_options retry: false, queue: :low

  def perform
    return unless Feature.active?(PiracyReports::SendService::FLAG)

    PiracyReport.where(state: "signed").find_each do |report|
      PiracyReports::SendService.new(report:).call
    end
  end
end
