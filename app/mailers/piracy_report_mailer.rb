# frozen_string_literal: true

# Tells the seller their report passed screening and asks them to sign the notice we will send.
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
end
