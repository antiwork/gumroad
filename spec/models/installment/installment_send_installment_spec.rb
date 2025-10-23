# frozen_string_literal: true

require "spec_helper"

describe "InstallmentSendInstallment"  do
  before do
    @creator = create(:named_user, :with_avatar)
    @installment = create(:installment, call_to_action_text: "CTA", call_to_action_url: "https://www.example.com", seller: @creator)
  end

  describe "publish" do
    it "sets published_at" do
      travel_to(Time.current) do
        expect { @installment.publish! }.to change { @installment.published_at.to_s }.to(Time.current.to_s)
      end
    end

    context "video transcoding" do
      it "transcodes video files on publishing the product only if `queue_for_transcoding?` is true for the product file" do
        video_file_1 = create(:product_file, installment: @installment, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4")
        video_file_2 = create(:product_file, installment: @installment, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter3.mp4")
        video_file_3 = create(:product_file, installment: @installment, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter4.mp4")
        video_file_3.delete!

        @installment.publish!
        expect(TranscodeVideoForStreamingWorker).to_not have_enqueued_sidekiq_job(video_file_1.id, video_file_1.class.name)
        expect(TranscodeVideoForStreamingWorker).to_not have_enqueued_sidekiq_job(video_file_2.id, video_file_2.class.name)
        expect(TranscodeVideoForStreamingWorker).to_not have_enqueued_sidekiq_job(video_file_3.id, video_file_3.class.name)
        @installment.unpublish!

        allow_any_instance_of(ProductFile).to receive(:queue_for_transcoding?).and_return(true)
        @installment.publish!
        expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(video_file_1.id, video_file_1.class.name)
        expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(video_file_2.id, video_file_2.class.name)
        expect(TranscodeVideoForStreamingWorker).to_not have_enqueued_sidekiq_job(video_file_3.id, video_file_3.class.name)
      end

      describe "published installments" do
        before do
          allow(FFMPEG::Movie).to receive(:new) do
            double.tap do |movie_double|
              allow(movie_double).to receive(:duration).and_return(13)
              allow(movie_double).to receive(:frame_rate).and_return(60)
              allow(movie_double).to receive(:height).and_return(240)
              allow(movie_double).to receive(:width).and_return(320)
              allow(movie_double).to receive(:bitrate).and_return(125_779)
            end
          end

          @s3_double = double
          allow(@s3_double).to receive(:content_length).and_return(10_000)
          allow(@s3_double).to receive(:get).and_return("")

          create(:product_file, installment: @installment, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/pencil.png")
          @installment.publish!
        end

        it "transcodes video when the link is already published" do
          video_file = create(:product_file, installment: @installment, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4")
          allow(video_file).to receive(:s3_object).and_return(@s3_double)
          allow(video_file).to receive(:confirm_s3_key!)
          video_file.analyze

          expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(video_file.id, video_file.class.name)
        end

        it "doesn't transcode when the link is unpublished" do
          @installment.link.unpublish!
          @installment.unpublish!
          @installment.reload

          video_file = create(:product_file, link: @installment.link, installment: @installment, url: "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachments/2/original/chapter2.mp4")
          allow(video_file).to receive(:s3_object).and_return(@s3_double)
          allow(video_file).to receive(:confirm_s3_key!)
          video_file.analyze

          expect(TranscodeVideoForStreamingWorker).not_to have_enqueued_sidekiq_job(video_file.id, video_file.class.name)
        end
      end
    end
  end

  describe "send_installment_from_workflow_for_purchase" do
    before do
      @seller = create(:user)
      @product = create(:product, user: @seller)
      vc = create(:variant_category, link: @product)
      @variant1 = create(:variant, variant_category: vc)
      @variant2 = create(:variant, variant_category: vc)
      @workflow = create(:workflow, seller: @seller, link: @product)
      @installment = create(:installment, link: @product, workflow: @workflow)
      @purchase1 = create(:purchase, link: @product, created_at: 1.week.ago, price_cents: 100)
      @purchase2 = create(:purchase, link: @product, email: "tuhinA@gumroad.com", created_at: 2.weeks.ago, price_cents: 100)
    end

    it "sends a purchase_installment email for the purchase" do
      expect(PostSendgridApi).to receive(:process).with(
        post: @installment,
        recipients: [{ email: @purchase1.email, purchase: @purchase1 }],
        cache: {}
      )
      expect(PostSendgridApi).to receive(:process).with(
        post: @installment,
        recipients: [{ email: @purchase2.email, purchase: @purchase2 }],
        cache: anything
      )

      @installment.send_installment_from_workflow_for_purchase(@purchase1.id)
      @installment.send_installment_from_workflow_for_purchase(@purchase2.id)
    end

    it "respects can_contact for purchase installments" do
      @purchase2.can_contact = false
      @purchase2.save!
      expect(PostSendgridApi).to receive(:process).with(
        post: @installment,
        recipients: [{ email: @purchase1.email, purchase: @purchase1 }],
        cache: {}
      )

      @installment.send_installment_from_workflow_for_purchase(@purchase1.id)
      @installment.send_installment_from_workflow_for_purchase(@purchase2.id)
    end

    it "does not send a purchase_installment if buyer got the installment from another purchase" do
      link2 = create(:product, user: @seller)
      purchase3 = create(:purchase, link: link2, email: "tuhinA@gumroad.com", created_at: 2.weeks.ago, price_cents: 100)
      create(:creator_contacting_customers_email_info, installment: @installment, purchase: purchase3)
      expect(PostSendgridApi).to receive(:process).with(
        post: @installment,
        recipients: [{ email: @purchase1.email, purchase: @purchase1 }],
        cache: {}
      )
      @installment.send_installment_from_workflow_for_purchase(@purchase1.id)
      @installment.send_installment_from_workflow_for_purchase(@purchase2.id)
    end

    it "sends a purchase_installment if buyer got the installment from another purchase but it has since been refunded" do
      link2 = create(:product, user: @seller)
      purchase3 = create(:purchase, link: link2, email: "tuhinA@gumroad.com", created_at: 2.weeks.ago, price_cents: 100)
      create(:creator_contacting_customers_email_info, installment: @installment, purchase: purchase3)

      @installment.send_installment_from_workflow_for_purchase(@purchase2.id)

      expect(PostSendgridApi).to receive(:process).with(
        post: @installment,
        recipients: [{ email: @purchase2.email, purchase: @purchase2 }],
        cache: {}
      )
      purchase3.update!(stripe_refunded: true)
      @installment.send_installment_from_workflow_for_purchase(@purchase2.id)
    end

    describe "variant workflows" do
      before do
        @variant1_workflow = create(:variant_workflow, link: @product, base_variant: @variant1)
        @variant1_installment = create(:installment, link: @product, workflow: @variant1_workflow)

        @variant2_workflow = create(:variant_workflow, link: @product, base_variant: @variant2)
        @variant2_installment = create(:installment, link: @product, workflow: @variant2_workflow)

        @purchase1.update!(variant_attributes: [@variant1])
      end

      it "sends a purchase_installment email for a purchase of a variant with a workflow" do
        expect(PostSendgridApi).to receive(:process).with(
          post: @variant1_installment,
          recipients: [{ email: @purchase1.email, purchase: @purchase1 }],
          cache: {}
        )
        @variant1_installment.send_installment_from_workflow_for_purchase(@purchase1.id)
      end

      it "does not send a purchase_installment email for a variant that was not purchased" do
        expect(PostSendgridApi).not_to receive(:process)
        @variant2_installment.send_installment_from_workflow_for_purchase(@purchase1.id)
        @variant1_installment.send_installment_from_workflow_for_purchase(@purchase2.id)
      end
    end

    describe "multi-product or variant workflows" do
      before do
        @other_product = create(:product, user: @seller)
        @other_variant = create(:variant, variant_category: create(:variant_category, link: @other_product))
        @purchase1.update!(variant_attributes: [@variant1])
      end

      it "sends a purchase_installment email if the purchase is for the targeted product" do
        multi_product_workflow = create(:seller_workflow, seller: @seller, bought_products: [@product.unique_permalink, @other_product.unique_permalink])
        multi_product_installment = create(:installment, workflow: multi_product_workflow)

        multi_product_and_variant_workflow = create(:seller_workflow, seller: @seller, bought_products: [@product.unique_permalink], bought_variants: [@other_variant.external_id])
        multi_product_and_variant_installment = create(:installment, workflow: multi_product_and_variant_workflow)

        expect(PostSendgridApi).to receive(:process).with(
          post: multi_product_installment,
          recipients: [{ email: @purchase1.email, purchase: @purchase1 }],
          cache: {}
        )
        expect(PostSendgridApi).to receive(:process).with(
          post: multi_product_and_variant_installment,
          recipients: [{ email: @purchase1.email, purchase: @purchase1 }],
          cache: {}
        )

        multi_product_installment.send_installment_from_workflow_for_purchase(@purchase1.id)
        multi_product_and_variant_installment.send_installment_from_workflow_for_purchase(@purchase1.id)
      end

      it "sends a purchase_installment email if the purchase is for the targeted variant" do
        multi_variant_workflow = create(:seller_workflow, seller: @seller, bought_variants: [@variant1.external_id, @other_variant.external_id])
        multi_variant_installment = create(:installment, workflow: multi_variant_workflow)

        multi_product_and_variant_workflow = create(:seller_workflow, seller: @seller, bought_products: [@other_product.unique_permalink], bought_variants: [@variant1.external_id])
        multi_product_and_variant_installment = create(:installment, workflow: multi_product_and_variant_workflow)

        expect(PostSendgridApi).to receive(:process).with(
          post: multi_variant_installment,
          recipients: [{ email: @purchase1.email, purchase: @purchase1 }],
          cache: {}
        )
        expect(PostSendgridApi).to receive(:process).with(
          post: multi_product_and_variant_installment,
          recipients: [{ email: @purchase1.email, purchase: @purchase1 }],
          cache: {}
        )
        multi_variant_installment.send_installment_from_workflow_for_purchase(@purchase1.id)
        multi_product_and_variant_installment.send_installment_from_workflow_for_purchase(@purchase1.id)
      end

      it "does not send a purchase_installment email if the purchase is not for the targeted product" do
        multi_product_workflow = create(:seller_workflow, seller: @seller, bought_products: [@other_product.unique_permalink])
        multi_product_installment = create(:installment, workflow: multi_product_workflow)
        expect(PostSendgridApi).not_to receive(:process)
        multi_product_installment.send_installment_from_workflow_for_purchase(@purchase1.id)
      end

      it "does not send a purchase_installment email if the purchase is not for the targeted variant" do
        multi_variant_workflow = create(:seller_workflow, seller: @seller, bought_variants: [@other_variant.external_id])
        multi_variant_installment = create(:installment, workflow: multi_variant_workflow)

        expect(PostSendgridApi).not_to receive(:process)
        multi_variant_installment.send_installment_from_workflow_for_purchase(@purchase1.id)
      end
    end

    describe "subscriptions" do
      before do
        @product = create(:membership_product, user: @seller)
        @purchase = create(:membership_purchase, link: @product, variant_attributes: [@product.default_tier])
        @sub = @purchase.subscription
        @workflow = create(:workflow, seller: @seller, link: @product)
        @installment = create(:installment, link: @product, workflow: @workflow)
      end

      it "does not do anything if purchase is recurring payment" do
        @purchase.update_attribute(:is_original_subscription_purchase, false)
        expect(PostSendgridApi).not_to receive(:process)
        @installment.send_installment_from_workflow_for_purchase(@purchase.id)
      end

      it "does not do anything if subscription is cancelled" do
        @sub.unsubscribe_and_fail!
        expect(PostSendgridApi).not_to receive(:process)
        @installment.send_installment_from_workflow_for_purchase(@purchase.id)
      end

      it "queues installment for original subscription purchase and alive subscription" do
        expect(PostSendgridApi).to receive(:process).with(
          post: @installment,
          recipients: [{ email: @purchase.email, purchase: @purchase }],
          cache: {}
        )
        @installment.send_installment_from_workflow_for_purchase(@purchase.id)
      end

      context "when subscription plan has changed" do
        before do
          @updated_original_purchase = create(:membership_purchase, subscription_id: @sub.id, link: @product, purchase_state: "not_charged")
          @purchase.update!(is_archived_original_subscription_purchase: true)
        end

        it "queues installment for the current original purchase" do
          expect(PostSendgridApi).to receive(:process).with(
            post: @installment,
            recipients: [{ email: @updated_original_purchase.email, purchase: @updated_original_purchase }],
            cache: {}
          )
          @installment.send_installment_from_workflow_for_purchase(@purchase.id)
        end

        context "and tier has changed" do
          it "does not queue installment for a workflow belonging to the old tier" do
            other_tier = create(:variant, variant_category: @product.tier_category)
            @updated_original_purchase.update!(variant_attributes: [other_tier])
            variant_workflow = create(:variant_workflow, seller: @seller, link: @product, base_variant: @product.default_tier)
            variant_installment = create(:installment, link: @product, base_variant: @product.default_tier, workflow: variant_workflow)

            expect(PostSendgridApi).not_to receive(:process)
            variant_installment.send_installment_from_workflow_for_purchase(@purchase.id)
          end
        end
      end

      it "sends a purchase_installment if buyer got the installment from another subscription but it has since been deactivated" do
        purchase3 = create(:purchase, link: @purchase.link, email: @purchase.email, created_at: 2.weeks.ago, price_cents: 100)
        create(:creator_contacting_customers_email_info, installment: @installment, purchase: @purchase)

        allow(PostSendgridApi).to receive(:process).once
        @installment.send_installment_from_workflow_for_purchase(purchase3.id)

        expect(PostSendgridApi).to receive(:process).with(
          post: @installment,
          recipients: [{ email: purchase3.email, purchase: purchase3 }],
          cache: {}
        )

        @sub.update!(deactivated_at: 1.day.ago)
        @installment.send_installment_from_workflow_for_purchase(purchase3.id)
      end

      context "when subscription was reactivated" do
        before do
          @purchase.update!(created_at: 1.week.ago)
          @sub.subscription_events.create!(event_type: :deactivated, occurred_at: 6.days.ago)
          @sub.subscription_events.create!(event_type: :restarted, occurred_at: 1.day.ago)

          @installment.update!(published_at: 1.day.ago)
          create(:installment_rule, installment: @installment, delayed_delivery_time: 1.day)

          @installment_2 = create(:published_installment, link: @product, workflow: @workflow)
          create(:installment_rule, installment: @installment_2, delayed_delivery_time: 3.days)
        end

        context "when it is too early to send the workflow post" do
          before do
            # PostSendgridApi creates this, but is mocked in specs
            create(:creator_contacting_customers_email_info_sent, purchase: @purchase, installment: @installment, email_name: "purchase_installment")
          end

          it "does not send an email" do
            expect(PostSendgridApi).not_to receive(:process)
            @installment_2.send_installment_from_workflow_for_purchase(@purchase.id)
          end

          it "schedules it to be sent in the future" do
            @installment_2.send_installment_from_workflow_for_purchase(@purchase.id)

            expect(SendWorkflowInstallmentWorker).to have_enqueued_sidekiq_job(@installment_2.id, 1, @purchase.id, nil)
          end
        end

        it "sends the next workflow post email when the previous one was deleted" do
          @installment.update!(deleted_at: Time.current)

          expect(PostSendgridApi).to receive(:process).with(
            post: @installment_2,
            recipients: [{ email: @purchase.email, purchase: @purchase }],
            cache: {}
          )
          travel_to(2.days.from_now) do
            @installment_2.send_installment_from_workflow_for_purchase(@purchase.id)
          end
        end

        it "sends the next workflow post email when the previous one was sent on time" do
          expect(PostSendgridApi).to receive(:process).with(
            post: @installment,
            recipients: [{ email: @purchase.email, purchase: @purchase }],
            cache: anything
          )
          # Enqueue first workflow post
          @installment.send_installment_from_workflow_for_purchase(@purchase.id)

          # PostSendgridApi creates this, but is mocked in specs
          create(:creator_contacting_customers_email_info_sent,
                 purchase: @purchase,
                 installment: @installment,
                 email_name: "purchase_installment")

          expect(PostSendgridApi).to receive(:process).with(
            post: @installment_2,
            recipients: [{ email: @purchase.email, purchase: @purchase }],
            cache: {}
          )
          # Let's wait 2 days and attempt to send the next workflow post email
          travel_to(2.days.from_now) do
            @installment_2.send_installment_from_workflow_for_purchase(@purchase.id)
          end
        end
      end
    end

    describe "preorders" do
      before do
        @preorder_link = create(:product, is_in_preorder_state: true)
        @preorder_workflow = create(:workflow, seller: @preorder_link.user, link: @preorder_link)
        @preorder_purchase = create(:purchase, link: @preorder_link, purchase_state: "preorder_concluded_successfully")
        @preorder_post = create(:installment, link: @preorder_link, workflow: @preorder_workflow)
      end

      it "does not send purchase_installment to chargedback purchases" do
        @preorder_purchase.update_attribute(:chargeback_date, Time.current)
        expect(PostSendgridApi).not_to receive(:process)
        @preorder_post.send_installment_from_workflow_for_purchase(@preorder_purchase.id)
      end
    end

    describe "gifts" do
      before do
        @gift_link = create(:product)
        @gift_workflow = create(:workflow, seller: @gift_link.user, link: @gift_link)
        @gifter_purchase = create(:purchase, link: @gift_link, is_gift_sender_purchase: true, purchase_state: "successful")
        @giftee_purchase = create(:purchase, link: @gift_link, purchase_state: "gift_receiver_purchase_successful")
        @gift_post = create(:installment, link: @gift_link, installment_type: "product")
      end

      it "sends a message to the giftee" do
        expect(PostSendgridApi).to receive(:process).with(
          post: @gift_post,
          recipients: [{ email: @giftee_purchase.email, purchase: @giftee_purchase }],
          cache: {}
        )
        @gift_post.send_installment_from_workflow_for_purchase(@giftee_purchase.id)
      end
    end
  end

  describe "send_installment_from_workflow_for_follower" do
    before do
      @followed = create(:user)
      @workflow = create(:workflow, seller: @followed, link: nil, workflow_type: Workflow::FOLLOWER_TYPE)
      @installment = create(:follower_installment, seller: @followed, workflow: @workflow)
      @follower = create(:active_follower, followed_id: @followed.id, email: "some@email.com")
    end

    it "sends a follower_installment email for the purchase" do
      allow(PostSendgridApi).to receive(:process)
      @installment.send_installment_from_workflow_for_follower(@follower.id)
      expect(PostSendgridApi).to have_received(:process).with(
        post: @installment,
        recipients: [{ email: @follower.email, follower: @follower, url_redirect: UrlRedirect.last! }],
        cache: {}
      )
    end

    it "doesn't send email if following was deleted" do
      @follower.mark_deleted!
      expect(PostSendgridApi).not_to receive(:process)
      @installment.send_installment_from_workflow_for_follower(@follower.id)
    end

    it "does not send email if follower has not confirmed" do
      @follower.update_column(:confirmed_at, nil)
      expect(PostSendgridApi).not_to receive(:process)
      @installment.send_installment_from_workflow_for_follower(@follower.id)
    end
  end
end
