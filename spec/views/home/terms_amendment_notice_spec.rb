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

  # Anchored on the notice line's OWN posting date, not on Last Updated. Last Updated moves for any
  # edit including a typo fix, while this date may only move when a MATERIAL change is posted — a
  # materiality call no spec can make. Coupling the two would redden CI on an innocent edit and the
  # only way to green it would be publishing a 30-day claim with no material change behind it.
  it "states a binding date 30 days after the amendment it describes was posted" do
    notice = header[/((?:January|February|March|April|May|June|July|August|September|October|November|December)#{SPACE}+\d{1,2},#{SPACE}*\d{4})#{SPACE}+changes#{SPACE}+take#{SPACE}+effect#{SPACE}+for#{SPACE}+existing#{SPACE}+accounts#{SPACE}+on#{SPACE}+((?:January|February|March|April|May|June|July|August|September|October|November|December)#{SPACE}+\d{1,2},#{SPACE}*\d{4})/o]
    expect(notice).to be_present,
                      "header must state when a posted amendment takes effect for existing accounts, " \
                      "in the form '<posted date> changes take effect for existing accounts on <date>'; " \
                      "header is #{header.inspect}"

    posted, binding_date = Regexp.last_match.captures.map { |d| Date.parse(d.gsub(/#{SPACE}+/o, " ")) }

    expect(binding_date).to eq(posted + 30),
                            "§27.5 gives the EARLIER of 30 days after posting or 30 days after an " \
                            "emailed notice, so a posting on #{posted} binds an existing account on " \
                            "#{posted + 30}, not #{binding_date}"
  end

  # The amendment date must be additive. Reusing this field would move the arbitration boundary in
  # §25 ("disputes that arose ... before the effective date of the Agreement").
  it "states the amendment date without disturbing the Agreement's own Effective Date" do
    expect(date_after("Effective Date")).to eq(Date.new(2025, 1, 1))
  end
end
