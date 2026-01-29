import { useForm, usePage } from "@inertiajs/react";
import * as React from "react";
import { cast } from "ts-safe-cast";

import { StandaloneLayout } from "$app/inertia/layout";

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
  } = cast<PageProps>(usePage().props);

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
      <EmailConfirmation confirmation_info={confirmation_info} />
    </Layout>
  );
}

const EmailConfirmation = ({ confirmation_info }: { confirmation_info: ConfirmationInfo }) => {
  const { data, setData, post, processing } = useForm({
    id: confirmation_info.id,
    destination: confirmation_info.destination ?? "",
    display: confirmation_info.display ?? "",
    email: confirmation_info.email ?? "",
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    post(Routes.confirm_redirect_path());
  };

  return (
    <Placeholder>
      <h2>You've viewed this product a few times already</h2>
      <p>Once you enter the email address used to purchase this product, you'll be able to access it again.</p>
      <form onSubmit={handleSubmit} className="flex flex-col gap-4" style={{ width: "calc(min(428px, 100%))" }}>
        <input
          type="text"
          name="email"
          placeholder="Email address"
          value={data.email}
          onChange={(e) => setData("email", e.target.value)}
        />
        <Button type="submit" color="accent" disabled={processing}>
          {processing ? "Confirming..." : "Confirm email"}
        </Button>
      </form>
    </Placeholder>
  );
};

ConfirmPage.layout = (page: React.ReactNode) => <StandaloneLayout>{page}</StandaloneLayout>;

export default ConfirmPage;
