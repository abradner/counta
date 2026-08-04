// Client-side lookup over the `client.*` subtree of config/locales/<locale>.yml.
//
// One source of truth: the server serialises that subtree into a data
// attribute on <body> and this reads it. A data attribute rather than an
// inline <script> because the CSP has no 'unsafe-inline', and rather than a
// fetch because copy must be present before the first render.
//
// Deliberately tiny — this covers interpolation and English-style
// one/other plurals, which is what the current copy needs. A locale with
// more plural categories (Polish, Arabic, Russian) needs real CLDR rules;
// swap the `pluralKey` function for a proper implementation then, not the
// call sites.

const STRINGS = JSON.parse(document.body.dataset.i18n || "{}");

function lookup(key) {
  return key.split(".").reduce((node, part) => (node == null ? undefined : node[part]), STRINGS);
}

function pluralKey(count) {
  return count === 1 ? "one" : "other";
}

function interpolate(template, vars) {
  return template.replace(/%\{(\w+)\}/g, (whole, name) =>
    Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : whole);
}

// t("dose.clicks", { count: 8 }) => "8 clicks"
// A missing key is a bug, not something to paper over with a blank string, so
// it shouts in the console and renders the key — visible in any spec or
// screenshot rather than silently disappearing.
export function t(key, vars = {}) {
  let entry = lookup(key);

  if (entry !== null && typeof entry === "object") {
    if (!("count" in vars)) {
      console.error(`i18n: "${key}" needs a count`);
      return key;
    }
    entry = entry[pluralKey(vars.count)] ?? entry.other;
  }

  if (typeof entry !== "string") {
    console.error(`i18n: missing key "${key}"`);
    return key;
  }
  return interpolate(entry, vars);
}

// Formats a click count the way the readout does everywhere else.
export const clicks = count => t("dose.clicks", { count });

// Like t(), but placeholders may be DOM nodes — for copy that embeds an
// element, e.g. <time datetime>. Returns an array suitable for
// element.replaceChildren(...). Keeping the sentence in one translatable
// string matters: word order around the dates differs by language, so
// concatenating fragments would be untranslatable.
export function tNodes(key, nodeVars = {}, vars = {}) {
  const template = t(key, { ...vars, ...Object.fromEntries(
    Object.keys(nodeVars).map(name => [ name, `%{${name}}` ]) ) });
  return template.split(/(%\{\w+\})/).map(part => {
    const name = part.match(/^%\{(\w+)\}$/)?.[1];
    return name && nodeVars[name] ? nodeVars[name] : part;
  }).filter(part => part !== "");
}
