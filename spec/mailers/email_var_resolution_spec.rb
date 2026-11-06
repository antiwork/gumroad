# frozen_string_literal: true

require "spec_helper"

describe "Receipt email custom properties" do
  it "leaves no var() in the inlined receipt" do
    purchase = create(:purchase, link: create(:product))
    mail = CustomerMailer.receipt(purchase.id)
    body = mail.html_part&.decoded || mail.body.decoded
    inlined = Premailer::Rails::CustomizedPremailer.new(body).to_inline_css
    styles = Nokogiri::HTML(inlined).css("[style]").map { |node| node["style"] }.join(";")

    expect(styles).to include("font-family")
    expect(styles).not_to include("var(")
  end
end
