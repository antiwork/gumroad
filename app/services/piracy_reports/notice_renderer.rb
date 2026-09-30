# frozen_string_literal: true

# The text is frozen on the report and digested, so the seller signs exactly what is later sent.
class PiracyReports::NoticeRenderer
  def initialize(report)
    @report = report
  end

  def call
    compliance_info = report.seller.alive_user_compliance_info

    ApplicationController.render(
      template: "piracy_reports/notice",
      formats: [:text],
      layout: false,
      locals: {
        recipient_name: clean(report.recipient_name),
        owner_name: clean(compliance_info.legal_entity_name),
        owner_email: report.seller.email,
        gumroad_address: GumroadAddress.full,
        product_name: clean(report.product.name),
        product_url: report.product.long_url,
        infringing_url: report.url,
        support_email: ApplicationMailer::SUPPORT_EMAIL
      }
    )
  end

  private
    attr_reader :report

    # Seller-editable text must stay on one line, or a title could open its own numbered section.
    def clean(value)
      value.to_s.squish
    end
end
