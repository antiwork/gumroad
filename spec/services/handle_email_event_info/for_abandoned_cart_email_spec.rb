# frozen_string_literal: true

describe HandleEmailEventInfo::ForAbandonedCartEmail do
  let!(:abandoned_cart_workflow1) { create(:abandoned_cart_workflow) }
  let(:abandoned_cart_workflow_installment1) { abandoned_cart_workflow1.alive_installments.sole }
  let!(:abandoned_cart_workflow2) { create(:abandoned_cart_workflow) }
  let(:abandoned_cart_workflow_installment2) { abandoned_cart_workflow2.alive_installments.sole }
  let!(:abandoned_cart_workflow3) { create(:abandoned_cart_workflow) }
  let(:abandoned_cart_workflow_installment3) { abandoned_cart_workflow3.alive_installments.sole }
  let(:mailer_args_with_multiple_workflow_ids) { "[4, {\"#{abandoned_cart_workflow1.id}\"=>[31, 57, 60], \"#{abandoned_cart_workflow3.id}\"=>[22, 57, 60]}]" }
  let(:mailer_args_with_single_workflow_id) { "[4, {\"#{abandoned_cart_workflow1.id}\"=>[31, 57, 60]}]" }

  def handler_class_for(email_provider)
    case email_provider
    when :sendgrid then HandleSendgridEventJob
    when :resend then HandleResendEventJob
    end
  end

  describe ".perform" do
    RSpec.shared_examples "tracks a delivered event" do |email_provider|
      it "tracks a delivered event" do
        expect do
          handler_class_for(email_provider).new.perform(params)
        end.to change { abandoned_cart_workflow_installment1.reload.customer_count }.from(nil).to(1)
          .and change { abandoned_cart_workflow_installment3.reload.customer_count }.from(nil).to(1)

        expect(abandoned_cart_workflow_installment2.reload.customer_count).to be_nil
      end
    end

    RSpec.shared_examples "handles opened events" do |email_provider|
      it "tracks an open event" do
        handler_class_for(email_provider).new.perform(params)

        expect(abandoned_cart_workflow_installment1.reload.unique_open_count).to eq(1)
        expect(abandoned_cart_workflow_installment3.reload.unique_open_count).to eq(1)
        expect(abandoned_cart_workflow_installment2.reload.unique_open_count).to eq(0)
      end

      it "reads live unique open counts after an open event" do
        [abandoned_cart_workflow_installment1, abandoned_cart_workflow_installment3].each do |installment|
          Rails.cache.write(installment.key_for_cache(:unique_open_count, dynamodb_reads: false), 0)
        end

        handler_class_for(email_provider).new.perform(params)

        expect(Installment.find(abandoned_cart_workflow_installment1.id).unique_open_count).to eq(1)
        expect(Installment.find(abandoned_cart_workflow_installment2.id).unique_open_count).to eq(0)
        expect(Installment.find(abandoned_cart_workflow_installment3.id).unique_open_count).to eq(1)
        [abandoned_cart_workflow_installment1, abandoned_cart_workflow_installment3].each do |installment|
          expect(Rails.cache.read(installment.key_for_cache(:unique_open_count, dynamodb_reads: false))).to be_nil
        end
      end

      it "tracks an open event and update it if there are 2 identical open events" do
        handler_class_for(email_provider).new.perform(params)
        handler_class_for(email_provider).new.perform(params)

        expect(abandoned_cart_workflow_installment1.reload.unique_open_count).to eq(1)
        expect(abandoned_cart_workflow_installment3.reload.unique_open_count).to eq(1)
      end
    end

    RSpec.shared_examples "handles click events" do |email_provider|
      it "tracks a click event with email click summary" do
        handler_class_for(email_provider).new.perform(params1)

        expect(abandoned_cart_workflow_installment1.reload.unique_click_count).to eq(1)
        expect(abandoned_cart_workflow_installment3.reload.unique_click_count).to eq(1)
        expect(abandoned_cart_workflow_installment2.reload.unique_click_count).to eq(0)
      end

      it "reads live unique click and open counts after a click event" do
        [abandoned_cart_workflow_installment1, abandoned_cart_workflow_installment3].each do |installment|
          Rails.cache.write(installment.key_for_cache(:unique_click_count, dynamodb_reads: false), 0)
          Rails.cache.write(installment.key_for_cache(:unique_open_count, dynamodb_reads: false), 0)
        end

        handler_class_for(email_provider).new.perform(params1)

        [abandoned_cart_workflow_installment1.id, abandoned_cart_workflow_installment3.id].each do |installment_id|
          installment = Installment.find(installment_id)
          expect(installment.unique_click_count).to eq(1)
          expect(installment.unique_open_count).to eq(1)
          expect(Rails.cache.read(installment.key_for_cache(:unique_click_count, dynamodb_reads: false))).to be_nil
          expect(Rails.cache.read(installment.key_for_cache(:unique_open_count, dynamodb_reads: false))).to be_nil
        end

        skipped = Installment.find(abandoned_cart_workflow_installment2.id)
        expect(skipped.unique_click_count).to eq(0)
        expect(skipped.unique_open_count).to eq(0)
      end

      it "tracks multiple click events and only one email click summary record for different URLs for an installment" do
        handler_class_for(email_provider).new.perform(params1)
        handler_class_for(email_provider).new.perform(params2)

        expect(abandoned_cart_workflow_installment1.reload.unique_click_count).to eq(2)
        expect(abandoned_cart_workflow_installment3.reload.unique_click_count).to eq(2)
        expect(abandoned_cart_workflow_installment2.reload.unique_click_count).to eq(0)
      end

      it "records a single email click summary for duplicate click events and updates the timestamps for the tracked click event" do
        handler_class_for(email_provider).new.perform(params1)
        handler_class_for(email_provider).new.perform(params1)

        expect(abandoned_cart_workflow_installment1.reload.unique_click_count).to eq(1)
        expect(abandoned_cart_workflow_installment3.reload.unique_click_count).to eq(1)
      end
    end

    RSpec.shared_examples "records an open event while tracking a click event when a corresponding open event does not exist yet" do |email_provider|
      it "records an open event while tracking a click event when a corresponding open event does not exist yet" do
        handler_class_for(email_provider).new.perform(params)

        expect(abandoned_cart_workflow_installment1.reload.unique_open_count).to eq(1)
        expect(abandoned_cart_workflow_installment1.unique_click_count).to eq(1)
      end
    end

    context "with SendGrid" do
      let(:params) do
        {
          "_json" => [
            {
              "event" => event_type,
              "mailer_class" => "CustomerMailer",
              "mailer_method" => "abandoned_cart",
              "mailer_args" => mailer_args_with_multiple_workflow_ids
            }
          ]
        }
      end

      context "with delivered event" do
        let(:event_type) { EmailEventInfo::EVENTS[:delivered][MailerInfo::EMAIL_PROVIDER_SENDGRID] }

        it_behaves_like "tracks a delivered event", :sendgrid
      end

      context "with opened event" do
        let(:event_type) { EmailEventInfo::EVENTS[:opened][MailerInfo::EMAIL_PROVIDER_SENDGRID] }

        it_behaves_like "handles opened events", :sendgrid
      end

      context "with clicked event" do
        let(:event_type) { EmailEventInfo::EVENTS[:clicked][MailerInfo::EMAIL_PROVIDER_SENDGRID] }

        let(:params1) { params.deep_merge("_json" => [params["_json"].first.merge("url" => "https://www&#46;gumroad&#46;com/checkout")]) }
        let(:params2) { params.deep_merge("_json" => [params["_json"].first.merge("url" => "https://seller&#46;gumroad&#46;com/l/abc")]) }

        it_behaves_like "handles click events", :sendgrid

        context "with mailer_args with single workflow_id" do
          before do
            params["_json"] = [params["_json"].first.merge("mailer_args" => mailer_args_with_single_workflow_id, "url" => "https://www&#46;gumroad&#46;com/checkout")]
          end

          it_behaves_like "records an open event while tracking a click event when a corresponding open event does not exist yet", :sendgrid
        end

        it "handles the second event in the params array even if the first one is malformed" do
          params = { "_json" => [{ "event" => "click" },
                                 { "event" => "click", "mailer_class" => "CustomerMailer", "mailer_method" => "abandoned_cart", "mailer_args" => mailer_args_with_multiple_workflow_ids, "url" => "https://www&#46;gumroad&#46;com/checkout" }] }
          handler_class_for(:sendgrid).new.perform(params)

          expect(abandoned_cart_workflow_installment1.reload.unique_click_count).to eq(1)
          expect(abandoned_cart_workflow_installment3.reload.unique_click_count).to eq(1)
        end
      end

      it "does not record an open event while recording a click event when a corresponding open event already exists" do
        params = {
          "_json" => [
            { "event" => "open", "mailer_class" => "CustomerMailer", "mailer_method" => "abandoned_cart", "mailer_args" => mailer_args_with_single_workflow_id },
            { "event" => "click", "mailer_class" => "CustomerMailer", "mailer_method" => "abandoned_cart", "mailer_args" => mailer_args_with_single_workflow_id, "url" => "https://www&#46;gumroad&#46;com/checkout" }
          ]
        }
        handler_class_for(:sendgrid).new.perform(params)

        expect(abandoned_cart_workflow_installment1.reload.unique_open_count).to eq(1)
        expect(abandoned_cart_workflow_installment1.unique_click_count).to eq(1)
      end
    end

    context "with Resend" do
      let(:params) do
        {
          "data" => {
            "created_at" => "2025-01-02 00:14:11.140106+00",
            "to" => ["customer@example.com"],
            "headers" => [
              {
                "name" => MailerInfo.header_name(:mailer_class),
                "value" => MailerInfo.encrypt("CustomerMailer")
              },
              {
                "name" => MailerInfo.header_name(:mailer_method),
                "value" => MailerInfo.encrypt("abandoned_cart")
              },
              {
                "name" => MailerInfo.header_name(:mailer_args),
                "value" => MailerInfo.encrypt(mailer_args_with_multiple_workflow_ids)
              },
              {
                "name" => MailerInfo.header_name(:workflow_ids),
                "value" => MailerInfo.encrypt([abandoned_cart_workflow1.id, abandoned_cart_workflow3.id].to_json)
              }
            ],
          },
          "type" => event_type
        }
      end

      context "with delivered event" do
        let(:event_type) { EmailEventInfo::EVENTS[:delivered][MailerInfo::EMAIL_PROVIDER_RESEND] }

        it_behaves_like "tracks a delivered event", :resend
      end

      context "with opened event" do
        let(:event_type) { EmailEventInfo::EVENTS[:opened][MailerInfo::EMAIL_PROVIDER_RESEND] }

        it_behaves_like "handles opened events", :resend
      end

      context "with clicked event" do
        let(:event_type) { EmailEventInfo::EVENTS[:clicked][MailerInfo::EMAIL_PROVIDER_RESEND] }

        # "click": {
        #   "ipAddress": "99.199.137.97",
        #   "link": "https://app.gumroad.dev/d/d12705ba11d9a4d81776638601b911bd",
        #   "timestamp": "2025-01-02T04:22:05.080Z",
        #   "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        # },
        let(:params1) { params.deep_merge("data" => { "click" => { "link" => "https://www&#46;gumroad&#46;com/checkout" } }) }
        let(:params2) { params.deep_merge("data" => { "click" => { "link" => "https://seller&#46;gumroad&#46;com/l/abc" } }) }

        it_behaves_like "handles click events", :resend

        context "with mailer_args with single workflow_id" do
          before do
            params["data"]["click"] = { "link" => "https://www&#46;gumroad&#46;com/checkout" }
            params["data"]["headers"].find { |header| header["name"] == MailerInfo.header_name(:workflow_ids) }["value"] = MailerInfo.encrypt([abandoned_cart_workflow1.id].to_json)
            params["data"]["headers"].find { |header| header["name"] == MailerInfo.header_name(:mailer_args) }["value"] = MailerInfo.encrypt(mailer_args_with_single_workflow_id)
          end

          it_behaves_like "records an open event while tracking a click event when a corresponding open event does not exist yet", :resend
        end
      end
    end

    describe "DynamoDB dual write" do
      it "records an open event in DynamoDB for each workflow installment" do
        [abandoned_cart_workflow_installment1, abandoned_cart_workflow_installment3].each do |installment|
          expect(EmailEngagementDynamoStore).to receive(:record_open).with(
            installment_id: installment.id,
            mailer_method: "CustomerMailer.abandoned_cart",
            mailer_args: mailer_args_with_multiple_workflow_ids
          )
        end

        HandleSendgridEventJob.new.perform(
          { "_json" => [{ "event" => "open", "mailer_class" => "CustomerMailer", "mailer_method" => "abandoned_cart",
                          "mailer_args" => mailer_args_with_multiple_workflow_ids }] }
        )
      end

      it "records a click event in DynamoDB for each workflow installment" do
        [abandoned_cart_workflow_installment1, abandoned_cart_workflow_installment3].each do |installment|
          expect(EmailEngagementDynamoStore).to receive(:record_click).with(
            installment_id: installment.id,
            mailer_method: "CustomerMailer.abandoned_cart",
            mailer_args: mailer_args_with_multiple_workflow_ids,
            click_url: "https://www&#46;gumroad&#46;com/checkout"
          )
        end

        HandleSendgridEventJob.new.perform(
          { "_json" => [{ "event" => "click", "mailer_class" => "CustomerMailer", "mailer_method" => "abandoned_cart",
                          "mailer_args" => mailer_args_with_multiple_workflow_ids, "url" => "https://www&#46;gumroad&#46;com/checkout" }] }
        )
      end
    end
  end
end
