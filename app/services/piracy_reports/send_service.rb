# frozen_string_literal: true

# Sends the signed notice to the host's registered agent, for the seller, with the seller in CC.
# The text and the recipient were both frozen on the row before this ran: nothing here chooses
# either one, so what leaves is what the seller signed.
class PiracyReports::SendService
  # The kill switch. While it is off a signed report waits instead of mailing a real notice.
  FLAG = :piracy_reports_sending

  Result = Struct.new(:report, :errors, keyword_init: true) do
    def success?
      errors.empty?
    end
  end

  def initialize(report:)
    @report = report
  end

  # The state moves inside the lock, so a second request cannot send a second notice. The mail
  # goes out after the transaction commits, the way ScreenService sends the signature request.
  def call
    result = report.with_lock { claim }
    return result unless result.success?

    deliver
  end

  private
    attr_reader :report

    def claim
      errors = gate_errors
      return Result.new(report:, errors:) if errors.any?

      report.assign_attributes(
        final_notice_digest: report.notice_digest,
        sent_at: Time.current,
        sent_to_email: report.recipient_email,
        delivery_status: "sending"
      )
      report.send_notice!
      Result.new(report:, errors: [])
    rescue StateMachines::InvalidTransition => e
      Result.new(report:, errors: [e.message])
    end

    def gate_errors
      errors = []
      errors << "The report is not signed" unless report.signed?
      errors << "Sending is turned off" unless Feature.active?(FLAG)
      errors << "The notice has no recipient" if report.recipient_email.blank?
      errors << "The notice changed after it was signed" unless report.notice_digest.present? && Digest::SHA256.hexdigest(report.notice_text.to_s) == report.notice_digest
      errors
    end

    def deliver
      mail = PiracyReportMailer.takedown_notice(report.id).deliver_now
      report.update!(sent_message_id: mail.message_id, delivery_status: "sent")
      Result.new(report:, errors: [])
    rescue StandardError => e
      # The state stays `sent`, so nothing can be sent twice. A human sees the failure on the record.
      report.update!(delivery_status: "failed")
      Result.new(report:, errors: ["The notice could not be sent: #{e.message}"])
    end
end
