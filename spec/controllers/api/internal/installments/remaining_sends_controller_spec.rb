# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"

describe Api::Internal::Installments::RemainingSendsController do
  let(:seller) { create(:user) }

  include_context "with user signed in as admin for seller"

  let(:installment) { create(:audience_post, :published, seller:) }
  let!(:blast) do
    create(:blast, post: installment, requested_at: 2.days.ago, started_at: 2.days.ago, first_email_delivered_at: 2.days.ago,
                   last_email_delivered_at: 2.days.ago, completed_at: nil, delivery_count: 6_798)
  end

  after { $redis.del(RedisKey.stalled_blast_auto_resumed(blast.id), RedisKey.blast_pending_recipients(blast.id)) }

  describe "POST create" do
    it_behaves_like "authentication required for action", :post, :create do
      let(:request_params) { { id: installment.external_id } }
    end

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { installment }
      let(:policy_method) { :send_to_remaining? }
      let(:request_params) { { id: installment.external_id } }
    end

    it "resumes an incomplete send and claims the monitor's once-per-window marker" do
      post :create, params: { id: installment.external_id }

      expect(response).to be_successful
      expect(response.parsed_body).to eq({ "success" => true })
      expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(blast.id)
      expect($redis.get(RedisKey.stalled_blast_auto_resumed(blast.id))).to eq("seller:#{seller.id}")
      expect($redis.ttl(RedisKey.stalled_blast_auto_resumed(blast.id))).to be_between(1, AlertOnStalledPostEmailBlastsJob::STALL_THRESHOLD.to_i).inclusive
    end

    it "refuses while the monitor will retry on its own" do
      Feature.activate(:auto_resume_stalled_post_blasts)
      $redis.set(RedisKey.blast_pending_recipients(blast.id), 16_212)

      post :create, params: { id: installment.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("We are retrying this automatically.")
      expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
    ensure
      Feature.deactivate(:auto_resume_stalled_post_blasts)
    end

    it "refuses when the latest send is not incomplete" do
      blast.update!(completed_at: 1.day.ago)

      post :create, params: { id: installment.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("This email is not waiting on any recipients.")
      expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
    end

    it "refuses while a sender is still busy, queued or retrying, and gives the marker back" do
      allow(AlertOnStalledPostEmailBlastsJob).to receive(:sender_visible?).with(blast.id).and_return(true)

      post :create, params: { id: installment.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("This email is already sending. Check back in a few hours.")
      expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
      expect($redis.exists?(RedisKey.stalled_blast_auto_resumed(blast.id))).to eq(false)
    end

    it "holds the marker while it scans for a live sender, so the monitor cannot start one meanwhile" do
      allow(AlertOnStalledPostEmailBlastsJob).to receive(:sender_visible?) do
        expect($redis.get(RedisKey.stalled_blast_auto_resumed(blast.id))).to eq("seller:#{seller.id}")
        false
      end

      post :create, params: { id: installment.external_id }

      expect(response).to be_successful
      expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(blast.id)
    end

    it "refuses a second start inside the stall window, whoever started the first" do
      $redis.set(RedisKey.stalled_blast_auto_resumed(blast.id), Time.current.iso8601, ex: 1.hour.to_i)

      post :create, params: { id: installment.external_id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("A send was started recently. Check back in a few hours.")
      expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
    end

    describe "an email that was never sent" do
      before { blast.update!(first_email_delivered_at: nil, last_email_delivered_at: nil, delivery_count: 0, expired_at: 1.hour.ago, expiry_reason: PostEmailBlast::EXPIRY_QUOTA) }

      it "starts a new send with its own content window and leaves the expired one as history" do
        freeze_time do
          expect { post :create, params: { id: installment.external_id } }.to change { installment.blasts.count }.by(1)

          new_blast = installment.reload.latest_regular_blast
          expect(response.parsed_body).to eq({ "success" => true })
          expect(new_blast.requested_at).to eq(Time.current)
          expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(new_blast.id)
          expect(blast.reload.expired_at).to be_present
        end
      end

      it "restarts an abandoned send the same way" do
        blast.update!(expiry_reason: PostEmailBlast::EXPIRY_ABANDONED)

        expect { post :create, params: { id: installment.external_id } }.to change { installment.blasts.count }.by(1)
        expect(SendPostBlastEmailsJob.jobs.size).to eq(1)
      end

      it "starts only one send when the seller submits twice" do
        post :create, params: { id: installment.external_id }
        post :create, params: { id: installment.external_id }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(installment.blasts.count).to eq(2)
        expect(SendPostBlastEmailsJob.jobs.size).to eq(1)
      end

      it "starts no send when a concurrent submit created one first" do
        allow_any_instance_of(Installment).to receive(:with_lock).and_wrap_original do |original, *args, &block|
          create(:blast, :just_requested, post: installment)
          original.call(*args, &block)
        end

        post :create, params: { id: installment.external_id }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to eq("This email is already sending.")
        expect(installment.blasts.count).to eq(2)
        expect(SendPostBlastEmailsJob.jobs.size).to eq(0)
      end

      it "ignores a non-opener resend when it decides the email was never sent" do
        create(:blast, post: installment, requested_at: 1.minute.ago, recipient_filter: PostEmailBlast::RECIPIENT_FILTER_UNOPENED, completed_at: nil)

        expect { post :create, params: { id: installment.external_id } }.to change { installment.blasts.count }.by(1)
      end
    end

    it "returns 404 for an unpublished post" do
      installment.update!(published_at: nil)

      post :create, params: { id: installment.external_id }

      expect(response).to have_http_status(:not_found)
    end
  end
end
