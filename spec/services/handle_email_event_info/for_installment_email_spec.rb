# frozen_string_literal: true

describe HandleEmailEventInfo::ForInstallmentEmail do
  before do
    @installment = create(:installment)
    @purchase = create(:purchase)
    @identifier = "[#{@purchase.id}, #{@installment.id}]"
  end

  describe ".perform" do
    def send_open
      HandleSendgridEventJob.new.perform(
        "_json" => [{ "event" => "open", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                      "identifier" => @identifier, "installment_id" => @installment.id }]
      )
    end

    def send_click(url: "https://www&#46;gumroad&#46;com", identifier: @identifier)
      HandleSendgridEventJob.new.perform(
        "_json" => [{ "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                      "identifier" => identifier, "installment_id" => @installment.id, "url" => url }]
      )
    end

    it "records a unique open in DynamoDB" do
      send_open
      expect(@installment.reload.unique_open_count).to eq 1
    end

    it "does not GetItem installment summaries while recording an open" do
      allow(EmailEngagementDynamoStore).to receive(:summary).and_call_original
      Rails.cache.write(@installment.key_for_cache(:unique_open_count, dynamodb_reads: false), 0)
      Rails.cache.write(@installment.key_for_cache(:unique_open_count), 0)

      send_open

      expect(EmailEngagementDynamoStore).not_to have_received(:summary)
      expect(Rails.cache.read(@installment.key_for_cache(:unique_open_count, dynamodb_reads: false))).to be_nil
      expect(Rails.cache.read(@installment.key_for_cache(:unique_open_count))).to be_nil
    end

    it "does not increment unique opens for a repeat open from the same recipient" do
      send_open
      send_open
      expect(@installment.reload.unique_open_count).to eq 1
    end

    it "records a unique click and counts a compensating open" do
      send_click
      expect(@installment.reload.unique_click_count).to eq 1
      expect(@installment.unique_open_count).to eq 1
    end

    it "reads live unique click and open counts after a click event" do
      Rails.cache.write(@installment.key_for_cache(:unique_click_count, dynamodb_reads: false), 0)
      Rails.cache.write(@installment.key_for_cache(:unique_open_count, dynamodb_reads: false), 0)

      send_click

      installment = Installment.find(@installment.id)
      expect(installment.unique_click_count).to eq 1
      expect(installment.unique_open_count).to eq 1
      expect(Rails.cache.read(@installment.key_for_cache(:unique_click_count, dynamodb_reads: false))).to be_nil
      expect(Rails.cache.read(@installment.key_for_cache(:unique_open_count, dynamodb_reads: false))).to be_nil
    end

    it "counts two urls from the same recipient as one unique clicker and two pairs" do
      send_click(url: "https://www&#46;gumroad&#46;com")
      send_click(url: "https://www&#46;google&#46;com")
      expect(@installment.reload.unique_click_count).to eq 2
      expect(@installment.clicked_urls.values.sum).to eq 2
    end

    it "ignores a duplicate click of the same url by the same recipient" do
      send_click
      send_click
      expect(@installment.reload.unique_click_count).to eq 1
    end

    it "marks the per-purchase email_info as opened when a click event arrives" do
      email_info = create(:creator_contacting_customers_email_info_sent, installment: @installment, purchase: @purchase)
      send_click
      expect(email_info.reload).to be_opened
      expect(email_info.opened_at).to be_present
    end

    it "leaves an already-opened email_info untouched on a click event" do
      email_info = create(:creator_contacting_customers_email_info_opened, installment: @installment, purchase: @purchase)
      original_opened_at = email_info.opened_at
      send_click
      expect(email_info.reload).to be_opened
      expect(email_info.opened_at.to_i).to eq(original_opened_at.to_i)
    end

    it "registers two unique clicks for two different users clicking the same url" do
      send_click
      purchase2 = create(:purchase)
      send_click(identifier: "[#{purchase2.id}, #{@installment.id}]")
      expect(@installment.reload.unique_click_count).to eq 2
      expect(@installment.clicked_urls.values.sum).to eq 2
    end

    it "handles the second event in the params array even if the first one is malformed" do
      HandleSendgridEventJob.new.perform(
        "_json" => [
          { "event" => "click" },
          { "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
            "identifier" => @identifier, "installment_id" => @installment.id, "url" => "https://www&#46;gumroad&#46;com" }
        ]
      )
      expect(@installment.reload.unique_click_count).to eq 1
    end

    it "does not increment unique opens twice when a click follows an open for the same recipient" do
      send_open
      send_click
      expect(@installment.reload.unique_open_count).to eq 1
      expect(@installment.unique_click_count).to eq 1
    end

    it "stores attachment clicks as view_attachments_url" do
      send_click(url: "#{DOMAIN}/d/fdd185111c9808abfb6029a3c2e4e96e")
      expect(@installment.reload.clicked_urls.keys).to include("view_attachments_url")
    end

    it "does not record clicks on unsubscribe urls" do
      HandleSendgridEventJob.new.perform(
        "_json" => [
          { "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
            "identifier" => @identifier, "installment_id" => @installment.id,
            "url" => "#{DOMAIN}#{Rails.application.routes.url_helpers.unsubscribe_purchase_path('CTE53CxbKFW_VLa0BZ9-iA==')}" },
          { "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
            "identifier" => @identifier, "installment_id" => @installment.id,
            "url" => "#{DOMAIN}#{Rails.application.routes.url_helpers.unsubscribe_imported_customer_path('_CTE53CxbKVLa0BZ9-iA==')}" },
          { "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
            "identifier" => @identifier, "installment_id" => @installment.id,
            "url" => "#{DOMAIN}#{Rails.application.routes.url_helpers.cancel_follow_path('-CTE53CxbKVLa0BZ9-iA==')}" }
        ]
      )
      expect(@installment.reload.unique_click_count).to eq 0
    end

    describe "cancel follower" do
      before do
        @non_existent_purchase_id = 999_999_999
      end

      it "does not cancel the follower on bounce event" do
        follower = create(:active_follower, email: "test@example.com", followed_id: @installment.seller_id)

        params = { "_json" => [{ "event" => "bounce", "type" => "bounce", "email" => "test@example.com",
                                 "identifier" => "[#{@non_existent_purchase_id}, #{@installment.id}]", "installment_id" => @installment.id }] }
        expect do
          travel_to(Time.current) do
            HandleSendgridEventJob.new.perform(params)
          end
        end.not_to change { follower.reload.alive? }
      end

      it "cancels the follower on spamreport event" do
        follower = create(:active_follower, email: "test@example.com", followed_id: @installment.seller_id)

        params = { "_json" => [{ "event" => "spamreport", "type" => "spamreport", "email" => "test@example.com",
                                 "identifier" => "[#{@non_existent_purchase_id}, #{@installment.id}]", "installment_id" => @installment.id }] }
        travel_to(Time.current) do
          HandleSendgridEventJob.new.perform(params)
        end

        expect(follower.reload).to be_deleted
      end
    end

    describe "email info" do
      describe "purchase installment" do
        describe "existing email info" do
          before do
            @email_info = create(:creator_contacting_customers_email_info, installment: @installment, purchase: @purchase)
          end

          it "marks it as bounced without changing contact consent" do
            follower = create(:active_follower, email: @purchase.email, followed_id: @purchase.seller_id)
            another_product = create(:product, user: @purchase.seller)
            another_purchase = create(:purchase, link: another_product, email: @purchase.email)

            params = { "_json" => [{ "event" => "bounce", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id }] }
            expect do
              travel_to(Time.current) do
                HandleSendgridEventJob.new.perform(params)
              end
            end.not_to change { [@purchase.reload.can_contact, another_purchase.reload.can_contact, follower.reload.alive?] }

            expect(CreatorContactingCustomersEmailInfo.count).to eq 1
            expect(@email_info.reload.state).to eq "bounced"
          end

          it "buffers the delivered mark and applies it on flush" do
            params = { "_json" => [{ "event" => "delivered", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id, "timestamp" => 1.day.ago.to_i }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(@email_info.reload.state).to eq "created"
            expect(FlushDeliveredEmailInfosJob).to have_enqueued_sidekiq_job

            FlushDeliveredEmailInfosJob.new.perform

            expect(CreatorContactingCustomersEmailInfo.count).to eq 1
            expect(@email_info.reload.state).to eq "delivered"
            expect(@email_info.reload.delivered_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
          end

          it "does not rewrite an already-delivered email_info" do
            @email_info.mark_sent!
            @email_info.mark_delivered!(2.days.ago)
            original_delivered_at = @email_info.reload.delivered_at

            params = { "_json" => [{ "event" => "delivered", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id, "timestamp" => Time.current.to_i }] }
            HandleSendgridEventJob.new.perform(params)
            FlushDeliveredEmailInfosJob.new.perform

            expect(@email_info.reload.state).to eq "delivered"
            expect(@email_info.delivered_at.to_i).to eq(original_delivered_at.to_i)
          end

          it "does not downgrade an opened email_info on a late delivered event" do
            @email_info.mark_sent!
            @email_info.mark_delivered!
            @email_info.mark_opened!
            opened_at = @email_info.reload.opened_at

            params = { "_json" => [{ "event" => "delivered", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id, "timestamp" => Time.current.to_i }] }
            HandleSendgridEventJob.new.perform(params)
            FlushDeliveredEmailInfosJob.new.perform

            expect(@email_info.reload.state).to eq "opened"
            expect(@email_info.opened_at.to_i).to eq(opened_at.to_i)
          end

          it "marks it as delivered synchronously when Redis is unavailable" do
            allow($redis).to receive(:rpush).and_raise(Redis::CannotConnectError)
            params = { "_json" => [{ "event" => "delivered", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id, "timestamp" => 1.day.ago.to_i }] }
            HandleSendgridEventJob.new.perform(params)

            expect(FlushDeliveredEmailInfosJob).not_to have_enqueued_sidekiq_job
            expect(@email_info.reload.state).to eq "delivered"
            expect(@email_info.reload.delivered_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
          end

          it "marks it as opened" do
            params = { "_json" => [{ "event" => "open", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id, "timestamp" => 1.hour.ago.to_i }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(CreatorContactingCustomersEmailInfo.count).to eq 1
            expect(@email_info.reload.state).to eq "opened"
            expect(@email_info.reload.opened_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
          end

          it "unsubscribes the buyer of the purchase and cancels the follower when the event type is 'spamreport'" do
            follower = create(:active_follower, email: @purchase.email, followed_id: @purchase.seller_id)
            another_product = create(:product, user: @purchase.seller)
            another_purchase = create(:purchase, link: another_product, email: @purchase.email)

            params = { "_json" => [{ "event" => "spamreport", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id }] }
            expect do
              HandleSendgridEventJob.new.perform(params)
            end.to change { [@purchase.reload.can_contact, another_purchase.reload.can_contact, follower.reload.alive?] }.from([true, true, true]).to([false, false, false])
          end

          it "does not unsubscribe the buyer when the event type is 'spamreport' from Resend" do
            follower = create(:active_follower, email: @purchase.email, followed_id: @purchase.seller_id)
            another_product = create(:product, user: @purchase.seller)
            another_purchase = create(:purchase, link: another_product, email: @purchase.email)

            params = {
              "data" => {
                "created_at" => "2025-01-02 00:14:11.140106+00",
                "to" => [@purchase.email],
                "headers" => [
                  { "name" => MailerInfo.header_name(:mailer_class), "value" => MailerInfo.encrypt("CreatorContactingCustomersMailer") },
                  { "name" => MailerInfo.header_name(:mailer_method), "value" => MailerInfo.encrypt("purchase_installment") },
                  { "name" => MailerInfo.header_name(:mailer_args), "value" => MailerInfo.encrypt(@identifier) },
                  { "name" => MailerInfo.header_name(:purchase_id), "value" => MailerInfo.encrypt(@purchase.id.to_s) },
                  { "name" => MailerInfo.header_name(:post_id), "value" => MailerInfo.encrypt(@installment.id.to_s) }
                ],
              },
              "type" => EmailEventInfo::EVENTS[:complained][MailerInfo::EMAIL_PROVIDER_RESEND]
            }
            expect do
              HandleResendEventJob.new.perform(params)
            end.not_to change { [@purchase.reload.can_contact, another_purchase.reload.can_contact, follower.reload.alive?] }
          end
        end

        describe "creating new email info" do
          it "creates a new email info and mark it as bounced" do
            expect(CreatorContactingCustomersEmailInfo.count).to eq 0
            params = { "_json" => [{ "event" => "bounce", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(CreatorContactingCustomersEmailInfo.count).to eq 1
            expect(CreatorContactingCustomersEmailInfo.last.state).to eq "bounced"
            expect(CreatorContactingCustomersEmailInfo.last.email_name).to eq "purchase_installment"
          end

          it "does not create a new email info for a delivered event" do
            expect(CreatorContactingCustomersEmailInfo.count).to eq 0
            params = { "_json" => [{ "event" => "delivered", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id, "timestamp" => 1.day.ago.to_i }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end
            FlushDeliveredEmailInfosJob.new.perform

            expect(CreatorContactingCustomersEmailInfo.count).to eq 0
          end

          it "creates a new email info and mark it as opened" do
            expect(CreatorContactingCustomersEmailInfo.count).to eq 0
            params = { "_json" => [{ "event" => "open", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id, "timestamp" => 1.hour.ago.to_i }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(CreatorContactingCustomersEmailInfo.count).to eq 1
            expect(CreatorContactingCustomersEmailInfo.last.state).to eq "opened"
            expect(CreatorContactingCustomersEmailInfo.last.opened_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
          end

          it "unsubscribes the buyer of the purchase when the event type is 'spamreport'" do
            another_product = create(:product, user: @purchase.seller)
            another_purchase = create(:purchase, link: another_product, email: @purchase.email)

            params = { "_json" => [{ "event" => "spamreport", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id }] }

            expect do
              HandleSendgridEventJob.new.perform(params)
            end.to change { [@purchase.reload.can_contact, another_purchase.reload.can_contact] }.from([true, true]).to([false, false])
          end
        end
      end

      describe "subscription installment" do
        before do
          @subscription = create(:subscription)
          @purchase.update_attribute(:subscription_id, @subscription.id)
          @purchase.update_attribute(:is_original_subscription_purchase, true)
        end

        describe "existing email info" do
          before do
            @email_info = create(:creator_contacting_customers_email_info, installment: @installment, purchase: @purchase)
          end

          it "buffers the delivered mark against the original purchase and applies it on flush" do
            params = { "_json" => [{ "event" => "delivered", "type" => "CreatorContactingCustomersMailer.subscription_installment",
                                     "identifier" => "[#{@subscription.id}, #{@installment.id}]", "installment_id" => @installment.id, "timestamp" => 1.day.ago.to_i }] }
            HandleSendgridEventJob.new.perform(params)
            FlushDeliveredEmailInfosJob.new.perform

            expect(@email_info.reload.state).to eq "delivered"
            expect(@email_info.delivered_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
          end

          it "marks it as opened" do
            params = { "_json" => [{ "event" => "open", "type" => "CreatorContactingCustomersMailer.subscription_installment",
                                     "identifier" => "[#{@subscription.id}, #{@installment.id}]", "installment_id" => @installment.id, "timestamp" => 1.hour.ago.to_i }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(CreatorContactingCustomersEmailInfo.count).to eq 1
            expect(@email_info.reload.state).to eq "opened"
            expect(@email_info.reload.opened_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
          end
        end

        describe "creating new email info" do
          it "creates a new email info and mark it as bounced" do
            expect(CreatorContactingCustomersEmailInfo.count).to eq 0
            params = { "_json" => [{ "event" => "bounce", "type" => "CreatorContactingCustomersMailer.subscription_installment",
                                     "identifier" => "[#{@subscription.id}, #{@installment.id}]", "installment_id" => @installment.id }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(CreatorContactingCustomersEmailInfo.count).to eq 1
            expect(CreatorContactingCustomersEmailInfo.last.state).to eq "bounced"
            expect(CreatorContactingCustomersEmailInfo.last.email_name).to eq "subscription_installment"
          end

          it "does not create a new email info for a delivered event" do
            expect(CreatorContactingCustomersEmailInfo.count).to eq 0
            params = { "_json" => [{ "event" => "delivered", "type" => "CreatorContactingCustomersMailer.subscription_installment",
                                     "identifier" => "[#{@subscription.id}, #{@installment.id}]", "installment_id" => @installment.id, "timestamp" => 1.day.ago.to_i }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end
            FlushDeliveredEmailInfosJob.new.perform

            expect(CreatorContactingCustomersEmailInfo.count).to eq 0
          end
        end
      end

      describe "follower installment" do
        it "does not create a new email info" do
          expect(CreatorContactingCustomersEmailInfo.count).to eq 0
          params = { "_json" => [{ "event" => "delivered", "type" => "CreatorContactingCustomersMailer.follower_installment",
                                   "identifier" => "[5, #{@installment.id}]", "installment_id" => @installment.id }] }
          travel_to(Time.current) do
            HandleSendgridEventJob.new.perform(params)
          end

          expect(CreatorContactingCustomersEmailInfo.count).to eq 0
        end
      end
    end

    describe "DynamoDB dual write" do
      it "records the open event in DynamoDB" do
        expect(EmailEngagementDynamoStore).to receive(:record_open).with(
          installment_id: @installment.id,
          mailer_method: "CreatorContactingCustomersMailer.purchase_installment",
          mailer_args: @identifier
        )

        params = { "_json" => [{ "event" => "open", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                 "identifier" => @identifier, "installment_id" => @installment.id }] }
        HandleSendgridEventJob.new.perform(params)
      end

      it "records the click event in DynamoDB" do
        expect(EmailEngagementDynamoStore).to receive(:record_click).with(
          installment_id: @installment.id,
          mailer_method: "CreatorContactingCustomersMailer.purchase_installment",
          mailer_args: @identifier,
          click_url: "https://www&#46;gumroad&#46;com"
        )

        params = { "_json" => [{ "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                 "identifier" => @identifier, "installment_id" => @installment.id, "url" => "https://www&#46;gumroad&#46;com" }] }
        HandleSendgridEventJob.new.perform(params)
      end
    end
  end
end
