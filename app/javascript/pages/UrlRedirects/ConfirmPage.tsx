import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { Button } from "$app/components/Button";
import { Layout, LayoutProps } from "$app/components/server-components/DownloadPage/Layout";
import { Placeholder } from "$app/components/ui/Placeholder";

type ConfirmationInfo = {
  id: string;
  destination: string | null;
  display: string | null;
  email: string | null;
};

type PageProps = LayoutProps & {
  confirmation_info: ConfirmationInfo;
  authenticity_token: string;
};

function ConfirmPage() {
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
    authenticity_token,
  } = cast<PageProps>(usePage().props);

  return (
    <div className="flex min-h-screen flex-col">
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
        <EmailConfirmation confirmation_info={confirmation_info} authenticity_token={authenticity_token} />
      </Layout>
    </div>
  );
}

const EmailConfirmation = ({
  confirmation_info,
  authenticity_token,
}: {
  confirmation_info: ConfirmationInfo;
  authenticity_token: string;
}) => {
  const { data, setData, post, processing } = useForm({
    id: confirmation_info.id,
    destination: confirmation_info.destination ?? "",
    display: confirmation_info.display ?? "",
    email: confirmation_info.email ?? "",
    authenticity_token,
  });

  const handleSubmit = (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    post(Routes.confirm_redirect_path());
  };

  return (
    <Placeholder>
      <h2>You've viewed this product a few times already</h2>
      <p>Once you enter the email address used to purchase this product, you'll be able to access it again.</p>
      <form
        action={Routes.confirm_redirect_path()}
        method="post"
        onSubmit={handleSubmit}
        className="flex flex-col gap-4"
        style={{ width: "calc(min(428px, 100%))" }}
      >
        <input type="hidden" name="utf8" value="✓" />
        <input type="hidden" name="authenticity_token" value={authenticity_token} />
        <input type="hidden" name="id" value={data.id} />
        <input type="hidden" name="destination" value={data.destination} />
        <input type="hidden" name="display" value={data.display} />
        <input
          type="text"
          name="email"
          placeholder="Email address"
          onChange={(e) => setData("email", e.target.value)}
          defaultValue={confirmation_info.email ?? ""}
        />
        <Button type="submit" color="accent" disabled={processing}>
          {processing ? "Confirming..." : "Confirm email"}
        </Button>
      </form>
    </Placeholder>
  );
};

ConfirmPage.loggedInUserLayout = true;
export default ConfirmPage;
