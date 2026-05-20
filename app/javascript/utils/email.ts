const REGEX =
  /^(([^<>()[\]\\.,;:\s@"]+(\.[^<>()[\]\\.,;:\s@"]+)*)|(".+"))@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})|(([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))$/u;
export const isValidEmail = (possiblyEmail: string): boolean =>
  REGEX.test(possiblyEmail) && possiblyEmail.length <= 255;

/** Sift3 string distance — same algorithm mailcheck used internally */
const sift3Distance = (s1: string, s2: string): number => {
  if (!s1 || !s2) return s1?.length || s2?.length || 0;
  const maxOffset = 5;
  let c1 = 0;
  let c2 = 0;
  let lcss = 0;
  let localCs = 0;

  while (c1 < s1.length && c2 < s2.length) {
    if (s1[c1] === s2[c2]) {
      localCs++;
    } else {
      lcss += localCs;
      localCs = 0;
      if (c1 !== c2) c1 = c2 = Math.min(c1, c2);
      for (let i = 0; i < maxOffset; i++) {
        if (c1 + i >= s1.length && c2 + i >= s2.length) break;
        if (c1 + i < s1.length && s1[c1 + i] === s2[c2]) {
          c1 += i;
          localCs++;
          break;
        }
        if (c2 + i < s2.length && s1[c1] === s2[c2 + i]) {
          c2 += i;
          localCs++;
          break;
        }
      }
    }
    c1++;
    c2++;
  }
  lcss += localCs;
  return Math.round(Math.max(s1.length, s2.length) - lcss);
};

const findClosestDomain = (domain: string, domains: string[], threshold = 3): string | null => {
  let bestDistance = Infinity;
  let bestDomain: string | null = null;
  const lowerDomain = domain.toLowerCase();

  for (const candidate of domains) {
    if (lowerDomain === candidate.toLowerCase()) return null; // exact match, no suggestion
    const distance = sift3Distance(lowerDomain, candidate.toLowerCase());
    if (distance < bestDistance) {
      bestDistance = distance;
      bestDomain = candidate;
    }
  }

  return bestDistance <= threshold ? bestDomain : null;
};

export interface EmailSuggestion {
  address: string;
  domain: string;
  full: string;
}

export const checkEmailForTypos = (email: string, cb: (suggestion: EmailSuggestion) => void): void => {
  const parts = email.split("@");
  if (parts.length < 2) return;

  const address = parts.slice(0, -1).join("@");
  const domainParts = (parts.at(-1) ?? "").split(".");
  const tld = domainParts.length > 1 ? domainParts.slice(1).join(".") : "";
  const domain = parts.at(-1) ?? "";

  // Check full domain first (e.g. "gmial.com" → "gmail.com")
  const closestDomain = findClosestDomain(domain, POPULAR_EMAIL_HOST_DOMAINS);
  if (closestDomain) {
    cb({ address, domain: closestDomain, full: `${address}@${closestDomain}` });
    return;
  }

  // Then check TLD (e.g. ".con" → ".com")
  if (tld) {
    const closestTld = findClosestDomain(tld, POPULAR_TOP_LEVEL_DOMAINS, 2);
    if (closestTld) {
      const closestTldParts = closestTld.split(".").length;
      const hostParts = domainParts.slice(0, -closestTldParts).join(".");
      const suggestedDomain = `${hostParts}.${closestTld}`;
      cb({ address, domain: suggestedDomain, full: `${address}@${suggestedDomain}` });
    }
  }
};

const POPULAR_EMAIL_HOST_DOMAINS = [
  "126.com",
  "163.com",
  "21cn.com",
  "aim.com",
  "alice.it",
  "aliyun.com",
  "aol.com",
  "aol.it",
  "arnet.com.ar",
  "att.net",
  "bellsouth.net",
  "blueyonder.co.uk",
  "bol.com.br",
  "bt.com",
  "btinternet.com",
  "charter.net",
  "comcast.net",
  "cox.net",
  "daum.net",
  "earthlink.net",
  "email.com",
  "email.it",
  "facebook.com",
  "fastmail.fm",
  "fibertel.com.ar",
  "foxmail.com",
  "free.fr",
  "freeserve.co.uk",
  "games.com",
  "globo.com",
  "globomail.com",
  "gmail.com",
  "gmx.com",
  "gmx.de",
  "gmx.fr",
  "gmx.net",
  "google.com",
  "googlemail.com",
  "hanmail.net",
  "hey.com",
  "hotmail.be",
  "hotmail.co.uk",
  "hotmail.com",
  "hotmail.com.ar",
  "hotmail.com.br",
  "hotmail.com.mx",
  "hotmail.de",
  "hotmail.es",
  "hotmail.fr",
  "hotmail.it",
  "hush.com",
  "hushmail.com",
  "icloud.com",
  "ig.com.br",
  "iname.com",
  "inbox.com",
  "itelefonica.com.br",
  "juno.com",
  "keemail.me",
  "laposte.net",
  "lavabit.com",
  "libero.it",
  "list.ru",
  "live.be",
  "live.co.uk",
  "live.com",
  "live.com.ar",
  "live.com.mx",
  "live.de",
  "live.fr",
  "live.it",
  "love.com",
  "mac.com",
  "mail.com",
  "mail.ru",
  "me.com",
  "msn.com",
  "nate.com",
  "naver.com",
  "neuf.fr",
  "ntlworld.com",
  "o2.co.uk",
  "oi.com.br",
  "online.de",
  "orange.fr",
  "orange.net",
  "outlook.com",
  "outlook.com.br",
  "pobox.com",
  "poste.it",
  "prodigy.net.mx",
  "protonmail.ch",
  "protonmail.com",
  "qq.com",
  "r7.com",
  "rambler.ru",
  "rocketmail.com",
  "safe-mail.net",
  "sbcglobal.net",
  "sfr.fr",
  "sina.cn",
  "sina.com",
  "sky.com",
  "skynet.be",
  "speedy.com.ar",
  "t-online.de",
  "talktalk.co.uk",
  "telenet.be",
  "teletu.it",
  "terra.com.br",
  "tin.it",
  "tiscali.co.uk",
  "tiscali.it",
  "tuta.io",
  "tutamail.com",
  "tutanota.com",
  "tutanota.de",
  "tvcablenet.be",
  "uol.com.br",
  "verizon.net",
  "virgilio.it",
  "virgin.net",
  "virginmedia.com",
  "voo.be",
  "wanadoo.co.uk",
  "wanadoo.fr",
  "web.de",
  "wow.com",
  "ya.ru",
  "yahoo.co.id",
  "yahoo.co.in",
  "yahoo.co.jp",
  "yahoo.co.kr",
  "yahoo.co.uk",
  "yahoo.com",
  "yahoo.com.ar",
  "yahoo.com.br",
  "yahoo.com.mx",
  "yahoo.com.ph",
  "yahoo.com.sg",
  "yahoo.de",
  "yahoo.fr",
  "yahoo.it",
  "yandex.com",
  "yandex.ru",
  "yeah.net",
  "ygm.com",
  "ymail.com",
  "zipmail.com.br",
  "zoho.com",
];

const POPULAR_TOP_LEVEL_DOMAINS = [
  "ac.uk",
  "at",
  "be",
  "biz",
  "ca",
  "cat",
  "ch",
  "co.il",
  "co.in",
  "co.jp",
  "co.nz",
  "co.uk",
  "com.au",
  "com.tw",
  "com",
  "cz",
  "de",
  "dk",
  "edu",
  "es",
  "eu",
  "fi",
  "fr",
  "gov",
  "gr",
  "hk",
  "hu",
  "ie",
  "in",
  "info",
  "it",
  "jp",
  "kr",
  "me",
  "mil",
  "net.au",
  "net",
  "nl",
  "no",
  "org",
  "pl",
  "ro",
  "ru",
  "se",
  "sg",
  "uk",
  "us",
];
