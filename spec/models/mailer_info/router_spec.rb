# frozen_string_literal: true

require "spec_helper"

RSpec.describe MailerInfo::Router do
  let(:domain) { :gumroad }
  let(:date) { Date.current }

  describe ".determine_email_provider" do
    it "raises error for invalid domain" do
      expect do
        described_class.determine_email_provider(:invalid)
      end.to raise_error(ArgumentError, "Invalid domain: invalid")
    end

    it "returns SendGrid in test environment" do
      expect(described_class.determine_email_provider(domain)).to eq(MailerInfo::EMAIL_PROVIDER_SENDGRID)
    end

    context "when resend feature is active" do
      before do
        allow(Rails.env).to receive(:test?).and_return(false)
        Feature.activate(:resend)
      end

      context "without counts" do
        it "returns SendGrid" do
          expect(described_class.determine_email_provider(domain)).to eq(MailerInfo::EMAIL_PROVIDER_SENDGRID)
        end
      end

      it "returns SendGrid when max count is reached" do
        described_class.set_max_count(domain, date, 10)
        $redis.set(described_class.send(:current_count_key, domain, date:), 10)

        expect(described_class.determine_email_provider(domain)).to eq(MailerInfo::EMAIL_PROVIDER_SENDGRID)
      end

      it "returns Resend based on probability" do
        described_class.set_probability(domain, date, 1.0)
        described_class.set_max_count(domain, date, 100)
        $redis.set(described_class.send(:current_count_key, domain, date:), 0)
        allow(Kernel).to receive(:rand).and_return(0.5)

        expect(described_class.determine_email_provider(domain)).to eq(MailerInfo::EMAIL_PROVIDER_RESEND)
      end

      it "returns SendGrid based on probability" do
        described_class.set_probability(domain, date, 0.0)
        described_class.set_max_count(domain, date, 100)
        $redis.set(described_class.send(:current_count_key, domain, date:), 0)
        allow(Kernel).to receive(:rand).and_return(0.5)

        expect(described_class.determine_email_provider(domain)).to eq(MailerInfo::EMAIL_PROVIDER_SENDGRID)
      end

      it "increments counter when choosing Resend" do
        described_class.set_probability(domain, date, 1.0)
        described_class.set_max_count(domain, date, 100)
        $redis.set(described_class.send(:current_count_key, domain, date:), 0)
        allow(Kernel).to receive(:rand).and_return(0.5)

        expect do
          described_class.determine_email_provider(domain)
        end.to change { $redis.get(described_class.send(:current_count_key, domain, date:)).to_i }.by(1)
      end
    end
  end

  describe ".set_probability" do
    it "raises error for invalid domain" do
      expect do
        described_class.set_probability(:invalid, date, 0.5)
      end.to raise_error(ArgumentError, "Invalid domain: invalid")
    end

    it "sets probability in Redis" do
      described_class.set_probability(domain, date, 0.5)
      key = described_class.send(:probability_key, domain, date:)
      expect($redis.get(key).to_f).to eq(0.5)
    end
  end

  describe ".set_max_count" do
    it "raises error for invalid domain" do
      expect do
        described_class.set_max_count(:invalid, date, 100)
      end.to raise_error(ArgumentError, "Invalid domain: invalid")
    end

    it "sets max count in Redis" do
      described_class.set_max_count(domain, date, 100)
      key = described_class.send(:max_count_key, domain, date:)
      expect($redis.get(key).to_i).to eq(100)
    end
  end

  describe ".domain_stats" do
    it "raises error for invalid domain" do
      expect do
        described_class.domain_stats(:invalid)
      end.to raise_error(ArgumentError, "Invalid domain: invalid")
    end

    it "returns stats for domain" do
      described_class.set_probability(domain, date, 0.5)
      described_class.set_max_count(domain, date, 100)
      $redis.set(described_class.send(:current_count_key, domain), 42)

      stats = described_class.domain_stats(domain)
      expect(stats).to include(
        hash_including(
          date: date.to_s,
          probability: 0.5,
          max_count: 100,
          current_count: 42
        )
      )
    end
  end

  describe ".stats" do
    it "returns stats for all domains" do
      described_class.set_probability(:gumroad, date, 0.5)
      described_class.set_max_count(:gumroad, date, 100)

      stats = described_class.stats
      expect(stats.keys).to match_array(MailerInfo::DeliveryMethod::DOMAINS)
      expect(stats[:gumroad]).to be_present
    end
  end
end
