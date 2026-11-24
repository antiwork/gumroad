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

  it "leaves no zero-width border with a visible style in the inlined receipt" do
    purchase = create(:purchase, link: create(:product))
    mail = CustomerMailer.receipt(purchase.id)
    body = mail.html_part&.decoded || mail.body.decoded
    inlined = Premailer::Rails::CustomizedPremailer.new(body).to_inline_css
    styles = Nokogiri::HTML(inlined).css("[style]").map { |node| node["style"] }

    expect(styles.grep(/border(-\w+)?-style: none/)).to be_present
    expect(styles.grep(/border-style: solid; border-width: 0(;|\z)/)).to be_empty
    # A side longhand is skipped by EmailZeroWidthBorderNormalizer, so the stylesheet may not leave one behind.
    zero_width_solid = styles.select { |style| style.match?(/border(-\w+)?-style: solid/) && style.match?(/border(-\w+)?-width: 0(;|\z)/) }
    expect(zero_width_solid).to be_empty
  end

  it "renders the product row as a table Outlook can lay out" do
    purchase = create(:purchase, link: create(:product))
    mail = CustomerMailer.receipt(purchase.id)
    body = mail.html_part&.decoded || mail.body.decoded
    inlined = Premailer::Rails::CustomizedPremailer.new(body).to_inline_css
    doc = Nokogiri::HTML(inlined)

    table = doc.at_css("table.product")
    expect([table["role"], table["border"], table["cellpadding"], table["cellspacing"], table["width"]]).to eq(%w[presentation 0 0 0 100%])

    thumbnail = table.at_css("td.product-thumbnail")
    expect(thumbnail["width"]).to eq("64")
    image = thumbnail.at_css("img")
    expect([image["width"], image["height"]]).to eq(%w[64 64])

    expect(table.css("td").map { |cell| cell["style"] }).to all(include("border-style: none"))
    expect(table.css("[style]").map { |node| node["style"] }).not_to include(a_string_matching(/display: table/))
  end
end
