# frozen_string_literal: true

RSpec::Matchers.define :equal_with_indifferent_access do |expected|
  match do |actual|
    actual.with_indifferent_access == expected.with_indifferent_access
  end

  failure_message do |actual|
    <<-EOS
    expected: #{expected}
         got: #{actual}
    EOS
  end

  failure_message_when_negated do |actual|
    <<-EOS
    expected: value != #{expected}
         got:          #{actual}
    EOS
  end
end

RSpec::Matchers.define :match_html do |expected_html, **options|
  match do |actual_html|
    expected_doc = Nokogiri::HTML5.fragment(expected_html)
    actual_doc = Nokogiri::HTML5.fragment(actual_html)

    # Options documented here: https://github.com/vkononov/compare-xml
    default_options = {
      collapse_whitespace: true,
      ignore_attr_order: true,
      ignore_comments: true,
    }

    options = default_options.merge(options).merge(verbose: true)

    diff = CompareXML.equivalent?(expected_doc, actual_doc, **options)
    diff.blank?
  end
end

RSpec::Matchers.define_negated_matcher :not_change, :change
RSpec::Matchers.define_negated_matcher :not_have_enqueued_mail, :have_enqueued_mail
