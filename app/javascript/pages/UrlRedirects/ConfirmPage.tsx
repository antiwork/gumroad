import * as React from "react";
import { usePage } from "@inertiajs/react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { Layout, LayoutProps } from "$app/components/server-components/DownloadPage/Layout";
import { Placeholder } from "$app/components/ui/Placeholder";
import { useRunOnce } from "$app/components/useRunOnce";

type ConfirmationInfo = {
  id: string;
  destination: string | null;
  display: string | null;
  email: string | null;
};

type PageProps = LayoutProps & {
  confirmation_info: ConfirmationInfo;
};

function ConfirmPage() {
  const props = usePage<PageProps>().props;
  const {
    confirmation_info,
    content_unavailability_reason_code,
    is_mobile_app_web_view,
    terms_page_url,
    token,
    redirect_id,
    creator,
    add_to_library_option,
    installment,
    purchase,
  } = props;

  const [csrfToken, setCsrfToken] = React.useState("");
  useRunOnce(() => setCsrfToken(cast(document.querySelector("meta[name=csrf-token]")?.getAttribute("content"))));

  return (
    <Layout
      content_unavailability_reason_code={content_unavailability_reason_code}
      is_mobile_app_web_view={is_mobile_app_web_view}
      terms_page_url={terms_page_url}
      token={token}
      redirect_id={redirect_id}
      creator={creator}
      add_to_library_option={add_to_library_option}
      installment={installment}
      purchase={purchase}
    >
      <Placeholder>
        <h2>You've viewed this product a few times already</h2>
        <p>Once you enter the email address used to purchase this product, you'll be able to access it again.</p>
        <form
          action={Routes.confirm_redirect_path()}
          method="post"
          className="flex flex-col gap-4"
          style={{ width: "calc(min(428px, 100%))" }}
        >
          <input type="hidden" name="authenticity_token" value={csrfToken} />
          <input type="hidden" name="id" value={confirmation_info.id} />
          <input type="hidden" name="destination" value={confirmation_info.destination ?? ""} />
          <input type="hidden" name="display" value={confirmation_info.display ?? ""} />
          <input
            type="text"
            name="email"
            placeholder="Email address"
            defaultValue={confirmation_info.email ?? ""}
          />
          <Button type="submit" color="accent">
            Confirm email
          </Button>
        </form>
      </Placeholder>
    </Layout>
  );
}

ConfirmPage.loggedInUserLayout = true;

export default ConfirmPage;
