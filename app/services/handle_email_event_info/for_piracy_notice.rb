# frozen_string_literal: true

class HandleEmailEventInfo::ForPiracyNotice
  def self.perform(email_event_info)
    report = PiracyReport.find_by(id: email_event_info.piracy_report_id)
    return if report.blank?
    # SendGrid reports each recipient separately; only the host's copy says whether the notice arrived.
    return unless email_event_info.email.to_s.casecmp?(report.sent_to_email.to_s)

    case email_event_info.type
    when EmailEventInfo::EVENT_DELIVERED
      report.update!(delivered_at: email_event_info.created_at || Time.current) if report.delivered_at.nil?
    when EmailEventInfo::EVENT_BOUNCED
      report.update!(delivery_failed_at: email_event_info.created_at || Time.current) if report.delivery_failed_at.nil?
    end
  end
end
