import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const sourcePath = resolve(root, "app/javascript/stylesheets/pages_tailwind.generated.html");
const inputPath = resolve(root, "app/javascript/stylesheets/pages_tailwind.css");
const outputPath = resolve(root, "public/pages-tailwind.css");
const tailwindBin = resolve(
  root,
  "node_modules/.bin",
  process.platform === "win32" ? "tailwindcss.cmd" : "tailwindcss",
);

const classes = new Set();
const variants = ["sm", "md", "lg", "hover", "dark", "dark:hover"];
const spacing = [
  "0",
  "0.5",
  "1",
  "1.5",
  "2",
  "2.5",
  "3",
  "3.5",
  "4",
  "5",
  "6",
  "7",
  "8",
  "9",
  "10",
  "11",
  "12",
  "14",
  "16",
  "20",
  "24",
  "28",
  "32",
  "36",
  "40",
  "44",
  "48",
  "52",
  "56",
  "60",
  "64",
  "72",
  "80",
  "96",
];
const fractions = ["1/2", "1/3", "2/3", "1/4", "3/4", "1/5", "2/5", "3/5", "4/5"];
const sizeKeywords = ["auto", "full", "screen", "min", "max", "fit", ...fractions];
const colors = [
  "slate",
  "gray",
  "zinc",
  "neutral",
  "stone",
  "red",
  "orange",
  "amber",
  "yellow",
  "lime",
  "green",
  "emerald",
  "teal",
  "cyan",
  "sky",
  "blue",
  "indigo",
  "violet",
  "purple",
  "fuchsia",
  "pink",
  "rose",
];
const shades = ["50", "100", "200", "300", "400", "500", "600", "700", "800", "900", "950"];
const colorKeywords = ["black", "white", "transparent", "current", "inherit"];

const add = (...items) => {
  for (const item of items.flat()) if (item) classes.add(item);
};
const addWithVariants = (...items) => {
  for (const item of items.flat()) {
    add(item);
    for (const variant of variants) add(`${variant}:${item}`);
  }
};
const expand = (prefixes, values, withVariants = false) => {
  for (const prefix of prefixes) {
    for (const value of values) {
      const item = value === "" ? prefix : `${prefix}-${value}`;
      withVariants ? addWithVariants(item) : add(item);
    }
  }
};

