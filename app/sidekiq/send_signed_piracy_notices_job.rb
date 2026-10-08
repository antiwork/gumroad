# frozen_string_literal: true

# The only path that sends notices, so turning the flag off stops all sending with no backlog to cancel.
class SendSignedPiracyNoticesJob
  include Sidekiq::Job
  sidekiq_options retry: false, queue: :low

  def perform
    return unless Feature.active?(PiracyReports::SendService::FLAG)

    PiracyReport.where(state: "signed").find_each do |report|
      send_one(report)
    end
  end

  private
    # One report that raises must not stop the rest: find_each would retry it first on every run.
    def send_one(report)
      PiracyReports::SendService.new(report:).call
    rescue StandardError => e
      ErrorNotifier.notify(e, context: { piracy_report_id: report.id })
    end
end
