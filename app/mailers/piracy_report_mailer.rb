# frozen_string_literal: true

# Tells the seller their report passed screening and asks them to sign the notice we will send.
class PiracyReportMailer < ApplicationMailer
  layout "layouts/email"

  def signature_request(piracy_report_id)
    @report = PiracyReport.find(piracy_report_id)
    # Closing the account can cancel the report while this mail waits in the queue.
    return unless @report.awaiting_signature?

    @seller = @report.seller
    @product_name = @report.product.name
    @subject = "Review and sign the takedown notice for #{@product_name}"
    @sign_url = piracy_report_url(@report.external_id)

    mail to: @seller.email, subject: @subject
  end

  # The exact text the seller signed, as plain text, so nothing reflows or rewrites it.
  def notice(piracy_report_id)
    @report = find_on_primary(piracy_report_id)

    mail(
      to: @report.sent_to_email,
      cc: @report.last_contact_email,
      from: SUPPORT_EMAIL_WITH_NAME,
      reply_to: @report.reply_to_address,
      subject: "Notice of claimed copyright infringement under 17 U.S.C. § 512(c)(3)"
    ) do |format|
      format.text { render plain: @report.notice_text }
    end
  end

  def notice_sent(piracy_report_id)
    @report = find_on_primary(piracy_report_id)
    @product_name = @report.product.name
    @subject = "We sent your takedown notice for #{@product_name}"
    @report_url = piracy_report_url(@report.external_id)

    mail to: @report.last_contact_email, subject: @subject
  end

  private
    # The send writes these fields just before the mail jobs run; a worker replica may not have them yet.
    def find_on_primary(piracy_report_id)
      ApplicationRecord.connected_to(role: :writing) { PiracyReport.find(piracy_report_id) }
    end
end