expand(
  ["p", "px", "py", "pt", "pr", "pb", "pl", "m", "mx", "my", "mt", "mr", "mb", "ml", "gap", "gap-x", "gap-y"],
  spacing,
  true,
);
expand(["-m", "-mx", "-my", "-mt", "-mr", "-mb", "-ml"], spacing, true);
expand(["w", "h", "min-w", "min-h", "max-w", "max-h"], [...spacing, ...sizeKeywords, "none", "7xl"], true);
expand(
  ["inset", "inset-x", "inset-y", "top", "right", "bottom", "left"],
  [...spacing, ...fractions, "auto", "full"],
  true,
);
expand(["-top", "-right", "-bottom", "-left"], [...spacing, ...fractions, "full"], true);
expand(["z"], ["0", "10", "20", "30", "40", "50", "[1]", "[99]", "[999]"], true);
expand(["grid-cols"], ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"], true);
expand(["col-span", "row-span"], ["1", "2", "3", "4", "5", "6", "full"], true);
expand(["basis"], [...spacing, ...fractions, "auto", "full"], true);

for (const color of colors) {
  for (const shade of shades) {
    const value = `${color}-${shade}`;
    expand(
      ["bg", "text", "border", "ring", "outline", "decoration", "from", "via", "to", "placeholder"],
      [value],
      true,
    );
    for (const opacity of ["5", "10", "20", "25", "30", "40", "50", "60", "70", "75", "80", "90", "95"]) {
      expand(["bg", "text", "border"], [`${value}/${opacity}`]);
    }
  }
}
expand(["bg", "text", "border", "ring", "outline", "from", "via", "to"], colorKeywords, true);

addWithVariants(
  "container",
  "sr-only",
  "not-sr-only",
  "pointer-events-none",
  "pointer-events-auto",
  "visible",
  "invisible",
  "collapse",
  "static",
  "fixed",
  "absolute",
  "relative",
  "sticky",
  "block",
  "inline-block",
  "inline",
  "flex",
  "inline-flex",
  "grid",
  "inline-grid",
  "contents",
  "hidden",
  "flex-row",
  "flex-row-reverse",
  "flex-col",
  "flex-col-reverse",
  "flex-wrap",
  "flex-nowrap",
  "grow",
  "grow-0",
  "shrink",
  "shrink-0",
  "items-start",
  "items-end",
  "items-center",
  "items-baseline",
  "items-stretch",
  "justify-start",
  "justify-end",
  "justify-center",
  "justify-between",
  "justify-around",
  "justify-evenly",
  "self-start",
  "self-end",
  "self-center",
  "overflow-hidden",
  "overflow-auto",
  "overflow-x-hidden",
  "overflow-y-auto",
  "object-cover",
  "object-contain",
  "object-center",
  "text-left",
  "text-center",
  "text-right",
  "uppercase",
  "lowercase",
  "capitalize",
  "italic",
  "not-italic",
  "underline",
  "no-underline",
  "line-through",
  "antialiased",
  "truncate",
  "break-words",
  "whitespace-nowrap",
  "whitespace-pre-line",
  "list-disc",
  "list-decimal",
  "list-none",
);

expand(["text"], ["xs", "sm", "base", "lg", "xl", "2xl", "3xl", "4xl", "5xl", "6xl", "7xl", "8xl", "9xl"], true);
expand(
  ["font"],
  [
    "sans",
    "serif",
    "mono",
    "thin",
    "extralight",
    "light",
    "normal",
    "medium",
    "semibold",
    "bold",
    "extrabold",
    "black",
  ],
  true,
);
expand(
  ["leading"],
  ["none", "tight", "snug", "normal", "relaxed", "loose", "3", "4", "5", "6", "7", "8", "9", "10"],
  true,
);
expand(["tracking"], ["tighter", "tight", "normal", "wide", "wider", "widest"], true);
expand(["rounded"], ["none", "sm", "", "md", "lg", "xl", "2xl", "3xl", "full"], true);
expand(
  ["rounded-t", "rounded-r", "rounded-b", "rounded-l"],
  ["none", "sm", "", "md", "lg", "xl", "2xl", "3xl", "full"],
  true,
);
expand(
  ["border", "border-x", "border-y", "border-t", "border-r", "border-b", "border-l"],
  ["", "0", "2", "4", "8"],
  true,
);
expand(["divide-x", "divide-y"], ["", "0", "2", "4", "8"], true);
expand(["ring"], ["", "0", "1", "2", "4", "8"], true);
expand(["shadow"], ["sm", "", "md", "lg", "xl", "2xl", "inner", "none"], true);
expand(["opacity"], ["0", "5", "10", "20", "25", "30", "40", "50", "60", "70", "75", "80", "90", "95", "100"], true);
expand(["blur"], ["none", "sm", "", "md", "lg", "xl", "2xl", "3xl"], true);
expand(["duration"], ["75", "100", "150", "200", "300", "500", "700", "1000"], true);
expand(["ease"], ["linear", "in", "out", "in-out"], true);
expand(["transition"], ["", "all", "colors", "opacity", "shadow", "transform", "none"], true);
expand(["scale", "scale-x", "scale-y"], ["0", "50", "75", "90", "95", "100", "105", "110", "125", "150"], true);
expand(["rotate"], ["0", "1", "2", "3", "6", "12", "45", "90", "180"], true);
expand(["-rotate"], ["1", "2", "3", "6", "12", "45", "90", "180"], true);

add(
  "prose",
  "prose-sm",
  "prose-base",
  "prose-lg",
  "prose-xl",
  "sm:prose",
  "md:prose-lg",
  "lg:prose-xl",
  "dark:prose-invert",
);

addWithVariants(
  "aspect-square",
  "aspect-video",
  "animate-spin",
  "animate-pulse",
  "animate-bounce",
  "animate-ping",
  "shadow-[4px_4px_0px_#000]",
  "shadow-[6px_6px_0px_#000]",
  "shadow-[8px_8px_0px_#000]",
  "shadow-[4px_4px_#fff]",
  "shadow-[8px_8px_#fff]",
  "bg-[radial-gradient(circle_at_top,_var(--tw-gradient-stops))]",
  "bg-[linear-gradient(135deg,_var(--tw-gradient-stops))]",
  "text-[clamp(3rem,8vw,6rem)]",
  "text-[clamp(2.5rem,7vw,5rem)]",
  "text-[72px]",
  "text-[90px]",
  "leading-[0.9]",
  "leading-[1]",
  "tracking-[-0.03em]",
);

mkdirSync(dirname(sourcePath), { recursive: true });
mkdirSync(dirname(outputPath), { recursive: true });
writeFileSync(sourcePath, `<div class="${[...classes].sort().join(" ")}"></div>\n`);

const result = spawnSync(tailwindBin, ["-i", inputPath, "-o", outputPath, "--minify"], {
  cwd: root,
  stdio: "inherit",
});

if (result.status !== 0) process.exit(result.status ?? 1);
