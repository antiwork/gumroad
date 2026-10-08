# frozen_string_literal: true

# Sends a signed notice to the host's registry contact, with the seller in CC. Nothing here chooses
# the text or the recipient: both were frozen on the report before signing.
class PiracyReports::SendService
  FLAG = :piracy_reports_sending

  Result = Struct.new(:report, :errors, keyword_init: true) do
    def success?
      errors.empty?
    end
  end

  def initialize(report:)
    @report = report
  end

  # The state moves under the lock, so a second run cannot send a second notice. The mail goes out
  # after the lock, the way ScreenService sends the signature request.
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
        reply_token: SecureRandom.alphanumeric(PiracyReport::REPLY_TOKEN_LENGTH).downcase,
        sent_at: Time.current,
        sent_to_email: report.recipient_email,
        last_contact_email: report.seller.email
      )
      report.send_notice!
      Result.new(report:, errors: [])
    end

    def gate_errors
      errors = []
      errors << "Sending is turned off" unless Feature.active?(FLAG)
      errors << "The report is not signed" unless report.signed?
      errors << "The notice changed after it was signed" unless report.notice_digest.present? && Digest::SHA256.hexdigest(report.notice_text.to_s) == report.notice_digest
      errors << "The signature is not under the current confirmations" unless report.signature_statement_version == PiracyReport::SIGNATURE_STATEMENT_VERSION
      errors << "The host's registry contact changed after screening" unless registry_contact_unchanged?
      errors
    end

    def registry_contact_unchanged?
      entry = PiracyReports::RecipientRegistry.for_host(report.url_host)
      entry.present? && entry.email == report.recipient_email && entry.name == report.recipient_name
    end

    # The state stays `sent` when delivery raises, so the notice is never sent twice; the failure
    # puts the report in the person queue instead.
    def deliver
      mail = PiracyReportMailer.notice(report.id).deliver_now
      # RescueSmtpErrors makes deliver_now return a rejected send's exception instead of raising it.
      raise mail if mail.is_a?(Exception)

      report.update!(sent_message_id: mail.message_id)
      PiracyReportMailer.notice_sent(report.id).deliver_later
      Result.new(report:, errors: [])
    rescue StandardError => e
      report.update!(delivery_failed_at: Time.current)
      ErrorNotifier.notify(e, context: { piracy_report_id: report.id })
      Result.new(report:, errors: ["The notice could not be sent: #{e.message}"])
    end
end
