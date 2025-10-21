import cx from "classnames";
import * as React from "react";

import { Button } from "$app/components/Button";
import { useState, getErrors } from "$app/components/Checkout/payment";
import { Icon } from "$app/components/Icons";
import { Modal } from "$app/components/Modal";

export const GiftForm = ({ isMembership }: { isMembership: boolean }) => {
  const giftEmailUID = React.useId();
  const giftNoteUID = React.useId();
  const [cancellingPresetGift, setCancellingPresetGift] = React.useState(false);

  const [state, dispatch] = useState();
  const { gift } = state;
  const hasError = getErrors(state).has("gift");

  return (
    <div className="flex flex-col">
      <label className="flex w-full items-center justify-between">
        <div className="flex items-center">
          <Icon name="gift-fill" className="mr-2" />
          <h4>Give as a gift?</h4>
        </div>
        <input
          type="checkbox"
          role="switch"
          checked={!!gift}
          onChange={(e) => {
            if (gift?.type === "anonymous") {
              e.preventDefault();
              setCancellingPresetGift(true);
            } else {
              dispatch({ type: "set-value", gift: gift ? null : { type: "normal", email: "", note: "" } });
            }
          }}
        />
      </label>

      {gift ? (
        <div className="paragraphs w-full">
          {isMembership ? (
            <div role="alert" className="info">
              <div>
                Note: Free trials will be charged immediately. The membership will not auto-renew. The recipient must
                update the payment method to renew the membership.
              </div>
            </div>
          ) : null}
          {gift.type === "normal" ? (
            <fieldset className={cx({ danger: hasError })}>
              <legend>
                <label htmlFor={giftEmailUID}>Recipient email</label>
              </legend>
              <input
                id={giftEmailUID}
                type="email"
                value={gift.email}
                onChange={(evt) => dispatch({ type: "set-value", gift: { ...gift, email: evt.target.value } })}
                placeholder="Recipient email address"
                aria-invalid={hasError}
                className="w-full"
              />
            </fieldset>
          ) : (
            <div role="alert" className="info">
              <div>
                {gift.name}'s email has been hidden for privacy purposes.{" "}
                <button className="underline" onClick={() => setCancellingPresetGift(true)}>
                  Cancel gift option
                </button>
              </div>
              <Modal
                open={cancellingPresetGift}
                onClose={() => setCancellingPresetGift(false)}
                footer={
                  <>
                    <Button onClick={() => setCancellingPresetGift(false)}>No, cancel</Button>
                    <Button
                      color="primary"
                      onClick={() => {
                        dispatch({ type: "set-value", gift: null });
                        setCancellingPresetGift(false);
                      }}
                    >
                      Yes, reset
                    </Button>
                  </>
                }
                title="Reset gift option?"
              >
                You are about to switch off the gift option. To gift this wishlist again, you will need to return to the
                wishlist page and select "Gift this product".
              </Modal>
            </div>
          )}
          <fieldset className="w-full">
            <legend>
              <label htmlFor={giftNoteUID}>Message</label>
            </legend>
            <textarea
              id={giftNoteUID}
              value={gift.note}
              onChange={(evt) => dispatch({ type: "set-value", gift: { ...gift, note: evt.target.value } })}
              placeholder="A personalized message (optional)"
              className="w-full"
            />
          </fieldset>
        </div>
      ) : null}
    </div>
  );
};
