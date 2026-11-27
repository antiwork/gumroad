# frozen_string_literal: true

# TEMPORARY gp#4744 scratch spec: dumps the inlined receipt HTML for a local before/after render
# comparison. Delete before committing.
require "spec_helper"

describe "gp4744 dump" do
  it "writes the inlined receipt" do
    purchase = create(:purchase, link: create(:product_with_pdf_file, thumbnail: create(:thumbnail)))
    mail = CustomerMailer.receipt(purchase.id)
    body = mail.html_part&.decoded || mail.body.decoded
    inlined = Premailer::Rails::CustomizedPremailer.new(body).to_inline_css
    File.write(ENV.fetch("GP4744_OUT"), inlined)
    puts "WROTE #{inlined.bytesize} bytes"
  end
end
