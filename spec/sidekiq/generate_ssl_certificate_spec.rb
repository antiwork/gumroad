# frozen_string_literal: true

describe GenerateSslCertificate do
  describe "#perform" do
    before do
      @custom_domain = create(:custom_domain, domain: "www.example.com")
      @obj_double = double("SslCertificates::Generate object")
      allow(SslCertificates::Generate).to receive(:new).with(@custom_domain).and_return(@obj_double)
      allow(@obj_double).to receive(:process)
    end

    context "when the environment is production or staging" do
      before do
        allow(Rails.env).to receive(:production?).and_return(true)
      end

      context "when the custom domain is not deleted" do
        it "invokes SslCertificates::Generate service" do
          expect(SslCertificates::Generate).to receive(:new).with(@custom_domain)
          expect(@obj_double).to receive(:process)

          described_class.new.perform(@custom_domain.id)
        end
      end

      context "when the custom domain is deleted" do
        before do
          @custom_domain.mark_deleted!
        end

        it "doesn't invoke SslCertificates::Generate service" do
          expect(SslCertificates::Generate).not_to receive(:new).with(@custom_domain)

          described_class.new.perform(@custom_domain.id)
        end
      end

      context "when Let's Encrypt rate-limits the account" do
        let(:rate_limit_error) do
          Acme::Client::Error::RateLimited.new(
            "too many new orders (300) from this account in the last 3h0m0s, " \
            "retry after 2026-07-20 05:14:17 UTC: see https://letsencrypt.org/docs/rate-limits/#new-orders-per-account"
          )
        end

        before do
          allow(@obj_double).to receive(:process).and_raise(rate_limit_error)
          # Creating the custom domain enqueues its own GenerateSslCertificate
          # job via a model callback — clear it so assertions below only see
          # the job rescheduled by the rate-limit handling.
          described_class.clear
        end

        it "reschedules the job past the rate-limit reset instead of raising" do
          travel_to(Time.utc(2026, 7, 20, 5, 0, 0)) do
            expect do
              described_class.new.perform(@custom_domain.id)
            end.not_to raise_error

            job = described_class.jobs.sole
            expect(job["args"]).to eq([@custom_domain.id, 1])

            delay = job["at"] - Time.current.to_f
            # At least until the reset time (05:14:17 = 857s away), at most
            # reset time + the 3-hour jitter window.
            expect(delay).to be >= 857
            expect(delay).to be <= 857 + 3.hours.to_i
          end
        end

        it "increments the reschedule count on each reschedule" do
          described_class.new.perform(@custom_domain.id, 3)

          job = described_class.jobs.sole
          expect(job["args"]).to eq([@custom_domain.id, 4])
        end

        context "when the reschedule cap has been reached" do
          it "lets the error propagate so Sidekiq retries (and eventually alerts)" do
            expect do
              described_class.new.perform(@custom_domain.id, described_class::RATE_LIMIT_MAX_RESCHEDULES)
            end.to raise_error(Acme::Client::Error::RateLimited)

            expect(described_class.jobs).to be_empty
          end
        end

        context "when the error message has no parseable retry-after time" do
          let(:rate_limit_error) { Acme::Client::Error::RateLimited.new("rate limited") }

          it "reschedules using the fallback delay" do
            expect do
              described_class.new.perform(@custom_domain.id)
            end.not_to raise_error

            job = described_class.jobs.sole
            delay = job["at"] - Time.current.to_f
            expect(delay).to be >= 1.hour.to_i
            expect(delay).to be <= 1.hour.to_i + 3.hours.to_i
          end
        end

        context "when the reset time is already in the past" do
          it "reschedules with only the jitter delay" do
            travel_to(Time.utc(2026, 7, 20, 6, 0, 0)) do
              # With a past reset time the base delay is 0, so a jitter of 0
              # would call perform_in(0, ...), which Sidekiq's fake mode
              # enqueues without an "at" timestamp. Pin the jitter to keep the
              # assertion deterministic.
              allow_any_instance_of(described_class).to receive(:rand).and_return(1)

              expect do
                described_class.new.perform(@custom_domain.id)
              end.not_to raise_error

              job = described_class.jobs.sole
              delay = job["at"] - Time.current.to_f
              expect(delay).to be >= 0
              expect(delay).to be <= 3.hours.to_i
            end
          end
        end
      end

      context "when certificate generation fails for a non-rate-limit reason" do
        it "lets the error propagate so Sidekiq retries (and eventually alerts)" do
          allow(@obj_double).to receive(:process).and_raise(Acme::Client::Error::RejectedIdentifier.new("Invalid identifier"))
          described_class.clear

          expect do
            described_class.new.perform(@custom_domain.id)
          end.to raise_error(Acme::Client::Error::RejectedIdentifier)

          expect(described_class.jobs).to be_empty
        end
      end
    end

    context "when the environment is not production or staging" do
      it "doesn't invoke SslCertificates::Generate service" do
        expect(SslCertificates::Generate).not_to receive(:new).with(@custom_domain)
        expect(@obj_double).not_to receive(:process)

        described_class.new.perform(@custom_domain.id)
      end
    end
  end
end
