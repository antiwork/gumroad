# frozen_string_literal: true

describe HandleEmailEventInfo::ForInstallmentEmail do
  before do
    @installment = create(:installment)
    @purchase = create(:purchase)
    @identifier = "[#{@purchase.id}, #{@installment.id}]"
  end

  describe ".perform" do
    it "creates a new CreatorEmailOpenEvent object" do
      now = Time.current
      params = { "_json" => [{ "event" => "open", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id }] }
      travel_to(now) do
        HandleSendgridEventJob.new.perform(params)
      end

      expect(CreatorEmailOpenEvent.count).to eq 1
      open_event = CreatorEmailOpenEvent.last
      expect(open_event.mailer_method).to eq "CreatorContactingCustomersMailer.purchase_installment"
      expect(open_event.mailer_args).to eq @identifier
      expect(open_event.installment_id).to eq @installment.id
      expect(open_event.open_timestamps.count).to eq 1
      expect(open_event.open_timestamps.last.to_i).to eq now.to_i
      expect(open_event.open_count).to eq 1
    end

    it "sets cache for open event" do
      params = { "_json" => [{ "event" => "open", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id }] }

      HandleSendgridEventJob.new.perform(params)

      unique_open_count = Rails.cache.read("unique_open_count_for_installment_#{@installment.id}")
      expect(unique_open_count).to eq 1
    end

    it "creates a new CreatorEmailOpenEvent object and then update it if there are 2 identical open events" do
      now = Time.current
      params = { "_json" => [{ "event" => "open", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id }] }
      travel_to(now) do
        HandleSendgridEventJob.new.perform(params)
      end

      travel_to(now + 1.minute) do
        HandleSendgridEventJob.new.perform(params)
      end

      expect(CreatorEmailOpenEvent.count).to eq 1
      open_event = CreatorEmailOpenEvent.last
      expect(open_event.mailer_method).to eq "CreatorContactingCustomersMailer.purchase_installment"
      expect(open_event.mailer_args).to eq @identifier
      expect(open_event.installment_id).to eq @installment.id
      expect(open_event.open_timestamps.count).to eq 2
      expect(open_event.open_timestamps.first.to_i).to eq now.to_i
      expect(open_event.open_timestamps.last.to_i).to eq((now + 1.minute).to_i)
      expect(open_event.open_count).to eq 2
    end

    it "creates a new CreatorEmailClickSummary object and a new CreatorEmailClickEvent object" do
      now = Time.current
      params = { "_json" => [{ "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id, "url" => "https://www&#46;gumroad&#46;com" }] }
      travel_to(now) do
        HandleSendgridEventJob.new.perform(params)
      end

      expect(CreatorEmailClickSummary.count).to eq 1
      summary = CreatorEmailClickSummary.last
      expect(summary.total_unique_clicks).to eq 1
      expect(summary.installment_id).to eq @installment.id
      url_hash = { "https://www&#46;gumroad&#46;com" => 1 }
      expect(summary.urls).to eq url_hash
      expect(CreatorEmailClickEvent.count).to eq 1
      click_event = CreatorEmailClickEvent.last
      expect(click_event.mailer_method).to eq "CreatorContactingCustomersMailer.purchase_installment"
      expect(click_event.mailer_args).to eq @identifier
      expect(click_event.installment_id).to eq @installment.id
      expect(click_event.click_url).to eq "https://www&#46;gumroad&#46;com"
      expect(click_event.click_timestamps.count).to eq 1
      expect(click_event.click_timestamps.last.to_i).to eq now.to_i
      expect(click_event.click_count).to eq 1
    end

    it "sets cache on click event" do
      params = { "_json" => [{ "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id, "url" => "https://www&#46;gumroad&#46;com" }] }

      HandleSendgridEventJob.new.perform(params)

      unique_click_count = Rails.cache.read("unique_click_count_for_installment_#{@installment.id}")
      expect(unique_click_count).to eq 1

      # It should also cache unique_open_count
      unique_open_count = Rails.cache.read("unique_open_count_for_installment_#{@installment.id}")
      expect(unique_open_count).to eq 1
    end

    it "creates 1 new CreatorEmailClickSummary and 2 CreatorEmailClickEvent objects for different URLs, \
        but not update unique clicks if same identifier" do
      now = Time.current
      params = { "_json" => [{ "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id, "url" => "https://www&#46;gumroad&#46;com" }] }
      travel_to(now) do
        HandleSendgridEventJob.new.perform(params)
      end

      params2 = { "_json" => [{ "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                "identifier" => @identifier, "installment_id" => @installment.id, "url" => "https://www&#46;google&#46;com" }] }
      travel_to(now + 1.minute) do
        HandleSendgridEventJob.new.perform(params2)
      end

      expect(CreatorEmailClickSummary.count).to eq 1
      summary = CreatorEmailClickSummary.last
      expect(summary.total_unique_clicks).to eq 1
      expect(summary.installment_id).to eq @installment.id
      url_hash = { "https://www&#46;gumroad&#46;com" => 1, "https://www&#46;google&#46;com" => 1 }
      expect(summary.urls).to eq url_hash
      expect(CreatorEmailClickEvent.count).to eq 2
      click_event = CreatorEmailClickEvent.order_by(created_at: :asc).last
      expect(click_event.mailer_method).to eq "CreatorContactingCustomersMailer.purchase_installment"
      expect(click_event.mailer_args).to eq @identifier
      expect(click_event.installment_id).to eq @installment.id
      expect(click_event.click_url).to eq "https://www&#46;google&#46;com"
      expect(click_event.click_timestamps.count).to eq 1
      expect(click_event.click_timestamps.last.to_i).to eq((now + 1.minute).to_i)
      expect(click_event.click_count).to eq 1
    end

    it "does not modify CreatorEmailClickSummary if it sees two duplicate events, \
        but should update the timestamps for the CreatorEmailClickEvent object" do
      now = Time.current
      params = { "_json" => [{ "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id, "url" => "https://www&#46;gumroad&#46;com" }] }
      travel_to(now) do
        HandleSendgridEventJob.new.perform(params)
      end

      travel_to(now + 1.minute) do
        HandleSendgridEventJob.new.perform(params)
      end

      expect(CreatorEmailClickSummary.count).to eq 1
      summary = CreatorEmailClickSummary.last
      expect(summary.total_unique_clicks).to eq 1
      expect(summary.installment_id).to eq @installment.id
      url_hash = { "https://www&#46;gumroad&#46;com" => 1 }
      expect(summary.urls).to eq url_hash
      expect(CreatorEmailClickEvent.count).to eq 1
      click_event = CreatorEmailClickEvent.last
      expect(click_event.mailer_method).to eq "CreatorContactingCustomersMailer.purchase_installment"
      expect(click_event.mailer_args).to eq @identifier
      expect(click_event.installment_id).to eq @installment.id
      expect(click_event.click_url).to eq "https://www&#46;gumroad&#46;com"
      expect(click_event.click_timestamps.first.to_i).to eq now.to_i
    end

    it "registers two unique clicks for two different users clicking the same url for the same installment" do
      now = Time.current
      params = { "_json" => [{ "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id, "url" => "https://www&#46;gumroad&#46;com" }] }
      travel_to(now) do
        HandleSendgridEventJob.new.perform(params)
      end

      purchase2 = create(:purchase)
      params2 = { "_json" => [{ "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                "identifier" => "[#{purchase2.id}, #{@installment.id}]", "installment_id" => @installment.id,
                                "url" => "https://www&#46;gumroad&#46;com" }] }
      travel_to(now + 1.minute) do
        HandleSendgridEventJob.new.perform(params2)
      end

      expect(CreatorEmailClickSummary.count).to eq 1
      summary = CreatorEmailClickSummary.last
      expect(summary.total_unique_clicks).to eq 2
      expect(summary.installment_id).to eq @installment.id
      url_hash = { "https://www&#46;gumroad&#46;com" => 2 }
      expect(summary.urls).to eq url_hash
      expect(CreatorEmailClickEvent.count).to eq 2
      click_event = CreatorEmailClickEvent.order_by(created_at: :asc).last
      expect(click_event.mailer_method).to eq "CreatorContactingCustomersMailer.purchase_installment"
      expect(click_event.mailer_args).to eq "[#{purchase2.id}, #{@installment.id}]"
      expect(click_event.installment_id).to eq @installment.id
      expect(click_event.click_url).to eq "https://www&#46;gumroad&#46;com"
      expect(click_event.click_timestamps.count).to eq 1
      expect(click_event.click_timestamps.first.to_i).to eq((now + 1.minute).to_i)
      expect(click_event.click_count).to eq 1
    end

    it "handles the second event in the params array even if the first one is malformed" do
      now = Time.current
      params = { "_json" => [{ "event" => "click" },
                             { "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id, "url" => "https://www&#46;gumroad&#46;com" }] }
      travel_to(now) do
        HandleSendgridEventJob.new.perform(params)
      end

      expect(CreatorEmailClickSummary.count).to eq 1
      summary = CreatorEmailClickSummary.last
      expect(summary.total_unique_clicks).to eq 1
      expect(summary.installment_id).to eq @installment.id
      url_hash = { "https://www&#46;gumroad&#46;com" => 1 }
      expect(summary.urls).to eq url_hash
      expect(CreatorEmailClickEvent.count).to eq 1
      click_event = CreatorEmailClickEvent.last
      expect(click_event.mailer_method).to eq "CreatorContactingCustomersMailer.purchase_installment"
      expect(click_event.mailer_args).to eq @identifier
      expect(click_event.installment_id).to eq @installment.id
      expect(click_event.click_url).to eq "https://www&#46;gumroad&#46;com"
      expect(click_event.click_timestamps.count).to eq 1
      expect(click_event.click_timestamps.first.to_i).to eq now.to_i
      expect(click_event.click_count).to eq 1
    end

    it "creates a corresponding open event if a click event is logged but \
        an open event does not yet exist for a particular installment / recipient pair" do
      now = Time.current
      params = { "_json" => [{ "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id, "url" => "https://www&#46;gumroad&#46;com" }] }
      travel_to(now) do
        HandleSendgridEventJob.new.perform(params)
      end

      expect(CreatorEmailOpenEvent.count).to eq 1
      open_event = CreatorEmailOpenEvent.last
      expect(open_event.mailer_method).to eq "CreatorContactingCustomersMailer.purchase_installment"
      expect(open_event.mailer_args).to eq @identifier
      expect(open_event.installment_id).to eq @installment.id
      expect(open_event.open_timestamps.count).to eq 1
      expect(open_event.open_timestamps.last.to_i).to eq now.to_i
    end

    it "does not create a corresponding open event if a click event is logged if an open event already exists" do
      now = Time.current
      params = { "_json" => [{ "event" => "open", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id },
                             { "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id, "url" => "https://www&#46;gumroad&#46;com" }] }
      travel_to(now) do
        HandleSendgridEventJob.new.perform(params)
      end

      expect(CreatorEmailOpenEvent.count).to eq 1
      open_event = CreatorEmailOpenEvent.last
      expect(open_event.mailer_method).to eq "CreatorContactingCustomersMailer.purchase_installment"
      expect(open_event.mailer_args).to eq @identifier
      expect(open_event.installment_id).to eq @installment.id
      expect(open_event.open_timestamps.count).to eq 1
      expect(open_event.open_timestamps.last.to_i).to eq now.to_i

      expect(CreatorEmailClickSummary.count).to eq 1
      summary = CreatorEmailClickSummary.last
      expect(summary.total_unique_clicks).to eq 1
      expect(summary.installment_id).to eq @installment.id
      url_hash = { "https://www&#46;gumroad&#46;com" => 1 }
      expect(summary.urls).to eq url_hash
      expect(CreatorEmailClickEvent.count).to eq 1
      click_event = CreatorEmailClickEvent.last
      expect(click_event.mailer_method).to eq "CreatorContactingCustomersMailer.purchase_installment"
      expect(click_event.mailer_args).to eq @identifier
      expect(click_event.installment_id).to eq @installment.id
      expect(click_event.click_url).to eq "https://www&#46;gumroad&#46;com"
      expect(click_event.click_timestamps.count).to eq 1
      expect(click_event.click_timestamps.first.to_i).to eq now.to_i
      expect(click_event.click_count).to eq 1
    end

    it "replaces the url for an attachment link with 'Attached Files'" do
      now = Time.current
      params = { "_json" => [{
        "event" => "click",
        "type" => "CreatorContactingCustomersMailer.purchase_installment",
        "identifier" => @identifier,
        "installment_id" => @installment.id,
        "url" => "#{DOMAIN}/d/fdd185111c9808abfb6029a3c2e4e96e"
      }] }
      travel_to(now) do
        HandleSendgridEventJob.new.perform(params)
      end

      click_event = CreatorEmailClickEvent.last
      expect(click_event.click_url).to eq "view_attachments_url"
    end

    it "does not create an event for unsubscribes" do
      now = Time.current
      params = { "_json" => [{ "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id,
                               "url" => "#{DOMAIN}#{Rails.application.routes.url_helpers.unsubscribe_purchase_path('CTE53CxbKFW_VLa0BZ9-iA==')}" },
                             { "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id,
                               "url" => "#{DOMAIN}#{Rails.application.routes.url_helpers.unsubscribe_imported_customer_path('_CTE53CxbKVLa0BZ9-iA==')}" },
                             { "event" => "click", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                               "identifier" => @identifier, "installment_id" => @installment.id,
                               "url" => "#{DOMAIN}#{Rails.application.routes.url_helpers.cancel_follow_path('-CTE53CxbKVLa0BZ9-iA==')}" }] }
      travel_to(now) do
        HandleSendgridEventJob.new.perform(params)
      end

      click_event = CreatorEmailClickEvent.last
      expect(click_event).to eq nil
    end

    describe "cancel follower" do
      before do
        @non_existent_purchase_id = 999_999_999
      end

      it "cancels the follower on bounce event" do
        follower = create(:active_follower, email: "test@example.com", followed_id: @installment.seller_id)

        params = { "_json" => [{ "event" => "bounce", "type" => "bounce", "email" => "test@example.com",
                                 "identifier" => "[#{@non_existent_purchase_id}, #{@installment.id}]", "installment_id" => @installment.id }] }
        travel_to(Time.current) do
          HandleSendgridEventJob.new.perform(params)
        end

        expect(follower.reload).to be_deleted
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

          it "marks it as bounced and cancel the follower" do
            follower = create(:active_follower, email: @purchase.email, followed_id: @purchase.seller_id)

            params = { "_json" => [{ "event" => "bounce", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(CreatorContactingCustomersEmailInfo.count).to eq 1
            expect(@email_info.reload.state).to eq "bounced"
            expect(follower.reload).to be_deleted
          end

          it "marks it as delivered" do
            params = { "_json" => [{ "event" => "delivered", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id, "timestamp" => 1.day.ago.to_i }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(CreatorContactingCustomersEmailInfo.count).to eq 1
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

          it "creates a new email info and mark it as delivered" do
            expect(CreatorContactingCustomersEmailInfo.count).to eq 0
            params = { "_json" => [{ "event" => "delivered", "type" => "CreatorContactingCustomersMailer.purchase_installment",
                                     "identifier" => @identifier, "installment_id" => @installment.id, "timestamp" => 1.day.ago.to_i }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(CreatorContactingCustomersEmailInfo.count).to eq 1
            expect(CreatorContactingCustomersEmailInfo.last.state).to eq "delivered"
            expect(CreatorContactingCustomersEmailInfo.last.delivered_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
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

          it "creates a new email info and mark it as delivered" do
            expect(CreatorContactingCustomersEmailInfo.count).to eq 0
            params = { "_json" => [{ "event" => "delivered", "type" => "CreatorContactingCustomersMailer.subscription_installment",
                                     "identifier" => "[#{@subscription.id}, #{@installment.id}]", "installment_id" => @installment.id, "timestamp" => 1.day.ago.to_i }] }
            travel_to(Time.current) do
              HandleSendgridEventJob.new.perform(params)
            end

            expect(CreatorContactingCustomersEmailInfo.count).to eq 1
            expect(CreatorContactingCustomersEmailInfo.last.state).to eq "delivered"
            expect(CreatorContactingCustomersEmailInfo.last.delivered_at).to eq(Time.zone.at(params["_json"].first["timestamp"]))
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
  end
end
