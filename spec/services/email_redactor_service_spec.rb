# frozen_string_literal: true

require "spec_helper"

describe EmailRedactorService do
  it "redacts short emails" do
    expect(EmailRedactorService.redact("foo@bar.baz")).to eq("f*o@b**.baz")
  end

  it "redacts 1 char emails" do
    expect(EmailRedactorService.redact("a@b.co")).to eq("a@b.co")
  end

  it "redacts emails with symbols" do
    expect(EmailRedactorService.redact("a-test+with_symbols@valid-domain.com")).to eq("a*****************s@v***********.com")
  end

  it "only keeps the TLD on multi-part TLDs" do
    expect(EmailRedactorService.redact("john@example.co.uk")).to eq("j**n@e*********.uk")
  end
end
