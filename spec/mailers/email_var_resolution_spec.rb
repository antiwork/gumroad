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

    expect(styles.grep(/border-width: 0(;|\z)/)).to be_present
    expect(styles.grep(/border-style: solid; border-width: 0(;|\z)/)).to be_empty
  end

  it "renders the product cell as a table Outlook can lay out" do
    purchase = create(:purchase, link: create(:product))
    mail = CustomerMailer.receipt(purchase.id)
    body = mail.html_part&.decoded || mail.body.decoded
    inlined = Premailer::Rails::CustomizedPremailer.new(body).to_inline_css
    doc = Nokogiri::HTML(inlined)

    table = doc.css("table.product-checkout-cell").first
    expect([table["border"], table["cellpadding"], table["cellspacing"]]).to eq(%w[0 0 0])
    expect(table["style"]).to include("display: table")

    figure = doc.css("table.product-checkout-cell td.figure").first
    expect(figure["width"]).to eq("128")
    expect(figure["style"]).to include("border-width: 0 1px 0 0")

    expect(doc.css("table.product-checkout-cell td.section").first["style"]).to include("display: table-cell")
    expect(doc.css("table.product-checkout-cell tr").first["style"]).to include("border-width: 0")
    expect(doc.css(".product-checkout-cell div").map { |node| node["style"] }).not_to include(a_string_including("display: table-cell"))
  end
end
