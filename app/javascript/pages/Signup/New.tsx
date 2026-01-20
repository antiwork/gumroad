import { Link, useForm, usePage } from "@inertiajs/react";
import * as React from "react";

import { formatPrice } from "$app/utils/price";

import { AuthAlert } from "$app/components/AuthAlert";
import { Layout } from "$app/components/Authentication/Layout";
import { SocialAuth } from "$app/components/Authentication/SocialAuth";
import { Button } from "$app/components/Button";
import { PasswordInput } from "$app/components/PasswordInput";
import { Separator } from "$app/components/Separator";
import { useOriginalLocation } from "$app/components/useOriginalLocation";
import { RecaptchaCancelledError, useRecaptcha } from "$app/components/useRecaptcha";

type PageProps = {
  email: string | null;
  application_name: string | null;
  recaptcha_site_key: string | null;
  referrer: {
    id: string;
    name: string;
  } | null;
  stats: {
    number_of_creators: number;
    total_made: number;
  };
};

function SignupPage() {
  const { email: initialEmail, application_name, recaptcha_site_key, referrer, stats } = usePage<PageProps>().props;
  const { number_of_creators, total_made } = stats;

  const url = new URL(useOriginalLocation());
  const next = url.searchParams.get("next");
  const recaptcha = useRecaptcha({ siteKey: recaptcha_site_key });
  const uid = React.useId();

  const form = useForm<{
    user: {
      email: string;
      password: string;
      terms_accepted: boolean;
    };
    next: string | null;
    referral: string | null;
    "g-recaptcha-response": string | null;
  }>({
    user: {
      email: initialEmail ?? "",
      password: "",
      terms_accepted: true,
    },
    next,
    referral: referrer?.id ?? null,
    "g-recaptcha-response": null,
  });

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    try {
      const recaptchaResponse = recaptcha_site_key !== null ? await recaptcha.execute() : null;
      form.transform((data) => ({
        ...data,
        "g-recaptcha-response": recaptchaResponse,
      }));
      form.post(Routes.signup_path());
    } catch (e) {
      if (e instanceof RecaptchaCancelledError) return;
      throw e;
    }
  };

  const headerText = referrer
    ? `Tham gia ${referrer.name} trên Gumroad`
    : application_name
      ? `Đăng ký Gumroad và kết nối ${application_name}`
      : `Tham gia hơn ${number_of_creators.toLocaleString()} nhà sáng tạo đã kiếm được hơn ${formatPrice("$", total_made, 0, { noCentsIfWhole: true })} trên Gumroad bán sản phẩm kỹ thuật số và thành viên.`;

  return (
    <Layout header={headerText}>
      <form className="space-y-6" onSubmit={(e) => void handleSubmit(e)}>
        <AuthAlert />
        <fieldset>
          <legend>
            <label htmlFor={`${uid}-email`}>Email</label>
          </legend>
          <div className="relative group input-focus border border-slate-200 rounded-2xl bg-slate-50 transition-all overflow-hidden">
            <input
              id={`${uid}-email`}
              type="email"
              value={form.data.user.email}
              onChange={(e) => form.setData("user.email", e.target.value)}
              required
              className="w-full bg-transparent text-slate-900 text-sm p-4 pl-12 outline-none border-none appearance-none focus:ring-0 focus:outline-none"
            />
          </div>
        </fieldset>
        <fieldset>
          <legend>
            <label htmlFor={`${uid}-password`}>Mật khẩu</label>
          </legend>
          <div className="relative group input-focus border border-slate-200 rounded-2xl bg-slate-50 transition-all overflow-hidden">
            <PasswordInput
              id={`${uid}-password`}
              value={form.data.user.password}
              onChange={(e) => form.setData("user.password", e.target.value)}
              required
            />
          </div>
        </fieldset>
        <Button color="primary" type="submit" className="w-full" disabled={form.processing}>
          {form.processing ? "Đang tạo..." : "Tạo tài khoản"}
        </Button>
        <Separator>
          <span>Tùy chọn khác</span>
        </Separator>
        <SocialAuth />
        <p>
          Bằng việc tạo tài khoản, bạn đồng ý với <a href="https://gumroad.com/terms">Điều khoản sử dụng</a> và{" "}
          <a href="https://gumroad.com/privacy">Chính sách bảo mật</a> của chúng tôi.
        </p>

        <p className="mt-10 text-center text-sm text-slate-500 font-medium">
          Đã có tài khoản?
          <Link href={Routes.login_path({ next })} className="ms-1 font-extrabold text-blue-600 hover:text-blue-700 hover:underline underline-offset-4">Đăng nhập</Link>
        </p>
      </form>
      {recaptcha.container}
    </Layout>
  );
}

SignupPage.disableLayout = true;
export default SignupPage;
