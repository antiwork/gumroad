const REGEX =
  /^(([^<>()[\]\\.,;:\s@"]+(\.[^<>()[\]\\.,;:\s@"]+)*)|(".+"))@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})|(([a-zA-Z\-0-9]+\.)+[a-zA-Z]{2,}))$/u;
export const isValidEmail = (possiblyEmail: string): boolean =>
  REGEX.test(possiblyEmail) && possiblyEmail.length <= 255;

const sift3Distance = (s1: string, s2: string): number => {
  if (s1.length === 0) return s2.length;
  if (s2.length === 0) return s1.length;

  let cursor = 0;
  let offset1 = 0;
  let offset2 = 0;
  let lcs = 0;
  const maxOffset = 5;

  while (cursor + offset1 < s1.length && cursor + offset2 < s2.length) {
    if (s1.charAt(cursor + offset1) === s2.charAt(cursor + offset2)) {
      lcs++;
    } else {
      offset1 = 0;
      offset2 = 0;
      for (let i = 0; i < maxOffset; i++) {
        if (cursor + i < s1.length && s1.charAt(cursor + i) === s2.charAt(cursor)) {
          offset1 = i;
          break;
        }
        if (cursor + i < s2.length && s1.charAt(cursor) === s2.charAt(cursor + i)) {
          offset2 = i;
          break;
        }
      }
    }
    cursor++;
  }

  return (s1.length + s2.length) / 2 - lcs;
};

const findClosestDomain = (domain: string, domains: string[], threshold: number): string | null => {
  let minDistance = Infinity;
  let closestDomain: string | null = null;

  for (const candidate of domains) {
    if (domain === candidate) return candidate;
    const distance = sift3Distance(domain, candidate);
    if (distance < minDistance) {
      minDistance = distance;
      closestDomain = candidate;
    }
  }

  return minDistance <= threshold ? closestDomain : null;
};

export interface EmailSuggestion {
  address: string;
  domain: string;
  full: string;
}

interface EmailParts {
  address: string;
  domain: string;
  secondLevelDomain: string;
  topLevelDomain: string;
}

const splitEmail = (email: string): EmailParts | null => {
  const parts = email.trim().split("@");
  if (parts.length < 2 || parts.some((part) => part === "")) return null;

  const domain = parts.at(-1) ?? "";
  const domainParts = domain.split(".");
  const topLevelDomain = domainParts.length === 1 ? (domainParts[0] ?? "") : domainParts.slice(1).join(".");

  return {
    address: parts.slice(0, -1).join("@"),
    domain,
    secondLevelDomain: domainParts.length === 1 ? "" : (domainParts[0] ?? ""),
    topLevelDomain,
  };
};

const encodeEmail = (email: string): string =>
  encodeURI(email)
    .replace("%20", " ")
    .replace("%25", "%")
    .replace("%5E", "^")
    .replace("%60", "`")
    .replace("%7B", "{")
    .replace("%7C", "|")
    .replace("%7D", "}");

const suggestEmail = (email: string): EmailSuggestion | null => {
  const emailParts = splitEmail(encodeEmail(email).toLowerCase());
  if (!emailParts) return null;

  if (
    POPULAR_SECOND_LEVEL_DOMAINS.includes(emailParts.secondLevelDomain) &&
    POPULAR_TOP_LEVEL_DOMAINS.includes(emailParts.topLevelDomain)
  )
    return null;

  const closestDomain = findClosestDomain(emailParts.domain, POPULAR_EMAIL_HOST_DOMAINS, DOMAIN_THRESHOLD);
  if (closestDomain) {
    if (closestDomain === emailParts.domain) return null;
    return {
      address: emailParts.address,
      domain: closestDomain,
      full: `${emailParts.address}@${closestDomain}`,
    };
  }

  const closestSecondLevelDomain = findClosestDomain(
    emailParts.secondLevelDomain,
    POPULAR_SECOND_LEVEL_DOMAINS,
    SECOND_LEVEL_THRESHOLD,
  );
  const closestTopLevelDomain = findClosestDomain(
    emailParts.topLevelDomain,
    POPULAR_TOP_LEVEL_DOMAINS,
    TOP_LEVEL_THRESHOLD,
  );

  let domain = emailParts.domain;
  let hasSuggestion = false;

  if (closestSecondLevelDomain && closestSecondLevelDomain !== emailParts.secondLevelDomain) {
    domain = domain.replace(emailParts.secondLevelDomain, closestSecondLevelDomain);
    hasSuggestion = true;
  }

  if (closestTopLevelDomain && closestTopLevelDomain !== emailParts.topLevelDomain) {
    domain = domain.replace(emailParts.topLevelDomain, closestTopLevelDomain);
    hasSuggestion = true;
  }

  return hasSuggestion
    ? {
        address: emailParts.address,
        domain,
        full: `${emailParts.address}@${domain}`,
      }
    : null;
};

export const checkEmailForTypos = (email: string, cb: (suggestion: EmailSuggestion) => void): void => {
  const suggestion = suggestEmail(email);
  if (suggestion) cb(suggestion);
};

const DOMAIN_THRESHOLD = 2;
const SECOND_LEVEL_THRESHOLD = 2;
const TOP_LEVEL_THRESHOLD = 2;

const POPULAR_SECOND_LEVEL_DOMAINS = ["yahoo", "hotmail", "mail", "live", "outlook", "gmx"];

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
