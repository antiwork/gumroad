# frozen_string_literal: true

class DisposableEmailValidator < ActiveModel::EachValidator
  DISPOSABLE_DOMAINS_PATH = Rails.root.join("lib/data/disposable_email_domains.txt")

  class << self
    def disposable_domains
      @disposable_domains ||= load_domains
    end

    def disposable?(email)
      return false if email.blank?

      domain = email.to_s.split("@").last&.downcase
      return false if domain.blank?

      disposable_domains.include?(domain)
    end

    def reload_domains!
      @disposable_domains = load_domains
    end

    private
      def load_domains
        return Set.new if !File.exist?(DISPOSABLE_DOMAINS_PATH)

        File.readlines(DISPOSABLE_DOMAINS_PATH).map(&:strip).reject(&:blank?).to_set
      end
  end

  def validate_each(record, attribute, value)
    return if value.blank? && options[:allow_blank]

    if self.class.disposable?(value)
      record.errors.add(attribute, options[:message] || "is from a disposable email provider and cannot be used")
    end
  end
end
