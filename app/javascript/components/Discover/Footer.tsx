import * as React from "react";

import logoG from "$assets/images/logo-g.svg";
import iconFacebook from "$assets/images/social/facebook.svg";
import iconInstagram from "$assets/images/social/instagram.svg";
import iconPinterest from "$assets/images/social/pinterest.svg";
import iconX from "$assets/images/social/x.svg";
import iconYoutube from "$assets/images/social/youtube.svg";

export const Footer = () => (
  <div className="flex flex-col justify-between gap-16 bg-black px-8 py-16 leading-relaxed text-white lg:flex-row lg:px-[4vw] lg:py-24">
    <div className="flex w-full max-w-3xl flex-col gap-16">
      <div className="flex flex-col gap-8">
        <div className="text-3xl lg:text-5xl lg:leading-tight">
          Subscribe to get tips and tactics to grow the way you want.
        </div>
        <form action="https://gumroad.com/follow_from_embed_form" method="post" className="flex gap-1">
          <input name="seller_id" type="hidden" value="6282492303727" />
          <div className="lg:flex-1">
            <input name="email" placeholder="Your email address" type="email" />
          </div>
          <button type="submit" className="button accent small">
            →
          </button>
        </form>
      </div>
      <div className="flex items-center gap-2">
        <img src={logoG} alt="Gumroad icon" className="h-6 w-6" />
        <div>Ⓒ Gumroad, Inc.</div>
      </div>
    </div>
    <div className="flex w-full max-w-3xl flex-col gap-16">
      <div className="flex flex-1 gap-16">
        <div className="flex flex-1 flex-col gap-3">
          <a href={Routes.discover_path()} className="no-underline hover:text-pink">
            Discover
          </a>
          <a href={Routes.gumroad_blog_root_path()} className="no-underline hover:text-pink">
            Blog
          </a>
          <a href={Routes.pricing_path()} className="no-underline hover:text-pink">
            Pricing
          </a>
          <a href={Routes.features_path()} className="no-underline hover:text-pink">
            Features
          </a>
          <a href={Routes.about_path()} className="no-underline hover:text-pink">
            About
          </a>
          <a href={Routes.small_bets_path()} className="no-underline hover:text-pink">
            Small Bets
          </a>
        </div>
        <div className="flex flex-1 flex-col gap-3">
          <a href={Routes.help_center_root_path()} className="no-underline hover:text-pink">
            Help
          </a>
          <a
            href="https://www.youtube.com/playlist?list=PL_DfN-mKCGNuswqERc6sIA8urYAKARc6s"
            className="no-underline hover:text-pink"
          >
            Board meetings
          </a>
          <a href={Routes.terms_path()} className="no-underline hover:text-pink">
            Terms of Service
          </a>
          <a href={Routes.privacy_path()} className="no-underline hover:text-pink">
            Privacy Policy
          </a>
        </div>
      </div>
      <div className="flex justify-between">
        <a href="https://x.com/gumroad" className="hover:opacity-70">
          <img src={iconX} alt="X" className="h-6 w-6" />
        </a>
        <a href="https://www.youtube.com/channel/UC6o7H5wr2Cf4ibntYEs4Mcg" className="hover:opacity-70">
          <img src={iconYoutube} alt="YouTube" className="h-6 w-8" />
        </a>
        <a href="https://www.instagram.com/gumroad/" className="hover:opacity-70">
          <img src={iconInstagram} alt="Instagram" className="h-6 w-6" />
        </a>
        <a href="https://www.facebook.com/gumroad" className="hover:opacity-70">
          <img src={iconFacebook} alt="Facebook" className="h-6 w-4" />
        </a>
        <a href="http://pinterest.com/gumroad" className="hover:opacity-70">
          <img src={iconPinterest} alt="Pinterest" className="h-6 w-6" />
        </a>
      </div>
    </div>
  </div>
);
