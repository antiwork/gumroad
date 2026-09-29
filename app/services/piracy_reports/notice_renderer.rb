# frozen_string_literal: true

# The text is frozen on the report and digested, so the seller signs exactly what is later sent.
class PiracyReports::NoticeRenderer
  # Bump when the template or the confirmations shown with it change.
  STATEMENT_VERSION = "2026-09-v1"
  MAX_PRODUCT_NAME_LENGTH = 200

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
        recipient_label: recipient_label,
        owner_name: clean(compliance_info.legal_entity_name),
        owner_address_lines: address_lines(compliance_info),
        owner_email: report.seller.email,
        product_name: clean(report.product.name).truncate(MAX_PRODUCT_NAME_LENGTH),
        product_url: report.product.long_url,
        infringing_urls: report.infringing_urls,
        support_email: ApplicationMailer::SUPPORT_EMAIL
      }
    )
  end

  private
    attr_reader :report

    # Built from the reported URL so nothing the agent read on a pirate page reaches the notice.
    def recipient_label
      report.recipient_kind == "host" ? "the hosting provider of #{report.url_host}" : report.url_host
    end

    def address_lines(info)
      [
        info.legal_entity_street_address,
        [info.legal_entity_city, [info.legal_entity_state, info.legal_entity_zip_code].compact_blank.join(" ")].compact_blank.join(", "),
        info.legal_entity_country
      ].map { clean(_1) }.compact_blank
    end

    # Seller-editable text must stay on one line, or a title could open its own numbered section.
    def clean(value)
      value.to_s.squish
    end
end
