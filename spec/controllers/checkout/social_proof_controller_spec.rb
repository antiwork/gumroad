# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Checkout::SocialProofController, type: :controller do
  let(:user) { create(:user) }
  let(:social_proof_widget) { create(:social_proof_widget, user: user) }

  describe 'POST #track_event' do
    context 'when tracking an impression' do
      let(:params) do
        {
          widget_id: social_proof_widget.id,
          event_type: 'impression',
          session_id: 'test_session_123'
        }
      end

      it 'creates an impression event' do
        expect {
          post :track_event, params: params
        }.to change(SocialProofWidgetEvent, :count).by(1)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)['success']).to be true

        event = SocialProofWidgetEvent.last
        expect(event.event_type).to eq('impression')
        expect(event.social_proof_widget_id).to eq(social_proof_widget.id)
        expect(event.session_id).to eq('test_session_123')
      end
    end

    context 'when tracking a click' do
      let(:params) do
        {
          widget_id: social_proof_widget.id,
          event_type: 'click',
          session_id: 'test_session_123'
        }
      end

      it 'creates a click event' do
        expect {
          post :track_event, params: params
        }.to change(SocialProofWidgetEvent, :count).by(1)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)['success']).to be true

        event = SocialProofWidgetEvent.last
        expect(event.event_type).to eq('click')
        expect(event.social_proof_widget_id).to eq(social_proof_widget.id)
        expect(event.session_id).to eq('test_session_123')
      end
    end

    context 'when tracking a purchase' do
      let(:purchase) { create(:purchase) }
      let(:params) do
        {
          widget_id: social_proof_widget.id,
          event_type: 'purchase',
          session_id: 'test_session_123',
          purchase_id: purchase.id,
          revenue_cents: 1000
        }
      end

      it 'creates a purchase event' do
        expect {
          post :track_event, params: params
        }.to change(SocialProofWidgetEvent, :count).by(1)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)['success']).to be true

        event = SocialProofWidgetEvent.last
        expect(event.event_type).to eq('purchase')
        expect(event.social_proof_widget_id).to eq(social_proof_widget.id)
        expect(event.session_id).to eq('test_session_123')
        expect(event.purchase_id).to eq(purchase.id)
        expect(event.revenue_cents).to eq(1000)
      end
    end

    context 'with invalid event type' do
      let(:params) do
        {
          widget_id: social_proof_widget.id,
          event_type: 'invalid_type',
          session_id: 'test_session_123'
        }
      end

      it 'returns error response' do
        post :track_event, params: params

        expect(response).to have_http_status(:bad_request)
        expect(JSON.parse(response.body)['success']).to be false
        expect(JSON.parse(response.body)['error_message']).to eq('Invalid event type')
      end
    end

    context 'with non-existent widget' do
      let(:params) do
        {
          widget_id: 99999,
          event_type: 'impression',
          session_id: 'test_session_123'
        }
      end

      it 'returns not found error' do
        post :track_event, params: params

        expect(response).to have_http_status(:not_found)
        expect(JSON.parse(response.body)['success']).to be false
        expect(JSON.parse(response.body)['error_message']).to eq('Widget not found')
      end
    end
  end
end
