# frozen_string_literal: true

require "spec_helper"

# Asserts the Terms document is internally consistent rather than pinning a list of expected
# numbers, so a legitimate Terms edit does not have to rewrite this file. gumroad-private#1617.
#
# Ruby's \s does not match U+00A0, and this file's hand-maintained markup gaps mix both — a \s
# gap silently skips the nbsp-gapped rows and every count below goes vacuous.
describe "app/views/home/terms.html.erb cross-references" do
  SP = "[[:space:]\u00a0]"

  let(:source) { Rails.root.join("app/views/home/terms.html.erb").read }

  # "8.1  Purchasing Process." => { "8.1" => "Purchasing Process" }
  let(:subsections) do
    source.scan(/<strong>#{SP}*(\d{1,2})\.(\d{1,2})#{SP}+([^<]*?)\.?#{SP}*<\/strong>/o)
          .to_h { |maj, min, title| ["#{maj}.#{min}", normalize(title)] }
  end

  # "5.  THIRD-PARTY PAYMENTS PROVIDERS." => { 5 => "THIRD-PARTY PAYMENTS PROVIDERS" }
  let(:sections) do
    source.scan(/<strong>#{SP}*(\d{1,2})\.#{SP}+([A-Z][^<]*?)\.?#{SP}*<\/strong>/o)
          .each_with_object({}) { |(n, title), h| h[n.to_i] ||= normalize(title) }
  end

  def normalize(text)
    text.gsub(/#{SP}+/o, " ").strip.delete_suffix(".")
  end

  # Titles drift in wording between the heading and the citation ("and" vs "or", a dropped
  # hyphen). Comparing on letters only keeps this spec about NUMBERS pointing at the right
  # place, which is the defect class, rather than about copy-editing.
  def title_key(text)
    text.downcase.gsub(/[^a-z0-9]/, "")
  end

  # The defect class is a NUMBER pointing at the wrong place, not copy drift: cite titles are
  # hand-typed and wander ("and" vs "or", a dropped hyphen) while naming the right number. So a
  # cite is dead when the title it names is the heading of a DIFFERENT number — which is exactly
  # §8.1's "Section 1 (Third-Party Payments Providers)" against section 5.
  def misdirected(cites, headings)
    cites.filter_map do |num, raw_title|
      title = normalize(raw_title)
      owners = headings.select { |_, heading| title_key(heading) == title_key(title) }.keys
      next if owners.empty? || owners.map(&:to_s).include?(num.to_s)

      "'Section #{num} (#{title})' — #{num} is '#{headings[coerce(num, headings)]}'; " \
        "that title is #{owners.inspect}"
    end
  end

  def coerce(num, headings)
    headings.keys.first.is_a?(Integer) ? num.to_i : num
  end

  it "parses the document it is asserting about" do
    expect(sections.size).to eq(27)
    expect(subsections.size).to eq(84)
  end

  it "resolves every titled whole-section cite to the section that carries that title" do
    cites = source.scan(/Section#{SP}+(\d{1,2})#{SP}*\(([^)]{3,90})\)/o)
    expect(cites.size).to eq(6)

    dead = misdirected(cites, sections)
    expect(dead).to be_empty, dead.join("\n")
  end

  it "resolves every titled subsection cite to a subsection that exists with that title" do
    cites = source.scan(/Section#{SP}+(\d{1,2}\.\d{1,2})#{SP}*\(([^)]{3,90})\)/o)
    expect(cites.size).to eq(14)
    expect(cites.map(&:first).uniq - subsections.keys).to be_empty

    dead = misdirected(cites, subsections)
    expect(dead).to be_empty, dead.join("\n")
  end

  it "points every bare subsection cite at a subsection that exists" do
    cited = source.scan(/Section#{SP}+(\d{1,2}\.\d{1,2})(?!#{SP}*\()/o).flatten.uniq
    expect(cited).not_to be_empty
    expect(cited - subsections.keys).to be_empty
  end

  it "numbers each subsection under the section it is printed beneath" do
    order = source.scan(/<strong>#{SP}*(\d{1,2})\.(\d{1,2})?#{SP}+[^<]*?<\/strong>/o)
    expect(order.count { |_, min| min.nil? }).to eq(27)

    current = nil
    misplaced = order.each_with_object([]) do |(maj, min), acc|
      if min.nil?
        current = maj.to_i
      elsif maj.to_i != current
        acc << "#{maj}.#{min} appears under section #{current.inspect}"
      end
    end
    expect(misplaced).to be_empty, misplaced.join("\n")
  end

  it "numbers subsections contiguously from 1 with no number used twice" do
    grouped = subsections.keys.group_by { |k| k.split(".").first.to_i }
                         .transform_values { |ks| ks.map { |k| k.split(".").last.to_i } }
    broken = grouped.reject { |_, mins| mins == (1..mins.size).to_a }
    expect(broken).to be_empty, broken.map { |sec, mins| "section #{sec}: #{mins.inspect}" }.join("\n")
  end

  it "keeps the anchor the help center deep-links to" do
    expect(source).to include('id="section-11-3"')
    expect(subsections).to have_key("11.3")

    article = Rails.root.join("app/views/help_center/articles/contents/_160-suspension.html.erb").read
    expect(article).to include("gumroad.com/terms#section-11-3")
    expect(article).to match(/Section#{SP}+11\.3/o)
  end
end
