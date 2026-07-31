# frozen_string_literal: true

require "spec_helper"

# §27.5 makes a material change effective for an existing Registered User on the EARLIER of 30 days
# after posting or 30 days after an emailed notice, so the posting date alone fixes the date and a
# later email cannot pull it in. Deriving the assertion from Last Updated rather than pinning a
# literal is what makes a future Terms edit redden here instead of shipping a stale notice.
#
# Ruby's \s does not match U+00A0, and this file's hand-maintained header markup mixes both.
describe "app/views/home/terms.html.erb amendment notice" do
  SPACE = "[[:space:]\u00a0]"

  let(:source) { Rails.root.join("app/views/home/terms.html.erb").read }

  let(:header) do
    source[/description:#{SPACE}*"(.*?)"#{SPACE}*%>/mo, 1] ||
      raise("could not find the header description passed to home/shared/header")
  end

  # No /o here: the interpolation varies per call, and /o would cache the FIRST label's pattern and
  # silently answer every later call with it.
  def date_after(label)
    raw = header[/#{Regexp.escape(label)}:#{SPACE}*([A-Z][a-z]+#{SPACE}+\d{1,2},#{SPACE}*\d{4})/, 1] ||
      raise("header carries no #{label}: #{header.inspect}")
    Date.parse(raw.gsub(/#{SPACE}+/o, " "))
  end

  it "parses the header it is asserting about" do
    expect(header).to include("Effective Date", "Last Updated Date")
  end

  # The Agreement's own Effective Date is load-bearing elsewhere — §25's arbitration clause reaches
  # "disputes that arose before the effective date of the Agreement" — so a per-amendment date must
  # be added alongside it, never written over it.
  it "leaves the Agreement's Effective Date alone" do
    expect(date_after("Effective Date")).to eq(Date.new(2025, 1, 1))
  end

  it "states when the latest changes bind an existing account, 30 days after posting" do
    posted = date_after("Last Updated Date")
    binding_date = posted + 30

    expect(header).to match(/take#{SPACE}+effect#{SPACE}+for#{SPACE}+existing#{SPACE}+accounts/o),
                      "header must say when the posted changes become effective for existing accounts"

    stated = header.scan(/([A-Z][a-z]+#{SPACE}+\d{1,2},#{SPACE}*\d{4})/o)
                   .map { |(d)| Date.parse(d.gsub(/#{SPACE}+/o, " ")) }

    expect(stated).to include(binding_date),
                      "expected the header to name #{binding_date} (Last Updated #{posted} + 30 days); " \
                      "it names #{stated.inspect}"
  end
end
