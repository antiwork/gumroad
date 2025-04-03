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
        now = Time.current

        travel_to(now) do
          handler_class_for(email_provider).new.perform(params)
        end

        expect(CreatorEmailOpenEvent.count).to eq(2)
        CreatorEmailOpenEvent.each.with_index do |open_event, i|
          expect(open_event.mailer_method).to eq("CustomerMailer.abandoned_cart")
          expect(open_event.mailer_args).to eq(mailer_args_with_multiple_workflow_ids)
          expect(open_event.installment_id).to eq([abandoned_cart_workflow_installment1.id, abandoned_cart_workflow_installment3.id][i])
          expect(open_event.open_timestamps.sole.to_i).to eq(now.to_i)
          expect(open_event.open_count).to eq(1)
        end
      end

      it "sets cache for open event" do
        handler_class_for(email_provider).new.perform(params)

        expect(Rails.cache.read("unique_open_count_for_installment_#{abandoned_cart_workflow_installment1.id}")).to eq(1)
        expect(Rails.cache.read("unique_open_count_for_installment_#{abandoned_cart_workflow_installment2.id}")).to be_nil
        expect(Rails.cache.read("unique_open_count_for_installment_#{abandoned_cart_workflow_installment3.id}")).to eq(1)
      end

      it "tracks an open event and update it if there are 2 identical open events" do
        now = Time.current
        travel_to(now) do
          handler_class_for(email_provider).new.perform(params)
        end

        travel_to(now + 1.minute) do
          handler_class_for(email_provider).new.perform(params)
        end

        expect(CreatorEmailOpenEvent.count).to eq(2)
        CreatorEmailOpenEvent.each.with_index do |open_event, i|
          expect(open_event.mailer_method).to eq("CustomerMailer.abandoned_cart")
          expect(open_event.mailer_args).to eq(mailer_args_with_multiple_workflow_ids)
          expect(open_event.installment_id).to eq([abandoned_cart_workflow_installment1.id, abandoned_cart_workflow_installment3.id][i])
          expect(open_event.open_timestamps.count).to eq(2)
          expect(open_event.open_timestamps.first.to_i).to eq(now.to_i)
          expect(open_event.open_timestamps.last.to_i).to eq((now + 1.minute).to_i)
          expect(open_event.open_count).to eq(2)
        end
      end
    end

    RSpec.shared_examples "handles click events" do |email_provider|
      it "tracks a click event with email click summary" do
        now = Time.current

        travel_to(now) do
          handler_class_for(email_provider).new.perform(params1)
        end

        installments = [abandoned_cart_workflow_installment1.id, abandoned_cart_workflow_installment3.id]
        expect(CreatorEmailClickSummary.count).to eq(2)
        CreatorEmailClickSummary.each.with_index do |summary, i|
          expect(summary.total_unique_clicks).to eq(1)
          expect(summary.installment_id).to eq(installments[i])
          expect(summary.urls).to eq("https://www&#46;gumroad&#46;com/checkout" => 1)
        end
        expect(CreatorEmailClickEvent.count).to eq(2)
        CreatorEmailClickEvent.each.with_index do |click_event, i|
          expect(click_event.mailer_method).to eq("CustomerMailer.abandoned_cart")
          expect(click_event.mailer_args).to eq(mailer_args_with_multiple_workflow_ids)
          expect(click_event.installment_id).to eq(installments[i])
          expect(click_event.click_url).to eq "https://www&#46;gumroad&#46;com/checkout"
          expect(click_event.click_timestamps.sole.to_i).to eq(now.to_i)
          expect(click_event.click_count).to eq(1)
        end
      end

      it "sets cache on click event" do
        handler_class_for(email_provider).new.perform(params1)

        [abandoned_cart_workflow_installment1.id, abandoned_cart_workflow_installment3.id].each do |installment_id|
          expect(Rails.cache.read("unique_click_count_for_installment_#{installment_id}")).to eq(1)

          # It should also cache unique_open_count
          expect(Rails.cache.read("unique_open_count_for_installment_#{installment_id}")).to eq(1)
        end

        expect(Rails.cache.read("unique_click_count_for_installment_#{abandoned_cart_workflow_installment2.id}")).to be_nil
        expect(Rails.cache.read("unique_open_count_for_installment_#{abandoned_cart_workflow_installment2.id}")).to be_nil
      end

      it "tracks multiple click events and only one email click summary record for different URLs for an installment" do
        now = Time.current
        travel_to(now) do
          handler_class_for(email_provider).new.perform(params1)
        end

        travel_to(now + 1.minute) do
          handler_class_for(email_provider).new.perform(params2)
        end

        installments = [abandoned_cart_workflow_installment1.id, abandoned_cart_workflow_installment3.id]
        expect(CreatorEmailClickSummary.count).to eq(2)
        CreatorEmailClickSummary.each.with_index do |summary, i|
          expect(summary.total_unique_clicks).to eq(1)
          expect(summary.installment_id).to eq(installments[i])
          expect(summary.urls).to eq(
            "https://www&#46;gumroad&#46;com/checkout" => 1,
            "https://seller&#46;gumroad&#46;com/l/abc" => 1
          )
        end
        expect(CreatorEmailClickEvent.count).to eq(4)
        expect(CreatorEmailClickEvent.where(installment_id: abandoned_cart_workflow_installment2.id).count).to eq(0)
        CreatorEmailClickEvent.order(created_at: :asc).each_slice(2).with_index do |click_events, i|
          click_events.each.with_index do |click_event, j|
            expect(click_event.mailer_method).to eq("CustomerMailer.abandoned_cart")
            expect(click_event.mailer_args).to eq(mailer_args_with_multiple_workflow_ids)
            expect(click_event.installment_id).to eq(installments[j])
            expect(click_event.click_url).to eq(["https://www&#46;gumroad&#46;com/checkout", "https://seller&#46;gumroad&#46;com/l/abc"][i])
            expect(click_event.click_timestamps.sole.to_i).to eq([now, now + 1.minute][i].to_i)
            expect(click_event.click_count).to eq(1)
          end
        end
      end

      it "records a single email click summary for duplicate click events and updates the timestamps for the tracked click event" do
        now = Time.current
        travel_to(now) do
          handler_class_for(email_provider).new.perform(params1)
        end

        travel_to(now + 1.minute) do
          handler_class_for(email_provider).new.perform(params1)
        end

        installments = [abandoned_cart_workflow_installment1.id, abandoned_cart_workflow_installment3.id]
        expect(CreatorEmailClickSummary.count).to eq(2)
        CreatorEmailClickSummary.each.with_index do |summary, i|
          expect(summary.total_unique_clicks).to eq(1)
          expect(summary.installment_id).to eq(installments[i])
          expect(summary.urls).to eq("https://www&#46;gumroad&#46;com/checkout" => 1)
        end
        expect(CreatorEmailClickEvent.count).to eq(2)
        CreatorEmailClickEvent.each.with_index do |click_event, i|
          expect(click_event.mailer_method).to eq("CustomerMailer.abandoned_cart")
          expect(click_event.mailer_args).to eq(mailer_args_with_multiple_workflow_ids)
          expect(click_event.installment_id).to eq(installments[i])
          expect(click_event.click_url).to eq("https://www&#46;gumroad&#46;com/checkout")
          expect(click_event.click_timestamps.sole.to_i).to eq(now.to_i)
        end
      end
    end

    RSpec.shared_examples "records an open event while tracking a click event when a corresponding open event does not exist yet" do |email_provider|
      it "records an open event while tracking a click event when a corresponding open event does not exist yet" do
        now = Time.current
        travel_to(now) do
          handler_class_for(email_provider).new.perform(params)
        end

        expect(CreatorEmailOpenEvent.count).to eq(1)
        open_event = CreatorEmailOpenEvent.last
        expect(open_event.mailer_method).to eq("CustomerMailer.abandoned_cart")
        expect(open_event.mailer_args).to eq(mailer_args_with_single_workflow_id)
        expect(open_event.installment_id).to eq(abandoned_cart_workflow_installment1.id)
        expect(open_event.open_timestamps.count).to eq(1)
        expect(open_event.open_timestamps.last.to_i).to eq(now.to_i)
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
          now = Time.current
          params = { "_json" => [{ "event" => "click" },
                                 { "event" => "click", "mailer_class" => "CustomerMailer", "mailer_method" => "abandoned_cart", "mailer_args" => mailer_args_with_multiple_workflow_ids, "url" => "https://www&#46;gumroad&#46;com/checkout" }] }
          travel_to(now) do
            handler_class_for(:sendgrid).new.perform(params)
          end

          installments = [abandoned_cart_workflow_installment1.id, abandoned_cart_workflow_installment3.id]
          expect(CreatorEmailClickSummary.count).to eq(2)
          CreatorEmailClickSummary.each.with_index do |summary, i|
            expect(summary.total_unique_clicks).to eq(1)
            expect(summary.installment_id).to eq(installments[i])
            expect(summary.urls).to eq("https://www&#46;gumroad&#46;com/checkout" => 1)
          end
          expect(CreatorEmailClickEvent.count).to eq(2)
          CreatorEmailClickEvent.each.with_index do |click_event, i|
            expect(click_event.mailer_method).to eq("CustomerMailer.abandoned_cart")
            expect(click_event.mailer_args).to eq(mailer_args_with_multiple_workflow_ids)
            expect(click_event.installment_id).to eq(installments[i])
            expect(click_event.click_url).to eq("https://www&#46;gumroad&#46;com/checkout")
            expect(click_event.click_timestamps.sole.to_i).to eq(now.to_i)
            expect(click_event.click_count).to eq(1)
          end
        end
      end

      it "does not record an open event while recording a click event when a corresponding open event already exists" do
        now = Time.current
        params = {
          "_json" => [
            { "event" => "open", "mailer_class" => "CustomerMailer", "mailer_method" => "abandoned_cart", "mailer_args" => mailer_args_with_single_workflow_id },
            { "event" => "click", "mailer_class" => "CustomerMailer", "mailer_method" => "abandoned_cart", "mailer_args" => mailer_args_with_single_workflow_id, "url" => "https://www&#46;gumroad&#46;com/checkout" }
          ]
        }
        travel_to(now) do
          handler_class_for(:sendgrid).new.perform(params)
        end

        expect(CreatorEmailOpenEvent.count).to eq(1)
        open_event = CreatorEmailOpenEvent.last
        expect(open_event.mailer_method).to eq("CustomerMailer.abandoned_cart")
        expect(open_event.mailer_args).to eq(mailer_args_with_single_workflow_id)
        expect(open_event.installment_id).to eq(abandoned_cart_workflow_installment1.id)
        expect(open_event.open_timestamps.sole.to_i).to eq(now.to_i)

        expect(CreatorEmailClickSummary.count).to eq(1)
        summary = CreatorEmailClickSummary.last
        expect(summary.total_unique_clicks).to eq(1)
        expect(summary.installment_id).to eq(abandoned_cart_workflow_installment1.id)
        expect(summary.urls).to eq("https://www&#46;gumroad&#46;com/checkout" => 1)
        expect(CreatorEmailClickEvent.count).to eq(1)
        click_event = CreatorEmailClickEvent.last
        expect(click_event.mailer_method).to eq("CustomerMailer.abandoned_cart")
        expect(click_event.mailer_args).to eq(mailer_args_with_single_workflow_id)
        expect(click_event.installment_id).to eq(abandoned_cart_workflow_installment1.id)
        expect(click_event.click_url).to eq("https://www&#46;gumroad&#46;com/checkout")
        expect(click_event.click_timestamps.count).to eq(1)
        expect(click_event.click_timestamps.sole.to_i).to eq(now.to_i)
        expect(click_event.click_count).to eq(1)
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
  end
end
