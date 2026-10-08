# frozen_string_literal: true

# Tells the seller their report passed screening and asks them to sign the notice we will send.
class PiracyReportMailer < ApplicationMailer
  layout "layouts/email"

  def signature_request(piracy_report_id)
    @report = PiracyReport.find(piracy_report_id)
    # The mail is queued while the report waits for a signature, and closing the account cancels the
    # report in the meantime. Check again here rather than ask a closed account to sign a report
    # that is no longer open.
    return unless @report.awaiting_signature?

    @seller = @report.seller
    @product_name = @report.product.name
    @subject = "Review and sign the takedown notice for #{@product_name}"
    @sign_url = piracy_report_url(@report.external_id)

    mail to: @seller.email, subject: @subject
  end
end
