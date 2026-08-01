# frozen_string_literal: true

require "spec_helper"

# §27.6 ("Agreement Updates") delays every Terms change by 30 days for existing Registered Users,
# and for MATERIAL changes makes it the earlier of that or 30 days after an emailed notice — so the
# posting date alone fixes the date and a later email cannot pull it in. The header states that date;
# these examples keep it arithmetically true and tied to the posting it describes.
#
# Asserts a derived invariant rather than pinning literals, so an ordinary Terms edit does not have
# to rewrite this file. Section NUMBERS are deliberately absent from the header and from the
# assertions: #6717 renumbered 52 subsection headers, which is why the amendment is identified by
# its posting date instead.
describe "app/views/home/terms.html.erb amendment notice" do
  # Methods rather than constants: a constant assigned in a describe block lands on Object and
  # collides with the next spec that picks the same name.
  def month
    "(?:January|February|March|April|May|June|July|August|September|October|November|December)"
  end

  # Ruby's \s does not match U+00A0 but POSIX [[:space:]] does, and this file's hand-maintained
  # markup is full of nbsp gaps — matching a gap with \s would silently skip those rows.
  def sp
    "[[:space:]]"
  end

  let(:source) { Rails.root.join("app/views/home/terms.html.erb").read }

  let(:header) do
    source[/description:#{sp}*"(.*?)"#{sp}*%>/m, 1] ||
      raise("could not find the header description passed to home/shared/header")
  end

  let(:last_updated) { date_after("Last Updated Date") }

  # The notice sentence, parsed as the pair of dates it relates. nil when no notice line is present.
  # The cohort has to be described by what was true at POSTING time, not by a calendar cutoff: an
  # account registered earlier the same day the amendments went up already existed when notice was
  # given, so "created before <posted>" would exclude a user §27.6 covers.
  let(:notice) do
    m = header.match(
      /Accounts#{sp}+that#{sp}+existed#{sp}+when#{sp}+the#{sp}+
       (?<posted>#{month}#{sp}+\d{1,2},#{sp}*\d{4})#{sp}+changes#{sp}+were#{sp}+posted#{sp}+
       are#{sp}+bound#{sp}+by#{sp}+them#{sp}+on#{sp}+
       (?<binding>#{month}#{sp}+\d{1,2},#{sp}*\d{4})/x
    )
    m && { posted: to_date(m[:posted]), binding: to_date(m[:binding]) }
  end

  def to_date(raw)
    Date.parse(raw.gsub(/#{sp}+/, " "))
  end

  def date_after(label)
    raw = header[/#{Regexp.escape(label)}:#{sp}*(#{month}#{sp}+\d{1,2},#{sp}*\d{4})/, 1] ||
      raise("header carries no #{label}: #{header.inspect}")
    to_date(raw)
  end

  # Required only while the latest posting's 30-day window is still running or just closed. Once the
  # window has passed the notice has done its work and may come off the page — the spec must not be
  # the reason a spent sentence stays up reading as future tense about a past date.
  it "states when a posted change takes effect while its 30-day window is still open" do
    pending_window = last_updated + 30 >= Date.current
    next unless pending_window

    expect(notice).to be_present,
                      "#{last_updated} is within 30 days, so the header must say when that change " \
                      "takes effect: 'Accounts that existed when the <posted> changes were posted " \
                      "are bound by them on <posted + 30 days>'. Header is #{header.inspect}"
  end

  # Both halves are checked against Last Updated, not just the trailing date: greening a stale line
  # by editing only the date it takes effect would leave the sentence attributing the wrong posting.
  it "describes the latest posting, and dates it 30 days out" do
    next if notice.nil?

    expect(notice[:posted]).to eq(last_updated),
                               "notice describes the #{notice[:posted]} changes but the page was " \
                               "last updated #{last_updated}"
    expect(notice[:binding]).to eq(notice[:posted] + 30),
                                "a change posted #{notice[:posted]} takes effect for an existing " \
                                "account on #{notice[:posted] + 30}, not #{notice[:binding]}"
  end

  # January 1, 2025 is a historical fact about this Agreement, so a per-amendment date has to be
  # added alongside it rather than written over it.
  it "states the amendment date without restating the Agreement's own Effective Date" do
    expect(date_after("Effective Date")).to eq(Date.new(2025, 1, 1))
  end
end
