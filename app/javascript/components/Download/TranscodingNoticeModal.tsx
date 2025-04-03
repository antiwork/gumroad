import * as React from "react";

import { Modal } from "$app/components/Modal";

type Props = { transcodeOnFirstSale: boolean };

export const TranscodingNoticeModal = ({ transcodeOnFirstSale }: Props) => {
  const [open, setOpen] = React.useState(true);
  return (
    <Modal
      open={open}
      title={transcodeOnFirstSale ? "Your video will be transcoded on first sale." : "Your video is being transcoded."}
      onClose={() => setOpen(false)}
    >
      <h4>
        {transcodeOnFirstSale
          ? "Until then, you may experience some viewing issues. You'll get an email once it's done."
          : "Until then, you and your future customers may experience some viewing issues. You'll get an email once it's done."}
      </h4>
    </Modal>
  );
};
