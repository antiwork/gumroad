# frozen_string_literal: true

# Talks to the seller about their report, and sends the notice itself once the seller has signed it.
class PiracyReportMailer < ApplicationMailer
  layout "layouts/email"

  def signature_request(piracy_report_id)
    @report = PiracyReport.find(piracy_report_id)
    @seller = @report.seller
    @product_name = @report.product.name
    @subject = "Review and sign the takedown notice for #{@product_name}"
    @sign_url = piracy_report_url(@report.external_id)

    mail to: @seller.email, subject: @subject
  end

  # The notice, sent to the host's agent on the seller's behalf, with the seller in CC. The body is
  # the exact text the seller signed, so it goes out as plain text and nothing reflows or rewrites it.
  def takedown_notice(piracy_report_id)
    @report = PiracyReport.find(piracy_report_id)

    mail(
      to: @report.sent_to_email,
      cc: @report.seller.email,
      from: ApplicationMailer::SUPPORT_EMAIL_WITH_NAME,
      reply_to: @report.reply_to_address,
      subject: "Notice of claimed copyright infringement under 17 U.S.C. § 512(c)(3)",
      layout: false
    ) do |format|
      format.text { render plain: @report.notice_text }
    end
  end

  # Tells the seller a site answered, and what the answer starts.
  def counter_notice_received(piracy_report_id)
    @report = PiracyReport.find(piracy_report_id)
    @seller = @report.seller
    @product_name = @report.product.name
    @subject = "A site responded to your takedown notice for #{@product_name}"

    mail to: @seller.email, subject: @subject
  end
end
