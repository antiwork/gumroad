import * as React from "react";
import { CardElement, Elements, useElements, useStripe } from "@stripe/react-stripe-js";
import { loadStripe } from "@stripe/stripe-js";
import { Button } from "$app/components/Button";
import { request } from "$app/utils/request";
import { showAlert } from "$app/components/server-components/Alert";

// @ts-ignore - STRIPE_PUBLIC_KEY is defined globally
const stripePromise = loadStripe(window.STRIPE_PUBLIC_KEY);

interface Card {
  id: number;
  visual: string;
  card_type: string;
  expiry: string;
  is_default: boolean;
  expired: boolean;
}

interface CardFormProps {
  onSuccess: () => void;
  onCancel: () => void;
}

function CardForm({ onSuccess, onCancel }: CardFormProps) {
  const stripe = useStripe();
  const elements = useElements();
  const [loading, setLoading] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!stripe || !elements) return;

    setLoading(true);
    setError(null);

    try {
      // Create payment method
      const cardElement = elements.getElement(CardElement);
      if (!cardElement) return;

      const { paymentMethod, error: pmError } = await stripe.createPaymentMethod({
        type: "card",
        card: cardElement,
      });

      if (pmError) {
        setError(pmError.message || "Card validation failed");
        return;
      }

      // Save to backend
      const response = await request("/settings/balance_load_cards", {
        method: "POST",
        body: JSON.stringify({
          payment_method_id: paymentMethod.id,
          set_as_default: true,
        }),
      });

      if (response.success) {
        showAlert({ message: "Card saved successfully!", type: "success" });
        onSuccess();
      } else {
        setError(response.error || "Failed to save card");
      }
    } catch (err: any) {
      setError(err.message || "An unexpected error occurred");
    } finally {
      setLoading(false);
    }
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-4 mt-4">
      <div className="p-4 border border-gray-300 rounded">
        <CardElement
          options={{
            style: {
              base: {
                fontSize: "16px",
                color: "#424770",
                "::placeholder": {
                  color: "#aab7c4",
                },
              },
              invalid: {
                color: "#9e2146",
              },
            },
            hidePostalCode: true,
          }}
        />
      </div>

      {error && (
        <div className="text-red-600 text-sm bg-red-50 p-3 rounded">
          {error}
        </div>
      )}

      <div className="flex gap-2">
        <Button
          type="submit"
          disabled={!stripe || loading}
          className="bg-blue-600 text-white hover:bg-blue-700"
        >
          {loading ? "Saving..." : "Save Card"}
        </Button>
        <Button
          type="button"
          onClick={onCancel}
          disabled={loading}
          className="bg-gray-200 text-gray-700 hover:bg-gray-300"
        >
          Cancel
        </Button>
      </div>
    </form>
  );
}

export function RefundPaymentMethodSection() {
  const [cards, setCards] = React.useState<Card[]>([]);
  const [showAddForm, setShowAddForm] = React.useState(false);
  const [loading, setLoading] = React.useState(true);

  const loadCards = async () => {
    try {
      const response = await request("/settings/balance_load_cards");
      if (response.success) {
        setCards(response.cards || []);
      }
    } catch (err) {
      console.error("Failed to load cards:", err);
      showAlert({ message: "Failed to load refund payment methods", type: "error" });
    } finally {
      setLoading(false);
    }
  };

  React.useEffect(() => {
    loadCards();
  }, []);

  const handleRemoveCard = async (cardId: number) => {
    if (!confirm("Are you sure you want to remove this card?")) return;

    try {
      const response = await request(`/settings/balance_load_cards/${cardId}`, {
        method: "DELETE",
      });

      if (response.success) {
        showAlert({ message: "Card removed successfully", type: "success" });
        loadCards();
      } else {
        showAlert({ message: response.error || "Failed to remove card", type: "error" });
      }
    } catch (err) {
      showAlert({ message: "Failed to remove card", type: "error" });
    }
  };

  const handleAddSuccess = () => {
    setShowAddForm(false);
    loadCards();
  };

  if (loading) {
    return (
      <div className="py-4">
        <div className="animate-pulse">Loading refund payment methods...</div>
      </div>
    );
  }

  return (
    <div className="border-t border-gray-200 pt-6 mt-6">
      <div className="mb-4">
        <h3 className="text-lg font-semibold text-gray-900">Refund Payment Method</h3>
        <p className="text-sm text-gray-600 mt-1">
          Add a credit card to automatically cover refunds when your balance is too low. Your card will only be charged when processing a refund with insufficient balance.
        </p>
      </div>

      {cards.length > 0 && (
        <div className="space-y-2 mb-4">
          {cards.map((card) => (
            <div
              key={card.id}
              className="flex items-center justify-between p-4 border border-gray-200 rounded bg-white hover:border-gray-300 transition-colors"
            >
              <div className="flex items-center gap-4">
                <div className="text-base font-mono">{card.visual}</div>
                <div className="text-sm text-gray-600">
                  <span className="capitalize">{card.card_type}</span> • Expires {card.expiry}
                  {card.expired && (
                    <span className="text-red-600 ml-2 font-semibold">(Expired)</span>
                  )}
                  {card.is_default && (
                    <span className="text-blue-600 ml-2 font-semibold">(Default)</span>
                  )}
                </div>
              </div>
              <button
                onClick={() => handleRemoveCard(card.id)}
                className="text-red-600 hover:text-red-800 text-sm font-medium transition-colors"
                type="button"
              >
                Remove
              </button>
            </div>
          ))}
        </div>
      )}

      {!showAddForm && (
        <Button
          onClick={() => setShowAddForm(true)}
          className="bg-white border border-gray-300 text-gray-700 hover:bg-gray-50"
          type="button"
        >
          {cards.length > 0 ? "Add Another Card" : "Add Card"}
        </Button>
      )}

      {showAddForm && (
        <div className="border-t border-gray-200 pt-4 mt-4">
          <h4 className="text-sm font-semibold text-gray-900 mb-2">Add New Card</h4>
          <Elements stripe={stripePromise}>
            <CardForm
              onSuccess={handleAddSuccess}
              onCancel={() => setShowAddForm(false)}
            />
          </Elements>
        </div>
      )}
    </div>
  );
}
