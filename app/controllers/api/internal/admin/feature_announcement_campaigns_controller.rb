# frozen_string_literal: true

class Api::Internal::Admin::FeatureAnnouncementCampaignsController < Api::Internal::Admin::BaseController
  CONTENT_PARAMS = %i[subject body reply_to].freeze
  MAX_LIST_RESULTS = 100

  # Approving or sending an email to every opted-in creator needs an attributable actor.
  before_action :require_per_actor_token!
  before_action :find_campaign_or_render, except: %i[index create]

  def index
    campaigns = FeatureAnnouncementCampaign.order(id: :desc).limit(MAX_LIST_RESULTS)
    render json: { success: true, campaigns: campaigns.map { campaign_json(_1) } }
  end

  def show
    render json: { success: true, campaign: campaign_json(@campaign), deliveries: delivery_counts }
  end

  def create
    campaign = FeatureAnnouncementCampaign.new(key: params[:key].to_s, audience: params[:audience].to_s, state: "draft", **content_params)
    record_admin_write(action: "feature_announcement_campaigns.create", target: campaign) do
      if campaign.save
        render json: { success: true, campaign: campaign_json(campaign) }, status: :created
      else
        render_errors(campaign)
      end
    end
  end

  def update
    record_admin_write(action: "feature_announcement_campaigns.update", target: @campaign) do
      if @campaign.with_lock { @campaign.update(content_params) }
        render json: { success: true, campaign: campaign_json(@campaign) }
      else
        render_errors(@campaign)
      end
    end
  end

  # Renders the email as the actor would get it. Nothing is sent or recorded. The digest is the one
  # stamped on the rendered message, so approving it approves the copy shown here.
  def preview
    mail = FeatureAnnouncementMailer.announcement(campaign: @campaign.key, user_id: Current.admin_actor.id, email: Current.admin_actor.email)
    rendered_digest = mail.message.feature_announcement_target[:content_digest]
    render json: {
      success: true,
      campaign: campaign_json(@campaign).merge(content_digest: rendered_digest),
      subscribed_count: FeatureAnnouncementSubscription.where(subscribed: true).count,
      email: { from: mail[:from].to_s, reply_to: mail.reply_to, subject: mail.subject, html_body: (mail.html_part || mail).body.decoded },
    }
  end

  def approve
    transition("approve") { @campaign.approve!(by: Current.admin_actor, digest: params[:content_digest].to_s) }
  end

  def deliver
    transition("deliver") { @campaign.start_sending! }
  end

  def cancel
    transition("cancel") { @campaign.cancel! }
  end

  private
    def record_admin_token_use?
      action_name != "preview"
    end

    def find_campaign_or_render
      @campaign = FeatureAnnouncementCampaign.find_by(key: params[:id].to_s)
      render json: { success: false, message: "Campaign not found" }, status: :not_found if @campaign.nil?
    end

    def content_params
      CONTENT_PARAMS.select { params.key?(_1) }.index_with { params[_1].to_s }
    end

    def transition(name)
      record_admin_write(action: "feature_announcement_campaigns.#{name}", target: @campaign) do
        yield
        render json: { success: true, campaign: campaign_json(@campaign.reload) }
      rescue FeatureAnnouncementCampaign::InvalidTransition => e
        render json: { success: false, message: e.message }, status: :conflict
      end
    end

    def render_errors(campaign)
      render json: { success: false, message: campaign.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end

    def delivery_counts
      FeatureAnnouncementDelivery.where(campaign: @campaign.key).group(:state, :reason).count
        .map { |(state, reason), count| { state:, reason:, count: } }
    end

    def campaign_json(campaign)
      {
        key: campaign.key,
        subject: campaign.subject,
        body: campaign.body,
        reply_to: campaign.reply_to,
        audience: campaign.audience,
        state: campaign.state,
        content_digest: campaign.current_digest,
        approved_by: campaign.approved_by&.external_id,
        approved_at: campaign.approved_at&.as_json,
        created_at: campaign.created_at&.as_json,
      }
    end
end
